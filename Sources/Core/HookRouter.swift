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
            return handleRead(toolInput: toolInput, eventName: eventName, projectRoot: projectRoot, sessionId: sessionId)
        case "Bash":
            let command = toolInput["command"] as? String ?? ""
            return handleBash(command: command, eventName: eventName, projectRoot: projectRoot, sessionId: sessionId)
        case "Grep":
            let pattern = toolInput["pattern"] as? String ?? ""
            return handleGrep(pattern: pattern, eventName: eventName)
        default:
            return passthroughResponse
        }
    }

    // MARK: - Tool Handlers

    private static func handleRead(toolInput: [String: Any], eventName: String, projectRoot: String?, sessionId: String?) -> Data {
        let filePath = toolInput["file_path"] as? String ?? ""

        // Phase I wedge: Re-read suppression
        // If this file was already served by senkani_read AND the file hasn't changed,
        // tell the agent it already has the content — eliminates the tool call entirely.
        if !filePath.isEmpty, let root = projectRoot {
            if let lastRead = SessionDatabase.shared.lastReadTimestamp(filePath: filePath, projectRoot: root) {
                let age = Date().timeIntervalSince(lastRead)

                // Only suppress if the read was recent (within 5 minutes) and the file is unchanged
                if age < 300 {
                    let fullPath = filePath.hasPrefix("/") ? filePath : root + "/" + filePath

                    if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
                       let mtime = attrs[.modificationDate] as? Date,
                       mtime < lastRead {

                        let ageStr = age < 60 ? "\(Int(age))s" : "\(Int(age / 60))m"

                        if let sid = sessionId {
                            SessionDatabase.shared.recordTokenEvent(
                                sessionId: sid,
                                paneId: nil,
                                projectRoot: root,
                                source: "intercept",
                                toolName: "Read",
                                model: nil,
                                inputTokens: 0,
                                outputTokens: 0,
                                savedTokens: estimateFileTokens(at: fullPath),
                                costCents: 0,
                                feature: "reread_suppression",
                                command: filePath
                            )
                        }

                        return blockResponse(
                            "This file was already read \(ageStr) ago via senkani and hasn't changed (mtime unchanged). "
                            + "Use your existing knowledge of this file's content. "
                            + "If you need to re-read it (e.g., after context compaction), call mcp__senkani__read — it returns from cache instantly (0 tokens).",
                            eventName: eventName
                        )
                    }
                }
            }
        }

        // Default: first Read of this file (or file changed since last read)
        let features = "session caching (re-reads free), compression, secret detection"
        return blockResponse(
            "Use mcp__senkani__read instead of Read. "
            + "Active features: \(features). "
            + "Pass the same file_path as the 'path' argument.",
            eventName: eventName
        )
    }

    /// Estimate token count for a file based on size (rough: 1 token per 4 bytes).
    private static func estimateFileTokens(at path: String) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int else { return 0 }
        return size / 4
    }

    private static func handleBash(command: String, eventName: String, projectRoot: String?, sessionId: String?) -> Data {
        guard !command.isEmpty else { return passthroughResponse }

        // Phase I: Command replay — check BEFORE passthrough.
        // If a replayable command was recently run and no files changed, deny with cached result.
        if let root = projectRoot {
            if let replayDeny = checkCommandReplay(command: command, projectRoot: root, sessionId: sessionId, eventName: eventName, db: .shared) {
                return replayDeny
            }
        }

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

    /// Check if a command can be replayed from a recent cached result.
    /// Extracted as internal static for testability — tests pass a temp DB.
    /// Returns a deny response if replay conditions are met, nil otherwise.
    static func checkCommandReplay(command: String, projectRoot: String, sessionId: String?, eventName: String, db: SessionDatabase) -> Data? {
        guard isReplayable(command) else { return nil }

        guard let lastExec = db.lastExecResult(command: command, projectRoot: projectRoot) else { return nil }

        let age = Date().timeIntervalSince(lastExec.timestamp)
        guard age < 300 else { return nil }

        // Check if any files in the project changed since the last exec.
        // macOS updates parent directory mtime when any child file changes.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: projectRoot),
              let dirMtime = attrs[.modificationDate] as? Date,
              dirMtime < lastExec.timestamp else { return nil }

        let ageStr = age < 60 ? "\(Int(age))s" : "\(Int(age / 60))m"
        let preview = lastExec.outputPreview ?? "(no output preview available)"

        // Record the replay intercept event
        if let sid = sessionId {
            let estimatedSaved = (lastExec.outputPreview?.utf8.count ?? 500) / 4
            db.recordTokenEvent(
                sessionId: sid,
                paneId: nil,
                projectRoot: projectRoot,
                source: "intercept",
                toolName: "Bash",
                model: nil,
                inputTokens: 0,
                outputTokens: 0,
                savedTokens: estimatedSaved,
                costCents: 0,
                feature: "command_replay",
                command: command
            )
        }

        return blockResponse(
            "This command was already run \(ageStr) ago and no source files have changed since. "
            + "Previous result: \(preview). "
            + "Run it again only if you've made changes since the last run.",
            eventName: eventName
        )
    }

    /// Commands eligible for replay — deterministic, read-only, no side effects.
    static func isReplayable(_ command: String) -> Bool {
        let prefixes = [
            "swift test", "swift build",
            "npm test", "npm run test", "npx jest", "npx vitest", "npx tsc",
            "cargo test", "cargo build", "cargo check", "cargo clippy",
            "go test", "go build", "go vet",
            "pytest", "python -m pytest", "python -m unittest",
            "make test", "make build", "make check",
            "tsc", "tsc --noEmit",
            "eslint", "ruff", "flake8", "mypy", "pylint", "swiftlint", "rubocop",
        ]
        for prefix in prefixes {
            if command.hasPrefix(prefix) { return true }
        }
        return false
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
