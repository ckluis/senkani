import Testing
import Foundation
@testable import MCPServer

/// P1-7: instructions payload byte-budget tests.
/// Exercises the static `MCPSession.truncate(_:to:marker:)` helper, which is the
/// load-bearing piece of `instructionsPayload(base:budgetBytes:)`. Constructing a
/// full MCPSession requires a live DB + index and is covered by integration paths.
@Suite("MCPSession.truncate")
struct InstructionsPayloadTruncateTests {

    @Test func shortInputPassesThrough() {
        let out = MCPSession.truncate("hello", to: 100, marker: "[cut]")
        #expect(out == "hello")
    }

    @Test func emptyInputStaysEmpty() {
        let out = MCPSession.truncate("", to: 100, marker: "[cut]")
        #expect(out == "")
    }

    @Test func exactBudgetPassesThrough() {
        let s = String(repeating: "a", count: 50)
        let out = MCPSession.truncate(s, to: 50, marker: "[cut]")
        #expect(out == s)
    }

    @Test func overBudgetAppendsMarker() {
        let s = String(repeating: "a", count: 200)
        let marker = "[cut]"
        let out = MCPSession.truncate(s, to: 100, marker: marker)
        #expect(out.utf8.count <= 100, "Output must fit within budget, got \(out.utf8.count)")
        #expect(out.hasSuffix(marker), "Marker must be appended on truncation")
    }

    @Test func utf8MultibyteDoesNotSplitScalar() {
        // Each 🦀 is 4 UTF-8 bytes. 50 × 4 = 200 bytes.
        let s = String(repeating: "🦀", count: 50)
        let marker = "[…]"
        // Budget forces truncation mid-crab region.
        let out = MCPSession.truncate(s, to: 60, marker: marker)
        #expect(out.utf8.count <= 60)
        #expect(out.hasSuffix(marker))
        // Every remaining character must be a valid crab — no split-scalar garbage.
        let body = String(out.dropLast(marker.count))
        #expect(body.allSatisfy { $0 == "🦀" }, "Truncation must not split a multi-byte scalar")
    }

    @Test func markerLargerThanBudgetDoesNotCrash() {
        // Pathological case: budget smaller than marker. Should not crash; result is
        // allowed to be empty or to contain a partial marker — just don't panic.
        let out = MCPSession.truncate("long text here", to: 2, marker: "[cut-longer-than-budget]")
        #expect(out.utf8.count >= 0)
    }
}
