import Testing
import Foundation
@testable import Core

// MARK: - Helpers

private func makeEvent(
    toolName: String,
    toolInput: [String: Any] = [:],
    eventName: String = "PreToolUse",
    sessionId: String? = nil,
    cwd: String? = nil
) -> Data {
    var event: [String: Any] = [
        "tool_name": toolName,
        "hook_event_name": eventName,
    ]
    if !toolInput.isEmpty { event["tool_input"] = toolInput }
    if let sid = sessionId { event["session_id"] = sid }
    if let cwd = cwd { event["cwd"] = cwd }
    return try! JSONSerialization.data(withJSONObject: event)
}

private func parseResponse(_ data: Data) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

// MARK: - Suite 1: Protocol Conformance

@Suite("HookRouter — Protocol Conformance")
struct HookRouterProtocolTests {

    @Test func passthroughReturnsEmptyJSON() {
        // "Write" is not in the Read/Bash/Grep intercept list
        let response = HookRouter.handle(eventJSON: makeEvent(toolName: "Write"))
        let json = String(data: response, encoding: .utf8)
        #expect(json == "{}", "Passthrough should be exactly '{}'")
    }

    @Test func blockReturnsCorrectClaudeCodeFormat() {
        let response = HookRouter.handle(eventJSON: makeEvent(toolName: "Read"))
        guard let json = parseResponse(response) else {
            Issue.record("Response is not valid JSON")
            return
        }

        // Root must have "hookSpecificOutput"
        guard let hookOutput = json["hookSpecificOutput"] as? [String: Any] else {
            Issue.record("Missing 'hookSpecificOutput' key in response")
            return
        }

        #expect(hookOutput["hookEventName"] as? String == "PreToolUse")
        #expect(hookOutput["permissionDecision"] as? String == "deny")

        let reason = hookOutput["permissionDecisionReason"] as? String ?? ""
        #expect(reason.contains("mcp__senkani__read"), "Reason should mention the alternative tool")
    }

    @Test func postToolUseNeverBlocks() {
        // PostToolUse for Read should still passthrough (tool already executed)
        let response = HookRouter.handle(eventJSON: makeEvent(toolName: "Read", eventName: "PostToolUse"))
        let json = String(data: response, encoding: .utf8)
        #expect(json == "{}", "PostToolUse should never block")
    }
}

// MARK: - Suite 2: Routing Logic

@Suite("HookRouter — Routing Logic")
struct HookRouterRoutingTests {

    @Test func bashPassthroughForBuildCommands() {
        let response = HookRouter.handle(eventJSON: makeEvent(
            toolName: "Bash",
            toolInput: ["command": "swift build -c release"]
        ))
        let json = String(data: response, encoding: .utf8)
        #expect(json == "{}", "Build commands should pass through")
    }

    @Test func bashBlocksForReadOnlyCommands() {
        let response = HookRouter.handle(eventJSON: makeEvent(
            toolName: "Bash",
            toolInput: ["command": "git status"]
        ))
        guard let json = parseResponse(response),
              let hookOutput = json["hookSpecificOutput"] as? [String: Any] else {
            Issue.record("Expected block response with hookSpecificOutput")
            return
        }

        #expect(hookOutput["permissionDecision"] as? String == "deny")
        let reason = hookOutput["permissionDecisionReason"] as? String ?? ""
        #expect(reason.contains("mcp__senkani__exec"), "Should suggest senkani exec")
    }

    @Test func grepPassthroughForRegex() {
        let response = HookRouter.handle(eventJSON: makeEvent(
            toolName: "Grep",
            toolInput: ["pattern": "log.*Error"]
        ))
        let json = String(data: response, encoding: .utf8)
        #expect(json == "{}", "Regex patterns should pass through to native Grep")
    }

    @Test func grepBlocksForIdentifier() {
        let response = HookRouter.handle(eventJSON: makeEvent(
            toolName: "Grep",
            toolInput: ["pattern": "SessionDatabase"]
        ))
        guard let json = parseResponse(response),
              let hookOutput = json["hookSpecificOutput"] as? [String: Any] else {
            Issue.record("Expected block response for identifier search")
            return
        }

        #expect(hookOutput["permissionDecision"] as? String == "deny")
        let reason = hookOutput["permissionDecisionReason"] as? String ?? ""
        #expect(reason.contains("mcp__senkani__search"), "Should suggest senkani search")
    }
}

// MARK: - Suite 3: Metrics & Performance

@Suite("HookRouter — Metrics & Performance")
struct HookRouterMetricsTests {

    @Test func hookEventRecordedToDatabase() {
        let dbPath = "/tmp/senkani-test-hookrouter-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: dbPath)
        defer {
            try? FileManager.default.removeItem(atPath: dbPath)
            try? FileManager.default.removeItem(atPath: dbPath + "-wal")
            try? FileManager.default.removeItem(atPath: dbPath + "-shm")
        }

        // Record a hook event directly (same call HookRouter makes)
        db.recordHookEvent(
            sessionId: "test-hook-session",
            toolName: "Read",
            eventType: "PreToolUse",
            projectRoot: "/tmp/hooktest"
        )

        // Flush async write by calling a sync read
        let stats = db.tokenStatsForProject("/tmp/hooktest")
        #expect(stats.commandCount == 1, "Hook event should be recorded")
    }

    @Test func performanceUnder5ms() {
        let clock = ContinuousClock()
        let event = makeEvent(toolName: "Write") // passthrough — fastest path

        let elapsed = clock.measure {
            for _ in 0..<100 {
                _ = HookRouter.handle(eventJSON: event)
            }
        }

        let avgMs = Double(elapsed.components.attoseconds) / 1e15 / 100.0
        #expect(avgMs < 5.0, "Average hook latency should be under 5ms, was \(String(format: "%.2f", avgMs))ms")
    }
}

// MARK: - Suite 4: Trivial Routing (Bach G5)

/// Layer-3 interception: commands with trivially-computable answers
/// (pwd, whoami, …) are answered locally without spawning a shell.
@Suite("HookRouter — Trivial Routing")
struct HookRouterTrivialRoutingTests {

    @Test func pwdReturnsProjectRoot() {
        let reply = HookRouter.checkTrivialRouting(
            command: "pwd",
            projectRoot: "/tmp/hr-trivial-test",
            sessionId: nil,
            eventName: "PreToolUse"
        )
        guard let data = reply, let json = parseResponse(data),
              let hook = json["hookSpecificOutput"] as? [String: Any],
              let reason = hook["permissionDecisionReason"] as? String
        else {
            Issue.record("expected deny with result, got \(String(describing: reply))")
            return
        }
        #expect(hook["permissionDecision"] as? String == "deny")
        #expect(reason.contains("/tmp/hr-trivial-test"),
                "pwd answer must include the project root, got: \(reason)")
    }

    @Test func whoamiAnswered() {
        let reply = HookRouter.checkTrivialRouting(
            command: "whoami",
            projectRoot: "/tmp/x",
            sessionId: nil,
            eventName: "PreToolUse"
        )
        #expect(reply != nil, "whoami should be answered locally")
    }

    @Test func echoStringAnswered() {
        let reply = HookRouter.checkTrivialRouting(
            command: "echo hello",
            projectRoot: "/tmp/x",
            sessionId: nil,
            eventName: "PreToolUse"
        )
        guard let data = reply, let json = parseResponse(data),
              let hook = json["hookSpecificOutput"] as? [String: Any],
              let reason = hook["permissionDecisionReason"] as? String
        else { Issue.record("expected echo answer"); return }
        #expect(reason.contains("hello"))
    }

    @Test func echoQuotedString() {
        let reply = HookRouter.checkTrivialRouting(
            command: "echo \"hi world\"",
            projectRoot: "/tmp/x",
            sessionId: nil,
            eventName: "PreToolUse"
        )
        guard let data = reply, let json = parseResponse(data),
              let hook = json["hookSpecificOutput"] as? [String: Any],
              let reason = hook["permissionDecisionReason"] as? String
        else { Issue.record("expected echo answer"); return }
        #expect(reason.contains("hi world"),
                "surrounding quotes must be stripped")
    }

    // MARK: Shell-metachar rejections

    @Test func pipeRejected() {
        let reply = HookRouter.checkTrivialRouting(
            command: "ls | wc -l",
            projectRoot: "/tmp/x",
            sessionId: nil,
            eventName: "PreToolUse"
        )
        #expect(reply == nil, "pipe must fall through to native Bash")
    }

    @Test func semicolonRejected() {
        #expect(HookRouter.checkTrivialRouting(
            command: "ls ; pwd",
            projectRoot: "/tmp/x",
            sessionId: nil,
            eventName: "PreToolUse"
        ) == nil)
    }

    @Test func subshellRejected() {
        #expect(HookRouter.checkTrivialRouting(
            command: "echo $(pwd)",
            projectRoot: "/tmp/x",
            sessionId: nil,
            eventName: "PreToolUse"
        ) == nil)
    }

    @Test func backtickRejected() {
        #expect(HookRouter.checkTrivialRouting(
            command: "echo `date`",
            projectRoot: "/tmp/x",
            sessionId: nil,
            eventName: "PreToolUse"
        ) == nil)
    }

    @Test func redirectRejected() {
        #expect(HookRouter.checkTrivialRouting(
            command: "ls > /tmp/out",
            projectRoot: "/tmp/x",
            sessionId: nil,
            eventName: "PreToolUse"
        ) == nil)
    }

    @Test func echoWithVariableExpansionRejected() {
        // $VAR expansion can't be answered locally — let Bash handle it.
        #expect(HookRouter.checkTrivialRouting(
            command: "echo $HOME",
            projectRoot: "/tmp/x",
            sessionId: nil,
            eventName: "PreToolUse"
        ) == nil)
    }

    @Test func lsWithFlagsRejected() {
        // ls with flags (-la, -al, etc.) falls through — we only answer
        // bare `ls` or `ls <simple-path>`.
        #expect(HookRouter.checkTrivialRouting(
            command: "ls -la",
            projectRoot: "/tmp/x",
            sessionId: nil,
            eventName: "PreToolUse"
        ) == nil)
    }
}

// MARK: - Suite 5: Replay Classification

/// `isReplayable` is the gate for Layer-3 command replay. A
/// command is replayable iff it's a known deterministic read-only
/// operation. Mutating or untrusted commands must never be replayed.
@Suite("HookRouter — Replay Classification")
struct HookRouterReplayClassificationTests {

    @Test func swiftTestIsReplayable() {
        #expect(HookRouter.isReplayable("swift test"))
        #expect(HookRouter.isReplayable("swift test --filter Foo"))
    }

    @Test func commonTestRunnersAreReplayable() {
        for cmd in ["npm test", "npx jest", "cargo test --release",
                    "go test ./...", "pytest tests/"] {
            #expect(HookRouter.isReplayable(cmd), "\(cmd) should be replayable")
        }
    }

    @Test func lintersAreReplayable() {
        for cmd in ["eslint src/", "ruff check .", "mypy .", "swiftlint"] {
            #expect(HookRouter.isReplayable(cmd), "\(cmd) should be replayable")
        }
    }

    @Test func gitMutationsAreNotReplayable() {
        for cmd in ["git push", "git commit -m msg", "git reset --hard"] {
            #expect(!HookRouter.isReplayable(cmd),
                    "\(cmd) is mutating — must NOT be replayable")
        }
    }

    @Test func destructiveShellIsNotReplayable() {
        #expect(!HookRouter.isReplayable("rm -rf /tmp/foo"))
        #expect(!HookRouter.isReplayable("sudo reboot"))
    }

    @Test func unknownCommandIsNotReplayable() {
        #expect(!HookRouter.isReplayable("my-custom-tool"))
    }
}

// MARK: - Suite 6: Protocol Edge Cases

@Suite("HookRouter — Protocol Edge Cases")
struct HookRouterProtocolEdgeCaseTests {

    @Test func malformedJSONReturnsPassthrough() {
        let response = HookRouter.handle(eventJSON: Data("not json {{".utf8))
        #expect(String(data: response, encoding: .utf8) == "{}")
    }

    @Test func missingToolNameReturnsPassthrough() {
        let json = try! JSONSerialization.data(withJSONObject: ["hook_event_name": "PreToolUse"])
        let response = HookRouter.handle(eventJSON: json)
        #expect(String(data: response, encoding: .utf8) == "{}")
    }

    @Test func unknownToolReturnsPassthrough() {
        // The HookRouter only intercepts Read/Bash/Grep; any other tool
        // name passes through.
        let response = HookRouter.handle(eventJSON: makeEvent(toolName: "NotebookEdit"))
        #expect(String(data: response, encoding: .utf8) == "{}")
    }

    @Test func emptyGrepPatternPassesThrough() {
        let response = HookRouter.handle(eventJSON: makeEvent(
            toolName: "Grep",
            toolInput: ["pattern": ""]
        ))
        #expect(String(data: response, encoding: .utf8) == "{}",
                "empty pattern must passthrough, not crash")
    }

    @Test func emptyBashCommandPassesThrough() {
        let response = HookRouter.handle(eventJSON: makeEvent(
            toolName: "Bash",
            toolInput: ["command": ""]
        ))
        #expect(String(data: response, encoding: .utf8) == "{}")
    }

    @Test func grepWithUnderscoreIdentifierBlocks() {
        // Identifiers with underscores are valid symbols — should route to search.
        let response = HookRouter.handle(eventJSON: makeEvent(
            toolName: "Grep",
            toolInput: ["pattern": "my_function_name"]
        ))
        guard let json = parseResponse(response),
              let hook = json["hookSpecificOutput"] as? [String: Any]
        else { Issue.record("expected deny"); return }
        #expect(hook["permissionDecision"] as? String == "deny")
    }

    @Test func grepWithDigitsInIdentifierBlocks() {
        // Numeric suffixes are still identifier-like (must start with letter).
        let response = HookRouter.handle(eventJSON: makeEvent(
            toolName: "Grep",
            toolInput: ["pattern": "http2Handler"]
        ))
        guard let json = parseResponse(response),
              let hook = json["hookSpecificOutput"] as? [String: Any]
        else { Issue.record("expected deny"); return }
        #expect(hook["permissionDecision"] as? String == "deny")
    }
}
