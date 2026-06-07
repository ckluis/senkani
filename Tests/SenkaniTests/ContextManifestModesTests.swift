import Testing
import Foundation
@testable import Core
@testable import Indexer
@testable import Bundle

// U.10b — ContextManifest modes (slice / diff-only / summary) tests.
// Covers: slice mode wiring, diff-only across the 4 selectors, summary
// mode's Gemma/KB/unavailable cases, the regression that no
// `mode-pending-u10b` reason surfaces after U.10b ships, and the
// tokens-mismatch freshness rule.

private let fixedDate = Date(timeIntervalSince1970: 1_713_360_000)

private func makeIndex() -> SymbolIndex {
    var idx = SymbolIndex()
    idx.projectRoot = "/tmp/u10b-fixture"
    idx.generated = fixedDate
    idx.symbols = [
        IndexEntry(name: "Foo", kind: .class, file: "Sources/Foo.swift", startLine: 10),
    ]
    return idx
}

private func makeInputs(entities: [KnowledgeEntity] = []) -> BundleInputs {
    BundleInputs(
        index: makeIndex(),
        graph: nil,
        entities: entities,
        readme: "# Hello\n\nplain readme.\n"
    )
}

// MARK: - 1. Slice mode

@Suite("U.10b slice mode")
struct ContextManifestSliceModeTests {

    @Test("Slice request emits a file-lane item with range + char/4 tokens_actual")
    func sliceEmitsFileLaneItem() {
        let content = "line one\nline two\nline three\nline four"
        let req = SliceRequest(
            path: "Sources/Foo.swift",
            range: ContextRange(start: 1, end: 4),
            content: content
        )
        let opts = ManifestOptions(
            projectRoot: "/tmp/u10b-fixture",
            modes: ContextMode.trivial.union([.slice]),
            lanes: [.file],
            now: fixedDate,
            slice: req
        )
        let manifest = BundleComposer.composeManifest(
            options: opts, inputs: makeInputs())
        let sliceItems = manifest.items.filter { $0.mode == .slice }
        #expect(sliceItems.count == 1, "exactly one slice item per SliceRequest")
        let item = sliceItems[0]
        #expect(item.lane == .file)
        #expect(item.path == "Sources/Foo.swift")
        #expect(item.range == ContextRange(start: 1, end: 4))
        #expect(item.tokensActual == content.count / 4,
                "tokens_actual must mirror the slice content's char/4")
        #expect(item.inclusionReason == "slice_1_4")
    }
}

// MARK: - 2. Diff-only mode — four selectors

@Suite("U.10b diff-only mode — 4 selectors")
struct ContextManifestDiffOnlyModeTests {

    private func makeOpts(selector: DiffSelector, perFile: [String: String]) -> ManifestOptions {
        ManifestOptions(
            projectRoot: "/tmp/u10b-fixture",
            modes: ContextMode.trivial.union([.diffOnly]),
            lanes: [.diff],
            now: fixedDate,
            diff: DiffRequest(selector: selector, perFileDiff: perFile)
        )
    }

    @Test("Unstaged selector emits one diff-lane item per file, inclusion_reason carries 'diff_unstaged'")
    func unstagedSelector() {
        let manifest = BundleComposer.composeManifest(
            options: makeOpts(
                selector: .unstaged,
                perFile: ["a.swift": "diff body a", "b.swift": "diff body b"]),
            inputs: makeInputs())
        let diffItems = manifest.items.filter { $0.lane == .diff }
        #expect(diffItems.count == 2)
        #expect(diffItems.allSatisfy { $0.mode == .diffOnly })
        #expect(diffItems.allSatisfy { $0.inclusionReason == "diff_unstaged" })
    }

    @Test("Staged selector inclusion_reason is 'diff_staged'")
    func stagedSelector() {
        let manifest = BundleComposer.composeManifest(
            options: makeOpts(selector: .staged, perFile: ["a.swift": "x"]),
            inputs: makeInputs())
        let item = manifest.items.first { $0.lane == .diff }
        #expect(item?.inclusionReason == "diff_staged")
    }

    @Test("Branch:<ref> selector inclusion_reason carries the ref")
    func branchSelector() {
        let manifest = BundleComposer.composeManifest(
            options: makeOpts(selector: .branch("main"), perFile: ["a.swift": "x"]),
            inputs: makeInputs())
        let item = manifest.items.first { $0.lane == .diff }
        #expect(item?.inclusionReason == "diff_branch:main")
    }

    @Test("Range:<a>..<b> selector inclusion_reason carries both refs")
    func rangeSelector() {
        let manifest = BundleComposer.composeManifest(
            options: makeOpts(
                selector: .range("HEAD~3", "HEAD"),
                perFile: ["a.swift": "x"]),
            inputs: makeInputs())
        let item = manifest.items.first { $0.lane == .diff }
        #expect(item?.inclusionReason == "diff_range:HEAD~3..HEAD")
    }

    @Test("DiffSelector rawValue / init(rawValue:) round-trips for all four shapes")
    func selectorRoundTrips() {
        let selectors: [DiffSelector] = [
            .unstaged,
            .staged,
            .branch("feature/foo"),
            .range("HEAD~5", "HEAD"),
        ]
        for sel in selectors {
            let raw = sel.rawValue
            #expect(DiffSelector(rawValue: raw) == sel,
                    "selector \(sel) must round-trip through rawValue '\(raw)'")
        }
        // Malformed inputs return nil.
        #expect(DiffSelector(rawValue: "") == nil)
        #expect(DiffSelector(rawValue: "branch:") == nil)
        #expect(DiffSelector(rawValue: "range:HEAD") == nil)
    }
}

// MARK: - 3. Summary mode — Gemma / KB-fallback / unavailable

@Suite("U.10b summary mode — Gemma + KB fallback + unavailable")
struct ContextManifestSummaryModeTests {

    private func makeEntity(name: String, understanding: String) -> KnowledgeEntity {
        KnowledgeEntity(
            id: 1, name: name, entityType: "class",
            sourcePath: "Sources/\(name).swift",
            markdownPath: ".senkani/knowledge/\(name).md",
            compiledUnderstanding: understanding,
            mentionCount: 5,
            createdAt: fixedDate, modifiedAt: fixedDate
        )
    }

    @Test("Gemma-available: pre-resolved summary populates item, inclusion_reason='summary_gemma'")
    func gemmaAvailable() {
        let entity = makeEntity(name: "Foo", understanding: "Original long understanding text.")
        let summaries = ["Foo": "Short Gemma summary."]
        let opts = ManifestOptions(
            projectRoot: "/tmp/u10b-fixture",
            modes: ContextMode.trivial.union([.summary]),
            lanes: [.knowledge],
            now: fixedDate,
            entitySummaries: summaries
        )
        let manifest = BundleComposer.composeManifest(
            options: opts, inputs: makeInputs(entities: [entity]))
        let summaryItems = manifest.items.filter { $0.mode == .summary }
        #expect(summaryItems.count == 1)
        let item = summaryItems[0]
        #expect(item.inclusionReason == "summary_gemma")
        #expect(item.tokensActual == "Short Gemma summary.".count / 4)
    }

    @Test("KB-fallback: no pre-resolved summary uses compiledUnderstanding, inclusion_reason='summary_kb_fallback'")
    func kbFallback() {
        let understanding = "Compiled understanding for the entity."
        let entity = makeEntity(name: "Foo", understanding: understanding)
        let opts = ManifestOptions(
            projectRoot: "/tmp/u10b-fixture",
            modes: ContextMode.trivial.union([.summary]),
            lanes: [.knowledge],
            now: fixedDate,
            entitySummaries: nil
        )
        let manifest = BundleComposer.composeManifest(
            options: opts, inputs: makeInputs(entities: [entity]))
        let item = manifest.items.first { $0.mode == .summary }
        #expect(item?.inclusionReason == "summary_kb_fallback")
        #expect(item?.tokensActual == understanding.count / 4)
    }

    @Test("Neither: empty understanding + no summary surfaces 'summary_unavailable'")
    func neitherAvailable() {
        let entity = makeEntity(name: "Foo", understanding: "")
        let opts = ManifestOptions(
            projectRoot: "/tmp/u10b-fixture",
            modes: ContextMode.trivial.union([.summary]),
            lanes: [.knowledge],
            now: fixedDate,
            entitySummaries: nil
        )
        let manifest = BundleComposer.composeManifest(
            options: opts, inputs: makeInputs(entities: [entity]))
        let item = manifest.items.first { $0.mode == .summary }
        #expect(item?.inclusionReason == "summary_unavailable")
        #expect(item?.tokensActual == 0)
    }
}

// MARK: - 4. Mode-pending-u10b regression

@Suite("U.10b mode-pending regression")
struct ContextManifestModePendingRegressionTests {

    @Test("No item carries inclusion_reason 'mode-pending-u10b' after U.10b ships")
    func noModePendingReasonsSurface() {
        // Request ALL seven modes + ALL 8 lanes — the broadest possible
        // surface that would have triggered every U.10a stub.
        let opts = ManifestOptions(
            projectRoot: "/tmp/u10b-fixture",
            modes: Set(ContextMode.allCases),
            lanes: Set(ContextLane.allCases),
            now: fixedDate
        )
        let manifest = BundleComposer.composeManifest(
            options: opts, inputs: makeInputs())
        let stubs = manifest.items.filter { $0.inclusionReason == "mode-pending-u10b" }
        #expect(stubs.isEmpty,
                "U.10b removes every mode-pending-u10b stub; saw \(stubs.count)")
    }
}

// MARK: - 5. Tokens mismatch → freshness: stale_estimate

@Suite("U.10b tokens mismatch freshness rule")
struct ContextManifestTokensMismatchTests {

    private func makeEntity(name: String, understanding: String) -> KnowledgeEntity {
        KnowledgeEntity(
            id: 1, name: name, entityType: "class",
            sourcePath: "Sources/\(name).swift",
            markdownPath: ".senkani/knowledge/\(name).md",
            compiledUnderstanding: understanding,
            mentionCount: 1,
            createdAt: fixedDate, modifiedAt: fixedDate
        )
    }

    @Test("Summary content within ±20% of budget stays fresh")
    func freshWithinBudget() {
        // Budget 200 tokens → ~800 chars. A summary of ~780 chars is
        // within ±20 %.
        let understanding = String(repeating: "a ", count: 390)  // ~780 chars
        let entity = makeEntity(name: "Foo", understanding: understanding)
        let opts = ManifestOptions(
            projectRoot: "/tmp/u10b-fixture",
            modes: ContextMode.trivial.union([.summary]),
            lanes: [.knowledge],
            now: fixedDate,
            entitySummaries: nil,
            summaryBudgetTokens: 200
        )
        let manifest = BundleComposer.composeManifest(
            options: opts, inputs: makeInputs(entities: [entity]))
        let item = manifest.items.first { $0.mode == .summary }
        #expect(item?.freshness == .fresh,
                "summary within ±20% of budget should remain fresh; was \(String(describing: item?.freshness))")
    }

    @Test("Summary content >20% off budget flips to stale_estimate")
    func staleEstimateBeyondBudget() {
        // Budget 50 tokens → ~200 chars. A 2000-char summary is 10× over.
        let understanding = String(repeating: "b ", count: 1000)  // ~2000 chars
        let entity = makeEntity(name: "Foo", understanding: understanding)
        let opts = ManifestOptions(
            projectRoot: "/tmp/u10b-fixture",
            modes: ContextMode.trivial.union([.summary]),
            lanes: [.knowledge],
            now: fixedDate,
            entitySummaries: nil,
            summaryBudgetTokens: 50
        )
        let manifest = BundleComposer.composeManifest(
            options: opts, inputs: makeInputs(entities: [entity]))
        let item = manifest.items.first { $0.mode == .summary }
        #expect(item?.freshness == .staleEstimate,
                "summary 10× over budget must flip stale_estimate")
    }
}
