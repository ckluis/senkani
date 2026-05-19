import Testing
import Foundation
@testable import Core
@testable import Indexer
@testable import Bundle

// U.10a-1 — ContextManifest contract tests.
// Covers: type round-trip, 8-lane vocabulary, 4-trivial-mode coverage,
// 3-pending-mode stub behavior, CLI/MCP parity surface (encoder
// determinism), and --modes restriction. The secret gate refusal +
// audit-row tests live in U.10a-2.

// MARK: - Fixtures

private let fixedDate = Date(timeIntervalSince1970: 1_713_360_000)

private func makeIndex() -> SymbolIndex {
    var idx = SymbolIndex()
    idx.projectRoot = "/tmp/u10a-fixture"
    idx.generated = fixedDate
    idx.symbols = [
        IndexEntry(name: "Foo", kind: .class, file: "Sources/Foo.swift", startLine: 10),
        IndexEntry(name: "bar", kind: .method, file: "Sources/Foo.swift", startLine: 15, container: "Foo"),
        IndexEntry(name: "Bar", kind: .struct, file: "Sources/Bar.swift", startLine: 5),
    ]
    return idx
}

private func makeInputs() -> BundleInputs {
    let entity = KnowledgeEntity(
        id: 1, name: "Foo", entityType: "class",
        sourcePath: "Sources/Foo.swift",
        markdownPath: ".senkani/knowledge/Foo.md",
        compiledUnderstanding: "Foo is the main domain type.",
        mentionCount: 5,
        createdAt: fixedDate, modifiedAt: fixedDate
    )
    return BundleInputs(
        index: makeIndex(),
        graph: nil,
        entities: [entity],
        readme: "# Hello\n\nProject readme.\n"
    )
}

// MARK: - Schema round-trip (Karpathy P0)

@Suite("ContextManifest schema round-trip")
struct ContextManifestRoundTripTests {

    @Test func itemRoundTripsThroughJSON() throws {
        let item = ContextManifestItem(
            id: "codemap:Sources/Foo.swift",
            lane: .codemap,
            path: "Sources/Foo.swift",
            range: ContextRange(start: 10, end: 50),
            mode: .codemap,
            tokensEstimated: 42,
            tokensActual: 42,
            freshness: .fresh,
            sensitivity: .clean,
            inclusionReason: "outline-available",
            toolId: "test-tool"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let pass1 = try encoder.encode(item)
        let decoded = try JSONDecoder().decode(ContextManifestItem.self, from: pass1)
        let pass2 = try encoder.encode(decoded)
        #expect(pass1 == pass2, "ContextManifestItem must round-trip byte-identically through JSON")
        #expect(decoded == item, "decoded item must equal the original")
    }

    @Test func stableJSONFieldNames() throws {
        let item = ContextManifestItem(
            id: "file:README",
            lane: .file,
            path: "README.md",
            mode: .full,
            tokensEstimated: 100,
            tokensActual: 100,
            inclusionReason: "readme-included"
        )
        let data = try JSONEncoder().encode(item)
        let json = String(data: data, encoding: .utf8)!
        // Field names are part of the contract — assert each shipped
        // key appears literally. Renaming any of these is a breaking
        // change for any consumer that decodes the manifest.
        #expect(json.contains("\"id\""))
        #expect(json.contains("\"lane\""))
        #expect(json.contains("\"path\""))
        #expect(json.contains("\"mode\""))
        #expect(json.contains("\"tokens_estimated\""))
        #expect(json.contains("\"tokens_actual\""))
        #expect(json.contains("\"freshness\""))
        #expect(json.contains("\"sensitivity\""))
        #expect(json.contains("\"inclusion_reason\""))
    }
}

// MARK: - Lane vocabulary (Morville P1)

@Suite("ContextManifest 8-lane vocabulary")
struct ContextManifestLaneTests {

    @Test func allEightLanesAreFirstClass() {
        // Schema-level: every lane the spec promises has an enum case.
        let expected: Set<String> = [
            "file", "diff", "codemap", "symbol",
            "knowledge", "runtime", "manual", "artifact",
        ]
        let actual = Set(ContextLane.allCases.map(\.rawValue))
        #expect(actual == expected, "ContextLane must be the exact 8-lane vocabulary")
    }

    @Test func artifactLaneEmitsReservedMarker() {
        let opts = ManifestOptions(
            projectRoot: "/tmp/u10a-fixture",
            modes: ContextMode.trivial,
            lanes: [.artifact],
            now: fixedDate
        )
        let manifest = BundleComposer.composeManifest(
            options: opts, inputs: makeInputs())
        // Reserved-marker contract: exactly one stub, mode is
        // artifactStubbed, reason is v9-pending, no body content.
        let artifactItems = manifest.items.filter { $0.lane == .artifact }
        #expect(artifactItems.count == 1, "artifact lane must emit exactly one reserved marker")
        let marker = artifactItems[0]
        #expect(marker.mode == .artifactStubbed)
        #expect(marker.inclusionReason == "v9-pending")
        #expect(marker.tokensEstimated == 0)
        #expect(marker.path == nil, "reserved marker must not carry a path")
    }

    @Test func lanesRequestedTracksInput() {
        let opts = ManifestOptions(
            projectRoot: "/tmp/u10a-fixture",
            modes: ContextMode.trivial,
            lanes: [.file, .codemap, .knowledge],
            now: fixedDate
        )
        let manifest = BundleComposer.composeManifest(
            options: opts, inputs: makeInputs())
        // Order is deterministic via allCases enumeration of the requested set.
        #expect(manifest.lanesRequested == [.file, .codemap, .knowledge])
        // Per-lane counts surface in the counts metadata.
        #expect(manifest.counts.perLane["codemap", default: 0] > 0)
        #expect(manifest.counts.perLane["knowledge", default: 0] > 0)
        // Lanes not requested produce no items.
        #expect(manifest.items.allSatisfy { [.file, .codemap, .knowledge].contains($0.lane) })
    }
}

// MARK: - Mode coverage (Morville P1)

@Suite("ContextManifest mode coverage")
struct ContextManifestModeTests {

    @Test func fourTrivialModesEmitValidItems() {
        let opts = ManifestOptions(
            projectRoot: "/tmp/u10a-fixture",
            modes: ContextMode.trivial,
            lanes: Set(ContextLane.allCases),
            now: fixedDate
        )
        let manifest = BundleComposer.composeManifest(
            options: opts, inputs: makeInputs())
        let modesUsed = Set(manifest.items.map(\.mode))
        // Each trivial mode shows up at least once across the
        // fixture: full (README + KB), codemap (per-file outline),
        // artifactStubbed (reserved marker). excluded-with-reason
        // is mode-dependent and not exercised by the all-trivial
        // request — covered separately below.
        #expect(modesUsed.contains(.full), "full mode must appear")
        #expect(modesUsed.contains(.codemap), "codemap mode must appear")
        #expect(modesUsed.contains(.artifactStubbed), "artifact-stubbed mode must appear")
    }

    @Test func excludedWithReasonFiresWhenModeNotRequested() {
        // Requesting only artifactStubbed lane-locks every other lane
        // out of its preferred mode. The file/codemap/knowledge items
        // STILL surface (the lane is requested) but with mode flipped
        // to excludedWithReason — that's the contract for "lane
        // requested, mode not requested".
        let opts = ManifestOptions(
            projectRoot: "/tmp/u10a-fixture",
            modes: [.artifactStubbed],
            lanes: [.file, .knowledge, .artifact],
            now: fixedDate
        )
        let manifest = BundleComposer.composeManifest(
            options: opts, inputs: makeInputs())
        let nonArtifactItems = manifest.items.filter { $0.lane != .artifact }
        #expect(!nonArtifactItems.isEmpty, "file/knowledge lanes still surface even when their mode is not requested")
        #expect(nonArtifactItems.allSatisfy { $0.mode == .excludedWithReason },
                "lanes whose preferred mode isn't requested must downgrade to excludedWithReason")
    }

    @Test func pendingModesEmitStubWithoutCrashing() {
        // The 3 pending modes (slice, diff-only, summary) emit one
        // forward-compat stub each with inclusion_reason
        // mode-pending-u10b — the surface accepts the request and
        // tells the caller the work is deferred.
        let opts = ManifestOptions(
            projectRoot: "/tmp/u10a-fixture",
            modes: [.slice, .diffOnly, .summary],
            lanes: Set(ContextLane.allCases),
            now: fixedDate
        )
        let manifest = BundleComposer.composeManifest(
            options: opts, inputs: makeInputs())
        let stubs = manifest.items.filter { $0.inclusionReason == "mode-pending-u10b" }
        #expect(stubs.count == 3, "one stub per requested pending mode")
        let stubModes = Set(stubs.map(\.mode))
        #expect(stubModes == [.slice, .diffOnly, .summary])
        // Each stub attaches to its natural lane: slice→file,
        // diff-only→diff, summary→knowledge.
        #expect(stubs.first { $0.mode == .slice }?.lane == .file)
        #expect(stubs.first { $0.mode == .diffOnly }?.lane == .diff)
        #expect(stubs.first { $0.mode == .summary }?.lane == .knowledge)
    }

    @Test func defaultModesExcludePendingStubs() {
        // The default ManifestOptions.modes = ContextMode.trivial,
        // so a default request produces NO mode-pending-u10b stubs.
        // Callers that want them must opt in.
        let opts = ManifestOptions(
            projectRoot: "/tmp/u10a-fixture",
            now: fixedDate
        )
        let manifest = BundleComposer.composeManifest(
            options: opts, inputs: makeInputs())
        let stubs = manifest.items.filter { $0.inclusionReason == "mode-pending-u10b" }
        #expect(stubs.isEmpty, "default modes set must not surface mode-pending stubs")
    }
}

// MARK: - CLI/MCP parity contract (Cavoukian P0 carryover, Karpathy P1)

@Suite("ContextManifest CLI/MCP parity")
struct ContextManifestParityTests {

    @Test func byteIdenticalJSONForSameInputs() {
        // CLI `senkani bundle --preview --format json` and MCP
        // `senkani_bundle preview:true` share the same renderer. This
        // test asserts the rendering is deterministic at the byte
        // level for the same inputs — the parity contract.
        let opts = ManifestOptions(
            projectRoot: "/tmp/u10a-fixture",
            modes: ContextMode.trivial,
            lanes: Set(ContextLane.allCases),
            now: fixedDate
        )
        let inputs = makeInputs()
        let a = BundleComposer.renderManifestJSON(
            BundleComposer.composeManifest(options: opts, inputs: inputs))
        let b = BundleComposer.renderManifestJSON(
            BundleComposer.composeManifest(options: opts, inputs: inputs))
        #expect(a == b, "renderManifestJSON must produce byte-identical output for identical inputs")
        // The render must round-trip back to an equal manifest.
        let decoded = try? JSONDecoder().decode(
            ContextManifest.self, from: Data(a.utf8))
        #expect(decoded != nil, "rendered JSON must decode back into a ContextManifest")
    }
}
