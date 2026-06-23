import Testing
import Foundation
#if canImport(Darwin)
import Darwin.POSIX
#endif
@testable import HookRelay

/// Carve 1 (observability) for
/// `t6-hook-relay-5ms-deadline-drops-deny-decisions-2026-06-22`.
///
/// HookRelay times out after 5 ms and passes through (`{}` = approve),
/// silently discarding any `deny`/`block` the server computed past the
/// deadline. This carve does NOT change that behavior — it makes the
/// otherwise-invisible drop detectable by appending a line to a drop log at
/// each DEADLINE-driven passthrough. These tests lock in the two pure
/// building blocks the `run()` timeout sites call:
///   1. `hookEventName(from:)` — best-effort label of the dropped hook.
///   2. `recordDrop(...)` — atomic append, never throws, never overwrites.
@Suite("HookRelay drop counter (carve 1)")
struct HookRelayDropCounterTests {

    private static func makeTempLogPath() -> String {
        NSTemporaryDirectory() + "senkani-hookrelay-drop-\(UUID().uuidString).log"
    }

    private static func readLines(_ path: String) -> [String] {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return s.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: - hookEventName

    @Test func hookEventNameParsesPreToolUse() {
        let payload = Data(#"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#.utf8)
        #expect(HookRelay.hookEventName(from: payload) == "PreToolUse")
    }

    @Test func hookEventNameReturnsNilOnGarbageOrMissingField() {
        #expect(HookRelay.hookEventName(from: Data()) == nil)
        #expect(HookRelay.hookEventName(from: Data("not json".utf8)) == nil)
        #expect(HookRelay.hookEventName(from: Data(#"{"other":"x"}"#.utf8)) == nil)
        #expect(HookRelay.hookEventName(from: Data(#"{"hook_event_name":""}"#.utf8)) == nil)
    }

    // MARK: - recordDrop

    @Test func recordDropAppendsWellFormedTSVLine() {
        let path = Self.makeTempLogPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let now = Date(timeIntervalSince1970: 1_719_000_000)

        HookRelay.recordDrop(reason: "read_timeout", hookEvent: "PreToolUse", at: path, now: now)

        let lines = Self.readLines(path)
        #expect(lines.count == 1)
        let fields = lines[0].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        #expect(fields.count == 3)
        #expect(fields[0] == ISO8601DateFormatter().string(from: now))
        #expect(fields[1] == "read_timeout")
        #expect(fields[2] == "PreToolUse")
    }

    @Test func recordDropAppendsRatherThanOverwrites() {
        let path = Self.makeTempLogPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        HookRelay.recordDrop(reason: "connect_timeout", hookEvent: "Notification", at: path)
        HookRelay.recordDrop(reason: "read_timeout", hookEvent: "PreToolUse", at: path)

        let lines = Self.readLines(path)
        #expect(lines.count == 2, "second drop must append, not clobber the first")
        #expect(lines[0].contains("connect_timeout") && lines[0].contains("Notification"))
        #expect(lines[1].contains("read_timeout") && lines[1].contains("PreToolUse"))
    }

    @Test func recordDropLabelsUnknownWhenEventIsNil() {
        let path = Self.makeTempLogPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        HookRelay.recordDrop(reason: "read_timeout", hookEvent: nil, at: path)

        let lines = Self.readLines(path)
        #expect(lines.count == 1)
        #expect(lines[0].hasSuffix("\tunknown"))
    }

    @Test func recordDropSanitizesTabsAndNewlinesInEventLabel() {
        let path = Self.makeTempLogPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        HookRelay.recordDrop(reason: "read_timeout", hookEvent: "weird\tname\nwith breaks", at: path)

        let lines = Self.readLines(path)
        #expect(lines.count == 1, "embedded tab/newline must not split the record into extra lines")
        let fields = lines[0].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        #expect(fields.count == 3)
        #expect(fields[2] == "weird name with breaks")
    }
}
