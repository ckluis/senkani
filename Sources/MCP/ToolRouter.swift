import Foundation
import MCP
import Core

private struct ToolTimeoutError: Error {}

enum ToolRouter {
    /// Phase B-i: register handlers with an explicit `ConnectionContext` so
    /// per-connection identity (and Phase B-ii toggle overrides) flow into
    /// dispatch. Existing call sites (single-connection stdio + tests) can
    /// pass a synthesized stdio context via `ConnectionContext.stdio(session:)`.
    static func register(on server: Server, session: MCPSession, context: ConnectionContext? = nil) async {
        let initialEffective = await session.effectiveSet
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: advertisedTools(for: initialEffective))
        }

        let resolvedContext = context ?? ConnectionContext.stdio(session: session)
        await server.withMethodHandler(CallTool.self) { params in
            await route(params, session: session, context: resolvedContext)
        }
    }

    /// Filter the full tool catalog by the session's effective-set.
    /// Core tools (read/outline/deps/session) always appear even when
    /// the manifest omits them. When no manifest file is present at
    /// all (`manifestPresent == false`) the full catalog ships — today's
    /// backwards-compat behavior.
    static func advertisedTools(for effectiveSet: EffectiveSet) -> [Tool] {
        let catalog = allTools()
        guard effectiveSet.manifestPresent else { return catalog }
        return catalog.filter { effectiveSet.isToolEnabled($0.name) }
    }

    static func route(_ params: CallTool.Parameters, session: MCPSession, context: ConnectionContext? = nil) async -> CallTool.Result {
        FileHandle.standardError.write(Data("🟡 TOOL CALL: \(params.name)\n".utf8))
        let ctx = context ?? ConnectionContext.stdio(session: session)
        // Re-read feature toggles from pane config file (GUI may have changed them)
        await session.refreshConfig()
        // Phase S.1 — manifest gating. If a manifest is present and does
        // not enable this tool, return a structured error pointing the
        // caller at the Skills pane toggle rather than silently dispatching.
        // No manifest present → full surface (today's behavior).
        let effective = await session.effectiveSet
        if effective.manifestPresent, !effective.isToolEnabled(params.name) {
            return .init(content: [.text(
                text: "Tool '\(params.name)' is not enabled in this project's manifest. Enable it in the Skills pane (or add it to .senkani/senkani.json).",
                annotations: nil, _meta: nil)],
                isError: true)
        }
        // SECURITY: Budget enforcement — non-bypassable gate before any tool execution.
        // This is the only routing path, so all tool calls pass through this check.
        let budgetDecision = await session.checkBudget()
        switch budgetDecision {
        case .block(let reason):
            // Log the blocked call
            if let sid = session.sessionId {
                SessionDatabase.shared.recordBudgetDecision(
                    sessionId: sid,
                    toolName: params.name,
                    decision: "blocked"
                )
            }
            return .init(content: [.text(text: "Budget exceeded: \(reason)", annotations: nil, _meta: nil)], isError: true)

        case .warn(let warning):
            // Log the warning, execute the tool, and prepend warning to result
            if let sid = session.sessionId {
                SessionDatabase.shared.recordBudgetDecision(
                    sessionId: sid,
                    toolName: params.name,
                    decision: "warned"
                )
            }
            let result = await executeRoute(params, session: session, context: ctx)
            var content = result.content
            content.insert(.text(text: "[Budget Warning] \(warning)", annotations: nil, _meta: nil), at: 0)
            return await prependSessionContext(.init(content: content, isError: result.isError), session: session)

        case .allow:
            // Log allowed (only if session tracking is active)
            if let sid = session.sessionId {
                SessionDatabase.shared.recordBudgetDecision(
                    sessionId: sid,
                    toolName: params.name,
                    decision: "allowed"
                )
            }
            let result = await executeRoute(params, session: session, context: ctx)
            return await prependSessionContext(result, session: session)
        }
    }

    /// Tool execution timeout in seconds.
    /// Set higher than ExecTool's 30s+5s process timeout so tools with their own
    /// timeout mechanisms can clean up before the outer timeout fires.
    private static let toolTimeoutSeconds: UInt64 = 60

    /// Detached task wrapper for async tool handlers. Inherits actor
    /// isolation rules: handlers can `await` MCPSession actor calls directly.
    private static func executeRoute(_ params: CallTool.Parameters, session: MCPSession, context: ConnectionContext) async -> CallTool.Result {
        let start = Date()
        FileHandle.standardError.write(Data("🟡 [TOOL-START] \(params.name) at \(start)\n".utf8))

        let result: CallTool.Result
        do {
            result = try await withThrowingTaskGroup(of: CallTool.Result.self) { group in
                group.addTask {
                    await dispatchTool(params, session: session, context: context)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: toolTimeoutSeconds * 1_000_000_000)
                    throw ToolTimeoutError()
                }
                // First to complete wins
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        } catch is ToolTimeoutError {
            let elapsed = Date().timeIntervalSince(start)
            Logger.log("tool.timeout", fields: [
                "tool": .string(params.name),
                "duration_ms": .int(Int(elapsed * 1000)),
                "outcome": .string("error"),
            ])
            return .init(content: [.text(text: "Tool timed out after \(toolTimeoutSeconds)s: \(params.name)", annotations: nil, _meta: nil)], isError: true)
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            Logger.log("tool.error", fields: [
                "tool": .string(params.name),
                "duration_ms": .int(Int(elapsed * 1000)),
                "error": .string(error.localizedDescription),
                "outcome": .string("error"),
            ])
            return .init(content: [.text(text: "Tool error: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }

        let elapsed = Date().timeIntervalSince(start)
        Logger.log("tool.done", fields: [
            "tool": .string(params.name),
            "duration_ms": .int(Int(elapsed * 1000)),
            "outcome": .string("success"),
        ])
        return result
    }

    /// Dedicated queue for tools that do heavy synchronous I/O.
    /// Prevents blocking tool handlers (file reads, index builds, process spawns)
    /// from starving Swift's cooperative async thread pool.
    static let toolQueue = DispatchQueue(
        label: "com.senkani.tool-execution",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private static func dispatchTool(_ params: CallTool.Parameters, session: MCPSession, context: ConnectionContext) async -> CallTool.Result {
        // Phase B-i: surface the connection_id to handlers via a TaskLocal so
        // tool implementations don't need a signature change to tag JSONL
        // metric rows. `recordMetrics(connectionId:)` reads the local value.
        // Phase B-ii: same pattern for `toggleOverrides`. The effective<X>Enabled
        // getters on `MCPSession` overlay the per-call override on top of
        // the session-wide default. Nested `withValue` blocks compose; both
        // task-locals are visible to the inner body.
        return await MCPSession.$currentConnectionId.withValue(context.connectionId) {
            await MCPSession.$currentToggleOverrides.withValue(context.toggleOverrides) {
                await dispatchToolBody(params, session: session, context: context)
            }
        }
    }

    private static func dispatchToolBody(_ params: CallTool.Parameters, session: MCPSession, context: ConnectionContext) async -> CallTool.Result {
        // P2-10: canonicalize deprecated argument names before handing to the tool.
        // ArgumentShim returns normalized args + any deprecation warnings. We filter
        // those warnings through `session.noteDeprecation` so only the first sighting
        // of each key per session produces a visible warning block — chat-spam-free.
        let shimmed = ArgumentShim.normalize(toolName: params.name, arguments: params.arguments)
        var firstSightWarnings: [ArgumentShim.Deprecation] = []
        for dep in shimmed.deprecations {
            if await session.noteDeprecation(dep.key) {
                firstSightWarnings.append(dep)
            }
        }
        let normalizedArgs = shimmed.arguments
        let normalizedParams = CallTool.Parameters(name: params.name, arguments: normalizedArgs)

        // Extract arg text before dispatch — covers ALL tools.
        let argText = normalizedArgs?.values.compactMap(\.stringValue).joined(separator: " ") ?? ""

        let result: CallTool.Result
        if let def = ToolRegistry.byName[normalizedParams.name] {
            switch def.handler {
            case .asyncHandler(let h):
                // All tool handlers became async after MCPSession's actor
                // conversion (Phase A) — dispatch directly. Tools that need
                // to off-load heavy synchronous I/O can opt into
                // `toolQueue.async` themselves.
                result = await h(normalizedArgs, session)
            case .syncHandler(let h):
                result = await withCheckedContinuation { continuation in
                    toolQueue.async {
                        let r = h(normalizedArgs, session)
                        continuation.resume(returning: r)
                    }
                }
            }
        } else {
            result = .init(content: [.text(text: "Unknown tool: \(normalizedParams.name)", annotations: nil, _meta: nil)], isError: true)
        }

        // Entity mention tracking + auto-pin detection (~52μs, all tools).
        if !argText.isEmpty {
            // entityTracker is `nonisolated let` — sync call is safe.
            session.entityTracker.observe(text: argText, source: "mcp:\(normalizedParams.name)")
            if await session.autoPinEnabled {
                await session.detectAndQueueAutoPins(argText: argText)
            }
        }

        // P2-10: append deprecation advisories AFTER the primary result so tests
        // indexing `result.content.first` still see the real output. One text block
        // per call, joined by newlines if multiple deprecations fire simultaneously.
        if !firstSightWarnings.isEmpty {
            let body = firstSightWarnings.map(\.message).joined(separator: "\n")
            var content = result.content
            content.append(.text(text: body, annotations: nil, _meta: nil))
            return .init(content: content, isError: result.isError)
        }

        return result
    }

    /// Prepend pinned context blocks and staleness notices to the tool result.
    ///
    /// Order (index 0 = first thing the model reads):
    ///   1. Pinned context blocks (--- @Name (N calls remaining) ---)
    ///   2. Pin expiry notices (for entries whose TTL just hit 0)
    ///   3. Symbol staleness notices
    private static func prependSessionContext(_ result: CallTool.Result, session: MCPSession) async -> CallTool.Result {
        let staleNotices = await session.drainStaleNotices()
        let (pinnedContext, expiryNotices) = session.pinnedContextStore.drain()

        var prefixParts: [String] = []
        if let pc = pinnedContext { prefixParts.append(pc) }
        prefixParts.append(contentsOf: expiryNotices)
        prefixParts.append(contentsOf: staleNotices)

        guard !prefixParts.isEmpty else { return result }
        var content = result.content
        content.insert(.text(text: prefixParts.joined(separator: "\n"), annotations: nil, _meta: nil), at: 0)
        return .init(content: content, isError: result.isError)
    }

    /// Tool catalog. Derived from `ToolRegistry.definitions` so dispatch and
    /// schema can never drift — one source of truth, one record per tool.
    static func allTools() -> [Tool] {
        ToolRegistry.definitions.map(\.schema)
    }
}

// P2-10 ArgumentShim lives in Sources/MCP/ArgumentShim.swift (extracted from
// this file in commit that landed after Wave 1+2 stabilized).
