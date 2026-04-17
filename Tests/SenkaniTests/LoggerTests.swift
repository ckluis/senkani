import Testing
import Foundation
@testable import Core

/// P2-9: Logger format + JSON escape tests. Exercises `Logger.format(...)`
/// directly — no stderr capture needed. Pure-function tests are fast and
/// reliable in CI.
@Suite("Logger")
struct LoggerTests {

    // MARK: - Text mode

    @Test func textModeNoFields() {
        let out = Logger.format(event: "mcp.started", fields: [:], asJSON: false)
        #expect(out == "[mcp.started]")
    }

    @Test func textModeWithFields() {
        let out = Logger.format(
            event: "mcp.tool.invoked",
            fields: ["tool": .string("read"), "duration_ms": .int(12)],
            asJSON: false
        )
        // Keys are alphabetized; exact match.
        #expect(out == "[mcp.tool.invoked] duration_ms=12 tool=read")
    }

    // MARK: - JSON mode

    @Test func jsonModeNoFieldsParses() throws {
        let line = Logger.format(event: "mcp.started", fields: [:], asJSON: true)
        let data = Data(line.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["event"] as? String == "mcp.started")
        #expect(obj?["ts"] as? Double != nil)
    }

    @Test func jsonModeWithFieldsParses() throws {
        let line = Logger.format(
            event: "retention.tick",
            fields: [
                "tool": .string("retention"),
                "rows_deleted": .int(42),
                "ok": .bool(true),
                "rate": .double(0.95)
            ],
            asJSON: true
        )
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        #expect(obj?["tool"] as? String == "retention")
        #expect(obj?["rows_deleted"] as? Int == 42)
        #expect(obj?["ok"] as? Bool == true)
        #expect(obj?["rate"] as? Double == 0.95)
    }

    // MARK: - Escaping

    @Test func jsonEscapesSpecialCharsInStrings() throws {
        let input = "he said \"hello\\world\"\n\tnext"
        let out = Logger.jsonEscape(input)
        // Round-trip through JSONSerialization to confirm the escape is valid.
        let wrapped = "{\"s\":\"\(out)\"}"
        let obj = try JSONSerialization.jsonObject(with: Data(wrapped.utf8)) as? [String: Any]
        #expect(obj?["s"] as? String == input, "escape must round-trip through JSONSerialization")
    }

    @Test func jsonEventNameEscaped() throws {
        // Event names with special chars must survive round-trip.
        let line = Logger.format(event: "weird\"event", fields: [:], asJSON: true)
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        #expect(obj?["event"] as? String == "weird\"event")
    }

    // MARK: - Cavoukian C5: secret redaction at the log sink
    //
    // Any `.string(_)` value flows through SecretDetector.scan before emit.
    // Even if a caller accidentally puts an API key or bearer token into a
    // log field, the stderr line carries `[REDACTED:*]` instead.

    @Test func stringFieldRedactsAnthropicKey() throws {
        // Build a plausible Anthropic-style token without embedding a real
        // prefix as a literal — keeps repo-secret-scanners happy.
        let token = "sk-" + "ant-" + String(repeating: "a", count: 40)
        let line = Logger.format(
            event: "mcp.debug",
            fields: ["note": .string("leaked \(token) in a field")],
            asJSON: true
        )
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        let note = obj?["note"] as? String ?? ""
        #expect(!note.contains(token), "raw token must not appear in logs")
        #expect(note.contains("[REDACTED:ANTHROPIC_API_KEY]"), "secret-detector tag must be present, got \(note)")
    }

    @Test func stringFieldRedactsBearerTokenInTextMode() {
        let bearer = "Bearer " + String(repeating: "z", count: 40)
        let line = Logger.format(
            event: "http.request",
            fields: ["auth": .string(bearer)],
            asJSON: false
        )
        #expect(!line.contains(bearer))
        #expect(line.contains("[REDACTED:BEARER_TOKEN]"))
    }

    @Test func stringFieldWithNoSecretIsUnchanged() {
        let line = Logger.format(
            event: "mcp.tool.invoked",
            fields: ["tool": .string("read"), "outcome": .string("success")],
            asJSON: false
        )
        #expect(line == "[mcp.tool.invoked] outcome=success tool=read")
    }

    // MARK: - Cavoukian C2: path redaction via .path() case

    @Test func pathValueStripsHomeDirectory() throws {
        let home = NSHomeDirectory()
        let realPath = home + "/Desktop/projects/senkani"
        let line = Logger.format(
            event: "filewatcher.scan",
            fields: ["project_root": .path(realPath)],
            asJSON: true
        )
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        let redacted = obj?["project_root"] as? String ?? ""
        #expect(redacted == "~/Desktop/projects/senkani",
                "home prefix must collapse to ~, got \(redacted)")
        #expect(!redacted.contains(home), "raw home must not leak")
    }

    @Test func pathValueObscuresForeignUsername() {
        let line = Logger.format(
            event: "filewatcher.scan",
            fields: ["project_root": .path("/Users/someone/Projects/thing")],
            asJSON: false
        )
        // `/Users/someone` → `/Users/***` (redactPath rule).
        #expect(line.contains("/Users/***/Projects/thing"))
        #expect(!line.contains("someone"))
    }

    @Test func pathValueTextModeRedaction() {
        let home = NSHomeDirectory()
        let line = Logger.format(
            event: "filewatcher.scan",
            fields: ["project_root": .path(home + "/code/x")],
            asJSON: false
        )
        #expect(line == "[filewatcher.scan] project_root=~/code/x")
    }
}
