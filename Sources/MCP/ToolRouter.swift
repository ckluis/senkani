import MCP

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
        switch params.name {
        case "senkani_read":
            return ReadTool.handle(arguments: params.arguments, session: session)
        case "senkani_exec":
            return ExecTool.handle(arguments: params.arguments, session: session)
        case "senkani_search":
            return SearchTool.handle(arguments: params.arguments, session: session)
        case "senkani_fetch":
            return FetchTool.handle(arguments: params.arguments, session: session)
        case "senkani_explore":
            return ExploreTool.handle(arguments: params.arguments, session: session)
        case "senkani_session":
            return SessionTool.handle(arguments: params.arguments, session: session)
        case "senkani_validate":
            return ValidateTool.handle(arguments: params.arguments, session: session)
        case "senkani_parse":
            return ParseTool.handle(arguments: params.arguments, session: session)
        case "senkani_embed":
            return await EmbedTool.handle(arguments: params.arguments, session: session)
        case "senkani_vision":
            return await VisionTool.handle(arguments: params.arguments, session: session)
        default:
            return .init(content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    static func allTools() -> [Tool] {
        [
            Tool(
                name: "senkani_read",
                description: "Read a file with compression (ANSI strip, blank collapse, secret detection) and session caching. Re-reads of unchanged files return instantly. 50-99% token savings.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string"), "description": .string("File path (absolute or relative to project root)")]),
                        "offset": .object(["type": .string("integer"), "description": .string("Start line number (1-based)")]),
                        "limit": .object(["type": .string("integer"), "description": .string("Maximum lines to read")]),
                    ]),
                    "required": .array([.string("path")]),
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "senkani_exec",
                description: "Execute a shell command with output filtering. Applies 24 command-specific rules (git, npm, cargo, docker, etc.), strips ANSI, deduplicates, truncates. 60-90% savings on build/test output.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "command": .object(["type": .string("string"), "description": .string("Shell command to execute")]),
                    ]),
                    "required": .array([.string("command")]),
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),
            Tool(
                name: "senkani_search",
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
                name: "senkani_fetch",
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
                name: "senkani_explore",
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
                name: "senkani_session",
                description: "Session intelligence: view stats, toggle features, manage validators, or reset. Actions: 'stats' (savings), 'config' (feature toggles), 'validators' (list/enable/disable validators), 'reset' (clear cache).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "action": .object(["type": .string("string"), "description": .string("Action: 'stats', 'reset', 'config', or 'validators'"), "enum": .array([.string("stats"), .string("reset"), .string("config"), .string("validators")])]),
                        "features": .object(["type": .string("object"), "description": .string("For 'config': {filter?: bool, secrets?: bool, indexer?: bool, cache?: bool, all?: bool}")]),
                        "name": .object(["type": .string("string"), "description": .string("For 'validators': validator name to enable/disable")]),
                        "enabled": .object(["type": .string("boolean"), "description": .string("For 'validators': set enabled state")]),
                    ]),
                ]),
                annotations: .init(readOnlyHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "senkani_validate",
                description: "Validate code using local compilers/linters. Auto-detects installed tools. Runs ALL enabled validators for the file type (syntax, type, lint, security, format). Config-driven: 30+ validators across 15+ languages. Use senkani_session(action: 'validators') to see/toggle available validators.",
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
                name: "senkani_parse",
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
                name: "senkani_embed",
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
                name: "senkani_vision",
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
        ]
    }
}
