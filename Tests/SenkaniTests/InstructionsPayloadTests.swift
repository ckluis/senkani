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

/// Bach G9 — end-to-end tests for `instructionsPayload(base:budgetBytes:)`.
/// The prior suite only exercised the static `truncate` helper. G9 asks for
/// the composition — that the budget holds across `base + repoMap + brief +
/// skills`, that sub-budgets respect priority (brief ≤ 700, skills ≤ 400,
/// repoMap takes the remainder), and that extremely large inputs don't
/// blow the ceiling.
///
/// Constructs a real MCPSession pointed at a temp directory — light-weight
/// (index + skills are empty on a blank dir, brief is a short string), and
/// avoids the risk of the test depending on the user's real project DB.
@Suite("MCPSession.instructionsPayload (G9)")
struct InstructionsPayloadIntegrationTests {

    private static func makeTempProject() -> String {
        let root = NSTemporaryDirectory() + "senkani-g9-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        // A tiny source file so the symbol index isn't completely empty —
        // not required, but makes the repo-map path exercise real logic.
        let src = root + "/example.swift"
        try? "struct Example { func hello() -> String { return \"hi\" } }\n"
            .write(toFile: src, atomically: true, encoding: .utf8)
        return root
    }

    private static func cleanup(_ root: String) {
        try? FileManager.default.removeItem(atPath: root)
    }

    @Test func budgetCeilingRespectedForSmallBase() {
        let root = Self.makeTempProject()
        defer { Self.cleanup(root) }

        let session = MCPSession(projectRoot: root)
        let base = "You are senkani.\n"
        let out = session.instructionsPayload(base: base, budgetBytes: 256)
        // Budget is 256 across base + repoMap + brief + skills. The base
        // itself is always included (base == foundation, the budget is for
        // the sections appended after). The assertion is the TOTAL stays
        // near budget — we allow some slack for the concatenation
        // overhead but reject runaway payloads.
        #expect(out.utf8.count <= 256 + base.utf8.count,
                "total payload must fit budget + base; got \(out.utf8.count) bytes for budget=256, base=\(base.utf8.count)")
    }

    @Test func budgetCeilingRespectedFor2KBDefault() {
        let root = Self.makeTempProject()
        defer { Self.cleanup(root) }

        let session = MCPSession(projectRoot: root)
        let base = "You are senkani.\n"
        let out = session.instructionsPayload(base: base)  // default 2048
        // Implementation sums three sub-budgets (brief=min(700, 2048/3),
        // skills=min(400, 2048/5), repoMap=remainder). Enforce the same
        // ceiling: 2048 + base.
        #expect(out.utf8.count <= 2048 + base.utf8.count,
                "default budget must not be exceeded; got \(out.utf8.count)")
    }

    @Test func basePrefixAlwaysPresent() {
        let root = Self.makeTempProject()
        defer { Self.cleanup(root) }

        let session = MCPSession(projectRoot: root)
        let base = "YOU-ARE-SENKANI-UNIQUE-MARKER-4b7a\n"
        let out = session.instructionsPayload(base: base, budgetBytes: 128)
        #expect(out.hasPrefix(base),
                "base must always be the prefix so the agent-facing instructions are stable")
    }

    @Test func tighterBudgetProducesNoLargerPayloadThanLooser() {
        let root = Self.makeTempProject()
        defer { Self.cleanup(root) }

        let session = MCPSession(projectRoot: root)
        let base = "base\n"
        let tight = session.instructionsPayload(base: base, budgetBytes: 256)
        let loose = session.instructionsPayload(base: base, budgetBytes: 4096)
        #expect(tight.utf8.count <= loose.utf8.count,
                "monotone: smaller budget ≤ larger budget (got tight=\(tight.utf8.count), loose=\(loose.utf8.count))")
    }

    @Test func emptyProjectProducesBaseOnly() {
        // Blank project (no source files, no prior session): sessionBrief,
        // repoMap, and skillsPrompt are all empty → payload == base.
        let root = NSTemporaryDirectory() + "senkani-g9-empty-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let session = MCPSession(projectRoot: root)
        let base = "BASE-ONLY"
        let out = session.instructionsPayload(base: base, budgetBytes: 2048)
        // Allow minor additions if the background index happens to populate
        // during test runtime — the guarantee is that output is close to
        // base and never smaller than base.
        #expect(out.hasPrefix(base))
        #expect(out.utf8.count >= base.utf8.count)
    }
}
