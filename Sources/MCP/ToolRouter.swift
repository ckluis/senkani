import Foundation
import MCP
import Core

private struct ToolTimeoutError: Error {}

enum ToolRouter {
    static func register(on server: Server, session: MCPSession) async {
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: allTools())
        }

        await server.withMethodHandler(CallTool.self) { params in
            await route(params, session: session)
        }
    }

    static func route(_ params: CallTool.Parameters, session: MCPSession) async -> CallTool.Result {
        FileHandle.standardError.write(Data("🟡 TOOL CALL: \(params.name)\n".utf8))
        // Re-read feature toggles from pane config file (GUI may have changed them)
        session.refreshConfig()
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
            return prependStaleNotices(.init(content: content, isError: result.isError), session: session)

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
            return prependStaleNotices(result, session: session)
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
        switch params.name {
        // Async tools — already non-blocking, run directly in cooperative pool
        case "embed":
            return await EmbedTool.handle(arguments: params.arguments, session: session)
        case "vision":
            return await VisionTool.handle(arguments: params.arguments, session: session)
        // All other tools — potentially blocking, run off cooperative pool
        default:
            return await withCheckedContinuation { continuation in
                toolQueue.async {
                    let result = syncDispatch(params, session: session)
                    continuation.resume(returning: result)
                }
            }
        }
    }

    /// Synchronous tool dispatch. Runs on toolQueue, never on the cooperative pool.
    private static func syncDispatch(_ params: CallTool.Parameters, session: MCPSession) -> CallTool.Result {
        switch params.name {
        case "read":
            return ReadTool.handle(arguments: params.arguments, session: session)
        case "exec":
            return ExecTool.handle(arguments: params.arguments, session: session)
        case "search":
            return SearchTool.handle(arguments: params.arguments, session: session)
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
        default:
            return .init(content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    /// Prepend any pending symbol staleness notices to the tool result.
    private static func prependStaleNotices(_ result: CallTool.Result, session: MCPSession) -> CallTool.Result {
        let notices = session.drainStaleNotices()
        guard !notices.isEmpty else { return result }
        var content = result.content
        let noticeText = notices.joined(separator: "\n")
        content.insert(.text(text: noticeText, annotations: nil, _meta: nil), at: 0)
        return .init(content: content, isError: result.isError)
    }

    static func allTools() -> [Tool] {
        [
            Tool(
                name: "read",
                description: "Read a file. Returns a compact outline (symbols + line numbers) by default — pass full: true to get the complete file content. Outlines are ~90% smaller than full reads. Re-reads of unchanged files return instantly from cache.",
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
                description: "Execute a shell command with output filtering. Applies 24 command-specific rules. Supports background mode for long builds: pass background:true to get a job_id, then poll with job_id to check status.",
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
                description: "Search the project's symbol index by name, kind, file, or container. Returns compact results (~50 tokens) instead of grepping files (~5000 tokens). Auto-indexes on first call.",
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
                description: "Fetch a specific symbol's source code. Reads only the symbol's lines, not the entire file. 50-99% savings vs full file reads.",
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
                name: "explore",
                description: "Show the project's symbol tree structure. Symbols grouped by file with type hierarchy. ~500 tokens for a typical project.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string"), "description": .string("Scope to a subdirectory (optional)")]),
                    ]),
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "outline",
                description: "Show a file's structure without reading it. Returns functions, classes, types with line numbers. ~90% savings vs reading the whole file.",
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
                description: "Session intelligence: view stats, toggle features, manage validators, or reset. Actions: 'stats' (savings), 'config' (feature toggles), 'validators' (list/enable/disable validators), 'reset' (clear cache).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "action": .object(["type": .string("string"), "description": .string("Action: 'stats', 'reset', 'config', 'validators', or 'result'"), "enum": .array([.string("stats"), .string("reset"), .string("config"), .string("validators"), .string("result")])]),
                        "features": .object(["type": .string("object"), "description": .string("For 'config': {filter?: bool, secrets?: bool, indexer?: bool, cache?: bool, all?: bool}")]),
                        "name": .object(["type": .string("string"), "description": .string("For 'validators': validator name to enable/disable")]),
                        "enabled": .object(["type": .string("boolean"), "description": .string("For 'validators': set enabled state")]),
                        "result_id": .object(["type": .string("string"), "description": .string("For 'result': the sandboxed result ID to retrieve (e.g. 'r_abc123def456')")]),
                    ]),
                ]),
                annotations: .init(readOnlyHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "validate",
                description: "Validate code using local compilers/linters. Auto-detects installed tools. Runs ALL enabled validators for the file type (syntax, type, lint, security, format). Config-driven: 30+ validators across 15+ languages. Use session(action: 'validators') to see/toggle available validators.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "file": .object(["type": .string("string"), "description": .string("Path to the file to validate")]),
                        "category": .object(["type": .string("string"), "description": .string("Filter by category: 'syntax', 'type', 'lint', 'security', 'format' (runs all if omitted)")]),
                    ]),
                    "required": .array([.string("file")]),
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "parse",
                description: "Extract structured results from build/test/lint/error output. Returns a concise summary (test pass/fail counts, error locations, stack trace categories) instead of raw output. ~90% token reduction on typical build output.",
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
                description: "Semantic code search using local embeddings on Apple Silicon. Find relevant files by meaning, not just text matching. Returns top matches with similarity scores. Auto-indexes on first call (~90MB model). $0/call.",
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
                description: "Analyze images using a local vision model on Apple Silicon. OCR, UI element detection, screenshot analysis. $0/call vs $0.01+ per GPT-4o vision call. ~1.5GB model, downloads on first use.",
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
                description: "Query the project's dependency graph. 'What imports this module?' and 'What does this file import?' in ~50 tokens instead of reading 20 files.",
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
                description: "Control workspace panes. List, add, remove, or focus panes. Enables orchestration: open browsers for testing, terminals for builds, markdown previews for docs.",
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
                description: "Query file changes detected by FSEvents. Returns changed files since a cursor timestamp. Use instead of re-reading files to check what changed after builds/edits.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "since": .object(["type": .string("string"), "description": .string("ISO8601 timestamp cursor — returns changes after this time. Omit for all recent changes.")]),
                        "glob": .object(["type": .string("string"), "description": .string("Glob pattern to filter paths (e.g. 'Sources/**/*.swift')")]),
                    ]),
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
            ),
        ]
    }
}
