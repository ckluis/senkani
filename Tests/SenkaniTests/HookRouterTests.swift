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
