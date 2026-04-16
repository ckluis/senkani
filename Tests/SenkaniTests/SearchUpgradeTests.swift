import Testing
import Foundation
@testable import Core

// MARK: - Helpers

private func makeReadEvent(filePath: String, projectRoot: String = "/tmp/project") -> Data {
    let event: [String: Any] = [
        "tool_name": "Read",
        "hook_event_name": "PreToolUse",
        "tool_input": ["file_path": filePath],
        "cwd": projectRoot,
    ]
    return try! JSONSerialization.data(withJSONObject: event)
}

private func parseResponse(_ data: Data) -> (decision: String?, reason: String?) {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let hookOutput = json["hookSpecificOutput"] as? [String: Any] else {
        return (nil, nil)
    }
    return (hookOutput["permissionDecision"] as? String,
            hookOutput["permissionDecisionReason"] as? String)
}

// MARK: - Tests

@Suite("HookRouter — Search Upgrade Hint")
struct SearchUpgradeTests {

    @Test func noHintForTwoReads() {
        HookRouter.readDenialTracker.reset()

        let r1 = HookRouter.handle(eventJSON: makeReadEvent(filePath: "file1.swift"))
        let r2 = HookRouter.handle(eventJSON: makeReadEvent(filePath: "file2.swift"))

        let (_, reason1) = parseResponse(r1)
        let (_, reason2) = parseResponse(r2)

        #expect(reason1?.contains("mcp__senkani__search") != true, "No hint on first read")
        #expect(reason2?.contains("mcp__senkani__search") != true, "No hint on second read")
    }

    @Test func hintAppearsOnThirdDistinctFile() {
        HookRouter.readDenialTracker.reset()

        _ = HookRouter.handle(eventJSON: makeReadEvent(filePath: "a.swift"))
        _ = HookRouter.handle(eventJSON: makeReadEvent(filePath: "b.swift"))
        let r3 = HookRouter.handle(eventJSON: makeReadEvent(filePath: "c.swift"))

        let (_, reason) = parseResponse(r3)
        #expect(reason?.contains("mcp__senkani__search") == true,
                "Third distinct file should trigger search hint")
    }

    @Test func sameFileDoesNotCountMultiple() {
        HookRouter.readDenialTracker.reset()

        _ = HookRouter.handle(eventJSON: makeReadEvent(filePath: "same.swift"))
        _ = HookRouter.handle(eventJSON: makeReadEvent(filePath: "same.swift"))
        let r3 = HookRouter.handle(eventJSON: makeReadEvent(filePath: "same.swift"))

        let (_, reason) = parseResponse(r3)
        #expect(reason?.contains("mcp__senkani__search") != true,
                "Same file 3 times should NOT trigger hint (only 1 distinct)")
    }

    @Test func hintResetsAfterFiring() {
        HookRouter.readDenialTracker.reset()

        // Trigger the hint (3 distinct files)
        _ = HookRouter.handle(eventJSON: makeReadEvent(filePath: "x.swift"))
        _ = HookRouter.handle(eventJSON: makeReadEvent(filePath: "y.swift"))
        let r3 = HookRouter.handle(eventJSON: makeReadEvent(filePath: "z.swift"))
        let (_, reason3) = parseResponse(r3)
        #expect(reason3?.contains("mcp__senkani__search") == true, "Hint should fire")

        // After reset, 2 more reads should NOT trigger
        _ = HookRouter.handle(eventJSON: makeReadEvent(filePath: "p.swift"))
        let r5 = HookRouter.handle(eventJSON: makeReadEvent(filePath: "q.swift"))
        let (_, reason5) = parseResponse(r5)
        #expect(reason5?.contains("mcp__senkani__search") != true,
                "Only 2 reads after reset — no hint yet")
    }

    @Test func expiredEntriesIgnored() {
        HookRouter.readDenialTracker.reset()

        // Record with a 50ms window. Sleep 4× the window (200ms) for reliable expiry
        // under CI load. Prior version used 10ms/20ms — too tight, caused flakiness.
        _ = HookRouter.readDenialTracker.recordAndCount(filePath: "old1.swift", windowSeconds: 0.05)
        _ = HookRouter.readDenialTracker.recordAndCount(filePath: "old2.swift", windowSeconds: 0.05)

        // Wait for expiry (4× window)
        Thread.sleep(forTimeInterval: 0.2)

        // This should be the only unexpired entry — count should be 1
        let count = HookRouter.readDenialTracker.recordAndCount(filePath: "new.swift", windowSeconds: 0.05)
        #expect(count == 1, "Expired entries should be pruned")
    }

    @Test func hintOnGenericRedirectPath() {
        HookRouter.readDenialTracker.reset()

        // These files don't exist in senkani_read cache, so they hit the generic redirect
        _ = HookRouter.handle(eventJSON: makeReadEvent(filePath: "/nonexistent/a.swift"))
        _ = HookRouter.handle(eventJSON: makeReadEvent(filePath: "/nonexistent/b.swift"))
        let r3 = HookRouter.handle(eventJSON: makeReadEvent(filePath: "/nonexistent/c.swift"))

        let (_, reason) = parseResponse(r3)
        #expect(reason?.contains("Use mcp__senkani__read") == true, "Should have generic redirect")
        #expect(reason?.contains("mcp__senkani__search") == true, "Should also have search hint")
    }

    @Test func noHintWhenFilePathEmpty() {
        HookRouter.readDenialTracker.reset()

        let hint = HookRouter.searchUpgradeHint(filePath: "")
        #expect(hint.isEmpty, "Empty file path should produce no hint")
    }

    @Test func hintContainsFileCount() {
        HookRouter.readDenialTracker.reset()

        // Record 4 distinct files
        _ = HookRouter.readDenialTracker.recordAndCount(filePath: "a.swift")
        _ = HookRouter.readDenialTracker.recordAndCount(filePath: "b.swift")
        _ = HookRouter.readDenialTracker.recordAndCount(filePath: "c.swift")
        _ = HookRouter.readDenialTracker.recordAndCount(filePath: "d.swift")

        let hint = HookRouter.searchUpgradeHint(filePath: "e.swift")
        // After recording e.swift, there are 5 distinct files but reset happened inside
        // searchUpgradeHint after it found >=3 from the tracker.
        // Actually, searchUpgradeHint calls recordAndCount which adds e.swift first,
        // making it 5, then checks >=3, resets, and returns the hint with count=5.
        #expect(hint.contains("5"), "Hint should mention the distinct file count")
    }
}
