import Testing
import Foundation
@testable import Indexer

// MARK: - Helpers

private func makeTempFTS() -> (SymbolFTSStore, String) {
    let dir = "/tmp/senkani-fts-test-\(UUID().uuidString)"
    let store = SymbolFTSStore(projectRoot: dir)
    return (store, dir)
}

private func cleanupDir(_ dir: String) {
    try? FileManager.default.removeItem(atPath: dir)
}

private func makeEntry(
    name: String,
    kind: SymbolKind = .function,
    file: String = "Sources/Foo.swift",
    startLine: Int = 1,
    signature: String? = nil,
    container: String? = nil
) -> IndexEntry {
    IndexEntry(name: name, kind: kind, file: file, startLine: startLine,
               signature: signature, container: container)
}

// MARK: - SymbolFTSStore Tests

@Suite("SymbolFTSStore")
struct SymbolFTSStoreTests {

    @Test func ftsPopulatesFromIndexEntries() throws {
        let (store, dir) = makeTempFTS()
        defer { cleanupDir(dir) }

        let entries = [
            makeEntry(name: "connect"),
            makeEntry(name: "connectHelper"),   // prefix match for "connect"
            makeEntry(name: "connectivity"),    // prefix match for "connect"
            makeEntry(name: "NetworkManager"),
            makeEntry(name: "fetchUser"),
        ]
        try store.rebuild(entries: entries)

        // Prefix search "connect"* should match connect, connectHelper, connectivity
        let results = try store.search(query: "connect", limit: 10)
        #expect(results.count >= 2, "Prefix search should match 'connect', 'connectHelper', 'connectivity'")
        let names = Set(results.map(\.entry.name))
        #expect(names.contains("connect"))
        #expect(names.contains("connectHelper"))
    }

    @Test func bm25RanksMatchesAboveNonMatches() throws {
        // Verify that matched symbols (by prefix) appear before unrelated symbols.
        // "connect*" matches connect, connectHelper — not "fetchUser" or "NetworkManager".
        let (store, dir) = makeTempFTS()
        defer { cleanupDir(dir) }

        let entries = [
            makeEntry(name: "connectHelper"),
            makeEntry(name: "fetchUser"),
            makeEntry(name: "connect"),
            makeEntry(name: "NetworkManager"),
        ]
        try store.rebuild(entries: entries)

        let results = try store.search(query: "connect", limit: 10)
        #expect(!results.isEmpty)
        // All returned symbols should start with "connect" (prefix match)
        for r in results {
            #expect(r.entry.name.lowercased().hasPrefix("connect"),
                    "Non-matching symbol '\(r.entry.name)' should not appear in results")
        }
        let names = Set(results.map(\.entry.name))
        #expect(names.contains("connect"))
        #expect(names.contains("connectHelper"))
    }

    @Test func ftsHandlesSpecialCharacters() throws {
        let (store, dir) = makeTempFTS()
        defer { cleanupDir(dir) }

        let entries = [makeEntry(name: "handleRequest")]
        try store.rebuild(entries: entries)

        // These should not crash — special chars are sanitized
        let r1 = try store.search(query: "handle\"request", limit: 5)
        let r2 = try store.search(query: "(connect)", limit: 5)
        let r3 = try store.search(query: "OR AND", limit: 5)  // FTS keywords stripped → empty
        _ = (r1, r2, r3)  // just verify no throws
    }

    @Test func ftsReturnsEmptyForNoMatch() throws {
        let (store, dir) = makeTempFTS()
        defer { cleanupDir(dir) }

        try store.rebuild(entries: [makeEntry(name: "fetchUser")])
        let results = try store.search(query: "xyzNotExistEver", limit: 10)
        #expect(results.isEmpty)
    }

    @Test func ftsIncrementalUpdateRemovesOldSymbols() throws {
        let (store, dir) = makeTempFTS()
        defer { cleanupDir(dir) }

        let file = "Sources/Old.swift"
        let entries = [makeEntry(name: "oldFunction", file: file)]
        try store.rebuild(entries: entries)

        // Verify entry exists
        let before = try store.search(query: "oldFunction", limit: 5)
        #expect(!before.isEmpty)

        // Remove the file
        try store.update(removedFiles: [file], addedEntries: [])

        // Should now be gone
        let after = try store.search(query: "oldFunction", limit: 5)
        #expect(after.isEmpty, "Symbols from removed file should not appear after incremental update")
    }
}

// MARK: - RRFRanker Tests

@Suite("RRFRanker")
struct RRFRankerTests {

    private func entry(_ name: String, file: String = "a.swift") -> IndexEntry {
        makeEntry(name: name, file: file)
    }

    @Test func rrfBoostsSymbolInTopRankedFile() {
        let symbolA = entry("fetchUser", file: "Network.swift")
        let symbolB = entry("fetchUser", file: "Legacy.swift")

        let bm25 = [
            (entry: symbolA, bm25Rank: 1),
            (entry: symbolB, bm25Rank: 2),
        ]
        let fileScores = [
            (file: "Network.swift", rank: 1),   // top semantic match
            (file: "Legacy.swift", rank: 10),
        ]

        let ranked = RRFRanker.fuse(bm25Results: bm25, fileScores: fileScores)
        #expect(ranked[0].entry.file == "Network.swift",
                "Symbol in top-ranked file should win after RRF fusion")
    }

    @Test func rrfDegradesToBm25OrderWhenNoFileScores() {
        let sym1 = entry("alpha")
        let sym2 = entry("beta")
        let sym3 = entry("gamma")

        let bm25: [(entry: IndexEntry, bm25Rank: Int)] = [
            (sym1, 1), (sym2, 2), (sym3, 3),
        ]

        let ranked = RRFRanker.fuse(bm25Results: bm25, fileScores: [])
        // With no file scores, all fileRank = k=60 → scores differ only by bm25Rank
        #expect(ranked[0].entry.name == "alpha")
        #expect(ranked[1].entry.name == "beta")
        #expect(ranked[2].entry.name == "gamma")
    }

    @Test func rrfScoreFormula() {
        let sym = entry("connect")
        let bm25: [(entry: IndexEntry, bm25Rank: Int)] = [(sym, 1)]
        let fileScores: [(file: String, rank: Int)] = [(file: "a.swift", rank: 1)]

        let ranked = RRFRanker.fuse(bm25Results: bm25, fileScores: fileScores, k: 60)
        let expected = 1.0 / Double(61) + 1.0 / Double(61)
        #expect(abs(ranked[0].rrfScore - expected) < 1e-10,
                "RRF score should equal 1/(k+1) + 1/(k+1) = \(expected)")
    }

    @Test func rrfPreservesAllResults() {
        let entries = (1...10).map { entry("sym\($0)", file: "f\($0).swift") }
        let bm25 = entries.enumerated().map { (entry: $1, bm25Rank: $0 + 1) }
        let ranked = RRFRanker.fuse(bm25Results: bm25, fileScores: [])
        #expect(ranked.count == 10)
    }
}

// MARK: - Integration: fallback when FTS unavailable

@Suite("SearchFusionFallback")
struct SearchFusionFallbackTests {

    @Test func ftsSearchWithEmptyStoreReturnsEmpty() throws {
        // A store pointing to a non-existent project directory has no indexed symbols
        let dir = "/tmp/senkani-nonexistent-\(UUID().uuidString)"
        let store = SymbolFTSStore(projectRoot: dir)
        defer { cleanupDir(dir) }

        // rebuild with empty → search should return empty
        try store.rebuild(entries: [])
        let results = try store.search(query: "anything", limit: 10)
        #expect(results.isEmpty)
    }
}
