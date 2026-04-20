import Foundation
import MCP
import Core

private struct ToolTimeoutError: Error {}

enum ToolRouter {
    static func register(on server: Server, session: MCPSession) async {
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: advertisedTools(for: session.effectiveSet))
        }

        await server.withMethodHandler(CallTool.self) { params in
            await route(params, session: session)
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

    static func route(_ params: CallTool.Parameters, session: MCPSession) async -> CallTool.Result {
        FileHandle.standardError.write(Data("🟡 TOOL CALL: \(params.name)\n".utf8))
        // Re-read feature toggles from pane config file (GUI may have changed them)
        session.refreshConfig()
        // Phase S.1 — manifest gating. If a manifest is present and does
        // not enable this tool, return a structured error pointing the
        // caller at the Skills pane toggle rather than silently dispatching.
        // No manifest present → full surface (today's behavior).
        let effective = session.effectiveSet
        if effective.manifestPresent, !effective.isToolEnabled(params.name) {
            return .init(content: [.text(
                text: "Tool '\(params.name)' is not enabled in this project's manifest. Enable it in the Skills pane (or add it to .senkani/senkani.json).",
                annotations: nil, _meta: nil)],
                isError: true)
        }
        // SECURITY: Budget enforcement — non-bypassable gate before any tool execution.
        // This is the only routing path, so all tool calls pass through this check.
        let budgetDecision = session.checkBudget()
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
            let result = await executeRoute(params, session: session)
            var content = result.content
            content.insert(.text(text: "[Budget Warning] \(warning)", annotations: nil, _meta: nil), at: 0)
            return prependSessionContext(.init(content: content, isError: result.isError), session: session)

        case .allow:
            // Log allowed (only if session tracking is active)
            if let sid = session.sessionId {
                SessionDatabase.shared.recordBudgetDecision(
                    sessionId: sid,
                    toolName: params.name,
                    decision: "allowed"
                )
            }
            let result = await executeRoute(params, session: session)
            return prependSessionContext(result, session: session)
        }
    }

    /// Tool execution timeout in seconds.
    /// Set higher than ExecTool's 30s+5s process timeout so tools with their own
    /// timeout mechanisms can clean up before the outer timeout fires.
    private static let toolTimeoutSeconds: UInt64 = 60

    private static func executeRoute(_ params: CallTool.Parameters, session: MCPSession) async -> CallTool.Result {
        let start = Date()
        FileHandle.standardError.write(Data("🟡 [TOOL-START] \(params.name) at \(start)\n".utf8))

        let result: CallTool.Result
        do {
            result = try await withThrowingTaskGroup(of: CallTool.Result.self) { group in
                group.addTask {
                    await dispatchTool(params, session: session)
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
            FileHandle.standardError.write(Data("🔴 [TOOL-TIMEOUT] \(params.name) after \(String(format: "%.1f", elapsed))s\n".utf8))
            return .init(content: [.text(text: "Tool timed out after \(toolTimeoutSeconds)s: \(params.name)", annotations: nil, _meta: nil)], isError: true)
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            FileHandle.standardError.write(Data("🔴 [TOOL-ERROR] \(params.name) after \(String(format: "%.1f", elapsed))s: \(error)\n".utf8))
            return .init(content: [.text(text: "Tool error: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }

        let elapsed = Date().timeIntervalSince(start)
        FileHandle.standardError.write(Data("🟢 [TOOL-DONE] \(params.name) in \(String(format: "%.2f", elapsed))s\n".utf8))
        return result
    }

    /// Dedicated queue for tools that do heavy synchronous I/O.
    /// Prevents blocking tool handlers (file reads, index builds, process spawns)
    /// from starving Swift's cooperative async thread pool.
    private static let toolQueue = DispatchQueue(
        label: "com.senkani.tool-execution",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private static func dispatchTool(_ params: CallTool.Parameters, session: MCPSession) async -> CallTool.Result {
        // P2-10: canonicalize deprecated argument names before handing to the tool.
        // ArgumentShim returns normalized args + any deprecation warnings. We filter
        // those warnings through `session.noteDeprecation` so only the first sighting
        // of each key per session produces a visible warning block — chat-spam-free.
        let shimmed = ArgumentShim.normalize(toolName: params.name, arguments: params.arguments)
        let firstSightWarnings = shimmed.deprecations.filter { session.noteDeprecation($0.key) }
        let normalizedArgs = shimmed.arguments
        let normalizedParams = CallTool.Parameters(name: params.name, arguments: normalizedArgs)

        // Extract arg text before dispatch — covers ALL tools (async and sync).
        // Previously only ran in the default/sync path, silently skipping embed/vision/search.
        let argText = normalizedArgs?.values.compactMap(\.stringValue).joined(separator: " ") ?? ""

        let result: CallTool.Result
        switch normalizedParams.name {
        // Async tools — already non-blocking, run directly in cooperative pool
        case "embed":
            result = await EmbedTool.handle(arguments: normalizedArgs, session: session)
        case "vision":
            result = await VisionTool.handle(arguments: normalizedArgs, session: session)
        case "search":
            result = await SearchTool.handle(arguments: normalizedArgs, session: session)
        case "web":
            result = await WebFetchTool.handle(arguments: normalizedArgs, session: session)
        case "repo":
            result = await RepoTool.handle(arguments: normalizedArgs, session: session)
        case "bundle":
            result = await BundleTool.handle(arguments: normalizedArgs, session: session)
        // All other tools — potentially blocking, run off cooperative pool
        default:
            result = await withCheckedContinuation { continuation in
                toolQueue.async {
                    let r = syncDispatch(normalizedParams, session: session)
                    continuation.resume(returning: r)
                }
            }
        }

        // Entity mention tracking + auto-pin detection (~52μs, all tools).
        if !argText.isEmpty {
            session.entityTracker.observe(text: argText, source: "mcp:\(normalizedParams.name)")
            if session.autoPinEnabled {
                session.detectAndQueueAutoPins(argText: argText)
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

    /// Synchronous tool dispatch. Runs on toolQueue, never on the cooperative pool.
    private static func syncDispatch(_ params: CallTool.Parameters, session: MCPSession) -> CallTool.Result {
        switch params.name {
        case "read":
            return ReadTool.handle(arguments: params.arguments, session: session)
        case "exec":
            return ExecTool.handle(arguments: params.arguments, session: session)
        case "fetch":
            return FetchTool.handle(arguments: params.arguments, session: session)
        case "explore":
            return ExploreTool.handle(arguments: params.arguments, session: session)
        case "outline":
            return OutlineTool.handle(arguments: params.arguments, session: session)
        case "session":
            return SessionTool.handle(arguments: params.arguments, session: session)
        case "validate":
            return ValidateTool.handle(arguments: params.arguments, session: session)
        case "parse":
            return ParseTool.handle(arguments: params.arguments, session: session)
        case "pane":
            return PaneControlTool.handle(arguments: params.arguments, session: session)
        case "deps":
            return DepsTool.handle(arguments: params.arguments, session: session)
        case "watch":
            return WatchTool.handle(arguments: params.arguments, session: session)
        case "knowledge":
            return KnowledgeTool.handle(arguments: params.arguments, session: session)
        case "version":
            return VersionTool.handle(arguments: params.arguments, session: session)
        default:
            return .init(content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    /// Prepend pinned context blocks and staleness notices to the tool result.
    ///
    /// Order (index 0 = first thing the model reads):
    ///   1. Pinned context blocks (--- @Name (N calls remaining) ---)
    ///   2. Pin expiry notices (for entries whose TTL just hit 0)
    ///   3. Symbol staleness notices
    private static func prependSessionContext(_ result: CallTool.Result, session: MCPSession) -> CallTool.Result {
        let staleNotices = session.drainStaleNotices()
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

    static func allTools() -> [Tool] {
        [
            Tool(
                name: "read",
                description: "Read a file. Returns compact outline (symbols + line numbers) by default; pass full:true for complete content. Outlines are ~90% smaller. Unchanged files served from cache.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string"), "description": .string("File path (absolute or relative to project root)")]),
                        "full": .object(["type": .string("boolean"), "description": .string("Return full file content instead of outline (default: false)")]),
                        "offset": .object(["type": .string("integer"), "description": .string("Start line number (1-based). Implies full read.")]),
                        "limit": .object(["type": .string("integer"), "description": .string("Maximum lines to read. Implies full read.")]),
                    ]),
                    "required": .array([.string("path")]),
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "exec",
                description: "Execute a shell command with output filtering. Background mode: pass background:true for a job_id, then poll with job_id.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "command": .object(["type": .string("string"), "description": .string("Shell command to execute")]),
                        "sandbox": .object(["type": .string("string"), "description": .string("Output sandbox mode: 'auto' (default), 'always', or 'never'")]),
                        "background": .object(["type": .string("boolean"), "description": .string("Run in background, return job_id immediately (default: false)")]),
                        "job_id": .object(["type": .string("string"), "description": .string("Poll or kill an existing background job by ID")]),
                        "kill": .object(["type": .string("boolean"), "description": .string("Send SIGTERM to a background job (use with job_id)")]),
                    ]),
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),
            Tool(
                name: "search",
                description: "Search the symbol index by name, kind, file, or container. ~50 tokens/result vs grepping files. Auto-indexes on first call.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string"), "description": .string("Symbol name to search (substring match)")]),
                        "kind": .object(["type": .string("string"), "description": .string("Filter by kind: function, class, struct, enum, protocol, method")]),
                        "file": .object(["type": .string("string"), "description": .string("Filter by file path (substring match)")]),
                        "container": .object(["type": .string("string"), "description": .string("Filter by enclosing type name")]),
                    ]),
                    "required": .array([.string("query")]),
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "fetch",
                description: "Fetch a symbol's source lines. Reads only that symbol, not the whole file. 50-99% savings vs full reads.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string"), "description": .string("Symbol name to fetch (exact match, case-insensitive)")]),
                    ]),
                    "required": .array([.string("name")]),
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "web",
                description: "Render a web page with full JavaScript execution and return a compact semantic tree (headings, text, links, buttons, form fields). Works on single-page applications (React/Vue/Next.js). ~99% token savings vs. raw HTML. Use format:'html' to retrieve raw content (always sandboxed).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "url":     .object(["type": .string("string"),  "description": .string("HTTP or HTTPS URL to render. file:// is not allowed — read local files via senkani_read.")]),
                        "timeout": .object(["type": .string("integer"), "description": .string("Load timeout in seconds, 5–60 (default: 15)")]),
                        "format":  .object(["type": .string("string"),  "description": .string("Output: 'tree' (semantic AXTree, default), 'text' (plain text), 'html' (raw HTML, always sandboxed)")]),
                    ]),
                    "required": .array([.string("url")]),
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: false, openWorldHint: true)
            ),
            Tool(
                name: "explore",
                description: "Symbol tree grouped by file with type hierarchy. Shows 30 files by default; use limit:0 for all. Filter symbols by kind: 'class,struct,protocol'.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string"), "description": .string("Scope to a subdirectory (optional)")]),
                        "limit": .object(["type": .string("integer"), "description": .string("Max files to show (default: 30). Use limit:0 for all.")]),
                        "kinds": .object(["type": .string("string"), "description": .string("Comma-separated kind filter: 'class,struct,protocol,enum' etc.")]),
                    ]),
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "outline",
                description: "A file's structure without reading it. Functions, classes, types with line numbers. ~90% savings vs full reads.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "file": .object(["type": .string("string"), "description": .string("File path or name (substring match, e.g. 'PaneModel.swift')")]),
                    ]),
                    "required": .array([.string("file")]),
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "session",
                description: "Session stats, feature toggles, validator management, and @-mention context pinning. Actions: stats · config · validators · reset · result · pin · unpin · pins.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "action": .object(["type": .string("string"), "description": .string("Action: 'stats', 'reset', 'config', 'validators', 'result', 'pin', 'unpin', or 'pins'"), "enum": .array([.string("stats"), .string("reset"), .string("config"), .string("validators"), .string("result"), .string("pin"), .string("unpin"), .string("pins")])]),
                        "features": .object(["type": .string("object"), "description": .string("For 'config': {filter?: bool, secrets?: bool, indexer?: bool, cache?: bool, terse?: bool, auto_pin?: bool, budget_session_cents?: int (0 clears)}")]),
                        "name": .object(["type": .string("string"), "description": .string("For 'pin'/'unpin': symbol name to pin or unpin. For 'validators': validator name to enable/disable.")]),
                        "ttl": .object(["type": .string("integer"), "description": .string("For 'pin': how many tool calls to keep the context pinned (1–50, default 20)")]),
                        "enabled": .object(["type": .string("boolean"), "description": .string("For 'validators': set enabled state")]),
                        "result_id": .object(["type": .string("string"), "description": .string("For 'result': the sandboxed result ID to retrieve (e.g. 'r_abc123def456')")]),
                    ]),
                ]),
                annotations: .init(readOnlyHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "validate",
                description: "Run local validators (syntax, type, lint, security, format). Returns summary by default; pass full:true for complete output. session(action:'validators') to configure.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "file": .object(["type": .string("string"), "description": .string("Path to the file to validate")]),
                        "category": .object(["type": .string("string"), "description": .string("Filter by category: 'syntax', 'type', 'lint', 'security', 'format' (runs all if omitted)")]),
                        "full": .object(["type": .string("boolean"), "description": .string("Return complete output: all validators including passing ones, full error text. Default false (summary only — failing validators + counts).")]),
                        "detail": .object(["type": .string("string"), "description": .string("[deprecated — use 'full' instead] Output level: 'summary' (default) or 'full'. Removed in tool_schemas_version 2.")]),
                    ]),
                    "required": .array([.string("file")]),
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "parse",
                description: "Extract structured results from build/test/lint output. Returns pass/fail counts, error locations — ~90% token reduction on typical build output.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "output": .object(["type": .string("string"), "description": .string("Raw build, test, lint, or error output to parse")]),
                        "type": .object(["type": .string("string"), "description": .string("Output type: 'test', 'build', 'lint', 'error', or omit for auto-detection")]),
                    ]),
                    "required": .array([.string("output")]),
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "embed",
                description: "Semantic code search via local embeddings on Apple Silicon. Returns top matches by meaning. Auto-indexes on first call.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string"), "description": .string("Natural language query describing what you're looking for")]),
                        "top_k": .object(["type": .string("integer"), "description": .string("Number of results (default: 5)")]),
                        "file_filter": .object(["type": .string("string"), "description": .string("Filter files by path substring")]),
                    ]),
                    "required": .array([.string("query")]),
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "vision",
                description: "Analyze images with a local vision model on Apple Silicon. OCR, UI element detection, screenshot analysis.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "image": .object(["type": .string("string"), "description": .string("Path to image file (PNG, JPG, etc.)")]),
                        "prompt": .object(["type": .string("string"), "description": .string("What to analyze (default: describe the image)")]),
                    ]),
                    "required": .array([.string("image")]),
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "deps",
                description: "Query the dependency graph. 'What imports this module?' and 'What does this file import?' in ~50 tokens.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "target": .object(["type": .string("string"), "description": .string("Module name or file path to query (e.g. 'Core', 'SessionDatabase.swift')")]),
                        "direction": .object(["type": .string("string"), "description": .string("'imports' (what does target import), 'importedBy' (what imports target), or 'both' (default)")]),
                    ]),
                    "required": .array([.string("target")]),
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "pane",
                description: "Control workspace panes: list, add, remove, focus. Open browsers, terminals, or markdown previews for orchestration.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "action": .object(["type": .string("string"), "description": .string("Action: 'list', 'add', 'remove', 'set_active'"), "enum": .array([.string("list"), .string("add"), .string("remove"), .string("set_active")])]),
                        "type": .object(["type": .string("string"), "description": .string("Pane type for 'add': terminal, browser, markdownPreview, htmlPreview, scratchpad, logViewer, diffViewer")]),
                        "title": .object(["type": .string("string"), "description": .string("Pane title for 'add'")]),
                        "command": .object(["type": .string("string"), "description": .string("Initial command for terminal panes")]),
                        "url": .object(["type": .string("string"), "description": .string("URL for browser panes")]),
                        "pane_id": .object(["type": .string("string"), "description": .string("Pane ID for 'remove' and 'set_active'")]),
                    ]),
                    "required": .array([.string("action")]),
                ]),
                annotations: .init(readOnlyHint: false, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "watch",
                description: "File changes via FSEvents. Returns paths changed since a cursor timestamp. Use after builds/edits instead of re-reading files.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "since": .object(["type": .string("string"), "description": .string("ISO8601 timestamp cursor — returns changes after this time. Omit for all recent changes.")]),
                        "glob": .object(["type": .string("string"), "description": .string("Glob pattern to filter paths (e.g. 'Sources/**/*.swift')")]),
                    ]),
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "version",
                description: "Return senkani server/tool-schemas/DB-schema versions + list of exposed tools. Use for version negotiation: cache tool schemas keyed on tool_schemas_version.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "repo",
                description: "Query any public GitHub repo without cloning. Actions: tree (list files), file (fetch content), readme (GitHub-rendered README), search (code search scoped to the repo). Anonymous by default (60 req/h); set GITHUB_TOKEN env for 5000 req/h. Host-allowlisted to api.github.com + raw.githubusercontent.com (SSRF defense). Every response passes through SecretDetector before return. In-memory cache with 15min TTL.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "action": .object(["type": .string("string"), "description": .string("tree | file | readme | search"), "enum": .array([.string("tree"), .string("file"), .string("readme"), .string("search")])]),
                        "repo": .object(["type": .string("string"), "description": .string("owner/name identifier — strictly validated. Example: 'react-router/react-router'.")]),
                        "ref": .object(["type": .string("string"), "description": .string("Git ref (branch, tag, or commit SHA). Optional — defaults to HEAD / default branch.")]),
                        "path": .object(["type": .string("string"), "description": .string("File path for `file` action. Relative, no leading /, no `..` components.")]),
                        "query": .object(["type": .string("string"), "description": .string("Search query for `search` action. Passed verbatim to GitHub code search, scoped to `repo:owner/name`.")]),
                        "limit": .object(["type": .string("integer"), "description": .string("Max results for `search`. Clamped to [1, 30].")]),
                    ]),
                    "required": .array([.string("action"), .string("repo")]),
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: true)
            ),
            Tool(
                name: "bundle",
                description: "Budget-bounded repo snapshot as a single markdown (or JSON) document. Local mode composes symbol outlines + dep graph + KB entities + README (critical context first). Remote mode (pass remote:\"owner/name\") snapshots any public GitHub repo via senkani_repo — same host allowlist + SecretDetector. Params: root, max_tokens, include, format (markdown|json), remote (owner/name), ref (branch/tag/SHA for --remote).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "root": .object(["type": .string("string"), "description": .string("Project root override. Defaults to the session project. Must be an existing directory you own. Ignored when `remote` is set.")]),
                        "max_tokens": .object(["type": .string("integer"), "description": .string("Token budget (char/4 approx). Default 20000. Clamped to [500, 200000].")]),
                        "include": .object(["type": .string("array"), "items": .object(["type": .string("string"), "enum": .array([.string("outlines"), .string("deps"), .string("kb"), .string("readme")])]), "description": .string("Subset of sections to include. Default: all four in canonical order (outlines → deps → kb → readme). Order of values here does not affect output ordering.")]),
                        "format": .object(["type": .string("string"), "description": .string("Output format: 'markdown' (default) or 'json' (stable BundleDocument schema).")]),
                        "remote": .object(["type": .string("string"), "description": .string("Bundle a public GitHub repo (owner/name) instead of the local project. Validated strictly; host-allowlisted.")]),
                        "ref": .object(["type": .string("string"), "description": .string("Git ref (branch/tag/SHA) for `remote` bundles. Defaults to HEAD / default branch.")]),
                    ]),
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "knowledge",
                description: "Query the project knowledge graph. Actions: status · get · search · list · relate · mine · propose · commit · discard · graph. get defaults to summary; pass full:true for complete output.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "action": .object(["type": .string("string"), "description": .string("Action: status|get|search|list|relate|mine|propose|commit|discard|graph"), "enum": .array([.string("status"), .string("get"), .string("search"), .string("list"), .string("relate"), .string("mine"), .string("propose"), .string("commit"), .string("discard"), .string("graph")])]),
                        "entity": .object(["type": .string("string"), "description": .string("Entity name for get, relate, graph, propose, commit, discard actions")]),
                        "query": .object(["type": .string("string"), "description": .string("Full-text search query for 'search' action")]),
                        "sort": .object(["type": .string("string"), "description": .string("Sort for 'list': 'mentions' (default), 'name', 'staleness', 'recent'")]),
                        "understanding": .object(["type": .string("string"), "description": .string("Enriched understanding text for 'propose' action")]),
                        "full": .object(["type": .string("boolean"), "description": .string("For 'get': return complete output (understanding, relations, decisions). Default false.")]),
                        "detail": .object(["type": .string("string"), "description": .string("[deprecated — use 'full' instead] Output level for 'get': 'summary' (default) or 'full'. Removed in tool_schemas_version 2.")]),
                    ]),
                    "required": .array([.string("action")]),
                ]),
                annotations: .init(readOnlyHint: false, idempotentHint: false, openWorldHint: false)
            ),
        ]
    }
}

// P2-10 ArgumentShim lives in Sources/MCP/ArgumentShim.swift (extracted from
// this file in commit that landed after Wave 1+2 stabilized).
