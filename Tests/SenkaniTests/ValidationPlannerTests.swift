import Testing
import Foundation
@testable import Core

/// U.2a-1 contract tests for `ValidationAxes` + `ValidationPlanner`.
/// One test per `DiffSelector` shape (unstaged / staged / branch / range)
/// plus a vocabulary round-trip and a tree-sitter injection sanity check.
@Suite("ValidationPlanner — U.2a-1 runtime contract")
struct ValidationPlannerTests {

    // MARK: - Helpers

    /// Recording targeter — captures the (path, diff) tuples the planner
    /// asked about so tests can assert on the dispatch order. The `_seen`
    /// buffer is guarded by a lock so the type can satisfy
    /// `SymbolicTargeter`'s `Sendable` requirement under @unchecked.
    final class RecordingTargeter: SymbolicTargeter, @unchecked Sendable {
        let returns: String?
        private let lock = NSLock()
        private var _seen: [(String, String)] = []

        init(returns: String? = nil) { self.returns = returns }

        func selector(forFile path: String, diff: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            _seen.append((path, diff))
            return returns
        }

        var seen: [(String, String)] {
            lock.lock(); defer { lock.unlock() }
            return _seen
        }
    }

    // MARK: - Axes vocabulary

    @Test("ValidationAxes carries all 4 stable string rawValues that JSON-round-trip")
    func axesVocabRoundTrips() throws {
        let expected: [(ValidationAxes, String)] = [
            (.perf, "perf"),
            (.security, "security"),
            (.design, "design"),
            (.completeness, "completeness"),
        ]
        for (axis, raw) in expected {
            #expect(axis.rawValue == raw, "rawValue mismatch for \(axis)")
            #expect(ValidationAxes(rawValue: raw) == axis)
        }

        let encoded = try JSONEncoder().encode(ValidationAxes.allCases)
        let decoded = try JSONDecoder().decode([ValidationAxes].self, from: encoded)
        #expect(decoded == ValidationAxes.allCases,
                "ValidationAxes.allCases must round-trip through JSON byte-identically")
    }

    // MARK: - DiffSelector shape coverage

    @Test("planner handles DiffSelector.unstaged — emits one step per (file, axis)")
    func plannerUnstaged() {
        let diff = DiffRequest(
            selector: .unstaged,
            perFileDiff: [
                "Sources/A.swift": "@@ -1,2 +1,2 @@\n-old\n+new",
                "Sources/B.swift": "@@ -5,1 +5,1 @@\n-x\n+y",
            ]
        )
        let plan = ValidationPlanner.plan(
            diff: diff,
            axes: [.perf, .completeness],
            targeter: NoopSymbolicTargeter()
        )
        #expect(plan.count == 4, "2 files × 2 axes = 4 steps; got \(plan.count)")

        // Files sorted ASC; axes preserved in argument order.
        #expect(plan[0].targetPath == "Sources/A.swift" && plan[0].axis == .perf)
        #expect(plan[1].targetPath == "Sources/A.swift" && plan[1].axis == .completeness)
        #expect(plan[2].targetPath == "Sources/B.swift" && plan[2].axis == .perf)
        #expect(plan[3].targetPath == "Sources/B.swift" && plan[3].axis == .completeness)

        // assertionId follows axis.rawValue.default convention.
        #expect(plan[0].assertionId == "perf.default")
        #expect(plan[1].assertionId == "completeness.default")

        // No targeter wired → all selectors nil (file-level targeting).
        #expect(plan.allSatisfy { $0.selector == nil })
    }

    @Test("planner handles DiffSelector.staged — empty perFileDiff returns empty plan")
    func plannerStagedEmpty() {
        let diff = DiffRequest(selector: .staged, perFileDiff: [:])
        let plan = ValidationPlanner.plan(diff: diff, axes: [.perf])
        #expect(plan.isEmpty, "no files → empty plan; got \(plan.count) steps")
    }

    @Test("planner handles DiffSelector.branch — invokes targeter once per file, uses returned selector")
    func plannerBranchWithTargeter() {
        let targeter = RecordingTargeter(returns: "function:foo")
        let diff = DiffRequest(
            selector: .branch("main"),
            perFileDiff: [
                "Sources/Bar.swift": "@@ -10,1 +10,1 @@\n-z\n+w",
            ]
        )
        let plan = ValidationPlanner.plan(
            diff: diff,
            axes: [.security, .design],
            targeter: targeter
        )

        #expect(plan.count == 2)
        #expect(plan.allSatisfy { $0.selector == "function:foo" },
                "targeter return value must propagate to ValidationStep.selector")
        #expect(targeter.seen.count == 1, "targeter must be invoked exactly once per file")
        #expect(targeter.seen[0].0 == "Sources/Bar.swift")
        #expect(targeter.seen[0].1.contains("-z"), "diff body must reach the targeter unaltered")
    }

    @Test("planner handles DiffSelector.range — skips files with empty diff bodies")
    func plannerRangeSkipsEmptyDiffs() {
        let diff = DiffRequest(
            selector: .range("v0.3.0", "HEAD"),
            perFileDiff: [
                "Sources/Empty.swift": "",
                "Sources/Real.swift": "@@ -1,1 +1,1 @@\n-q\n+r",
            ]
        )
        let plan = ValidationPlanner.plan(diff: diff, axes: [.perf])
        #expect(plan.count == 1, "empty-body file must be skipped; got \(plan.count) steps")
        #expect(plan[0].targetPath == "Sources/Real.swift")
    }

    // MARK: - Plan-shape stability

    @Test("ValidationStep encodes byte-stably with snake_case JSON keys")
    func validationStepJSONShape() throws {
        let step = ValidationStep(
            axis: .perf,
            assertionId: "perf.inp",
            targetPath: "src/index.html",
            selector: "function:hydrate",
            expected: "{\"max_ms\":200}"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(step)
        let json = String(data: data, encoding: .utf8) ?? ""

        // sortedKeys + snake_case CodingKeys → exact bytes.
        let expected = """
            {"assertion_id":"perf.inp","axis":"perf","expected":"{\\"max_ms\\":200}","selector":"function:hydrate","target_path":"src/index.html"}
            """
        #expect(json == expected, "got:   \(json)\nwant:  \(expected)")
    }
}
