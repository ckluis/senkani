import Foundation

/// Processes hook events from the senkani-hook binary and returns
/// routing decisions (block/passthrough) for Claude Code tool calls.
///
/// Response format follows Claude Code hook protocol:
/// - Passthrough: `{}`
/// - Block: `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "..."}}`
public enum HookRouter {

    /// Process a hook event JSON and return a response JSON.
    /// Returns `{}` (passthrough) for unrecognized or unroutable events.
    public static func handle(eventJSON: Data) -> Data {
        guard let event = try? JSONSerialization.jsonObject(with: eventJSON) as? [String: Any],
              let toolName = event["tool_name"] as? String else {
            return passthroughResponse
        }

        let toolInput = event["tool_input"] as? [String: Any] ?? [:]
        let eventName = event["hook_event_name"] as? String ?? "PreToolUse"
        let projectRoot = event["cwd"] as? String
        let sessionId = event["session_id"] as? String

        // Record the hook event for compliance tracking
        if let sid = sessionId {
            SessionDatabase.shared.recordHookEvent(
                sessionId: sid,
                toolName: toolName,
                eventType: eventName,
                projectRoot: projectRoot
            )
        }

        // PostToolUse: record only, never block (tool already executed)
        guard eventName == "PreToolUse" else {
            return passthroughResponse
        }

        // Budget enforcement on the hook path
        if let root = projectRoot {
            let budget = BudgetConfig.load()
            if budget.dailyLimitCents != nil || budget.weeklyLimitCents != nil {
                let todayCents = SessionDatabase.shared.costForToday()
                let weekCents = SessionDatabase.shared.costForWeek()
                let decision = budget.check(sessionCents: 0, todayCents: todayCents, weekCents: weekCents)
                if case .block(let reason) = decision {
                    return blockResponse(reason, eventName: eventName)
                }
            }
        }

        // Route the tool call
        switch toolName {
        case "Read":
            return handleRead(eventName: eventName)
        case "Bash":
            let command = toolInput["command"] as? String ?? ""
            return handleBash(command: command, eventName: eventName)
        case "Grep":
            let pattern = toolInput["pattern"] as? String ?? ""
            return handleGrep(pattern: pattern, eventName: eventName)
        default:
            return passthroughResponse
        }
    }

    // MARK: - Tool Handlers

    private static func handleRead(eventName: String) -> Data {
        let features = "session caching (re-reads free), compression, secret detection"
        return blockResponse(
            "Use mcp__senkani__read instead of Read. "
            + "Active features: \(features). "
            + "Pass the same file_path as the 'path' argument.",
            eventName: eventName
        )
    }

    private static func handleBash(command: String, eventName: String) -> Data {
        guard !command.isEmpty else { return passthroughResponse }

        // Allowlist: commands that must pass through natively
        if isBashPassthrough(command) {
            return passthroughResponse
        }

        return blockResponse(
            "Use mcp__senkani__exec instead of Bash for this read-only command. "
            + "It filters output (24 command rules, ANSI stripping, dedup, truncation, secret detection). "
            + "Pass command: \"\(command)\"",
            eventName: eventName
        )
    }

    private static func handleGrep(pattern: String, eventName: String) -> Data {
        guard !pattern.isEmpty else { return passthroughResponse }

        // Only intercept simple identifier patterns — regex stays native
        let hasRegexChars = pattern.contains(where: { "\\[](){}|+?^$.*".contains($0) })
        if hasRegexChars { return passthroughResponse }

        // Must look like an identifier: [a-zA-Z_][a-zA-Z0-9_]*
        let isIdentifier = pattern.first.map { $0.isLetter || $0 == "_" } ?? false
            && pattern.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        guard isIdentifier else { return passthroughResponse }

        return blockResponse(
            "Use mcp__senkani__search instead of Grep for symbol lookup. "
            + "Returns compact results (~50 tokens vs ~5000). "
            + "Pass query: \"\(pattern)\". "
            + "For regex or content search, Grep is fine.",
            eventName: eventName
        )
    }

    // MARK: - Bash Allowlist

    /// Commands that must pass through to native Bash (destructive, build, or shell builtins).
    private static func isBashPassthrough(_ command: String) -> Bool {
        let prefixes = [
            // Git (mutating)
            "git commit", "git push", "git add", "git checkout", "git reset",
            "git stash", "git merge", "git rebase",
            // Filesystem mutations
            "rm ", "mv ", "cp ", "mkdir ", "touch ", "chmod ", "chown ",
            // Build systems
            "swift build", "swift test", "swift package", "swift run",
            "npm run", "npm start", "npm install", "yarn ", "bun run", "bun test", "bun install",
            "cargo build", "cargo test", "cargo run", "cargo install",
            "go build", "go test", "go run", "go install",
            "make ", "cmake ", "docker ", "kubectl ",
            // Package managers
            "pip install", "pip3 install", "brew install", "brew upgrade",
            // Shell builtins and dangerous
            "cd ", "export ", "source ", "eval ", "sudo ",
        ]

        for prefix in prefixes {
            if command.hasPrefix(prefix) { return true }
        }

        // Redirects (output to file)
        if command.contains(">") { return true }

        return false
    }

    // MARK: - Response Builders

    static let passthroughResponse = Data("{}".utf8)

    static func blockResponse(_ reason: String, eventName: String = "PreToolUse") -> Data {
        let response: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": eventName,
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            ] as [String: Any]
        ]
        return (try? JSONSerialization.data(withJSONObject: response)) ?? passthroughResponse
    }
}
