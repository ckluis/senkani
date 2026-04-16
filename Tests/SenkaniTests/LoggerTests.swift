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
}
