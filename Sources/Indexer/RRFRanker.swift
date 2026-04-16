import Foundation

/// A symbol with its combined RRF score from BM25 + embedding signals.
public struct RankedEntry: Sendable {
    public let entry: IndexEntry
    /// Combined RRF score. Higher = better. Range: (0, 2/k].
    public let rrfScore: Double
    /// 1-based rank from BM25 FTS5 search.
    public let bm25Rank: Int

    public init(entry: IndexEntry, rrfScore: Double, bm25Rank: Int) {
        self.entry = entry
        self.rrfScore = rrfScore
        self.bm25Rank = bm25Rank
    }
}

/// Reciprocal Rank Fusion over BM25 + file-level embedding signals.
///
/// Formula: score(symbol) = 1/(k + bm25Rank) + 1/(k + fileRank)
///
/// - `bm25Rank`: 1-based rank from FTS5 ORDER BY rank (1 = best lexical match)
/// - `fileRank`: 1-based rank of the symbol's file in MiniLM embedding results
///              (default k when file not in embedding results → minimal boost)
/// - `k = 60`: standard RRF constant; prevents rank-1 from dominating
///
/// Degrades gracefully: when `fileScores` is empty, all fileRank = k,
/// adding a flat 1/(2k) to every score — preserving BM25 order.
public enum RRFRanker {
    public static func fuse(
        bm25Results: [(entry: IndexEntry, bm25Rank: Int)],
        fileScores: [(file: String, rank: Int)],
        k: Int = 60
    ) -> [RankedEntry] {
        let fileRankMap: [String: Int] = Dictionary(
            uniqueKeysWithValues: fileScores.map { ($0.file, $0.rank) }
        )
        return bm25Results
            .map { (entry, bm25Rank) -> RankedEntry in
                let fileRank = fileRankMap[entry.file] ?? k
                let score = 1.0 / Double(k + bm25Rank) + 1.0 / Double(k + fileRank)
                return RankedEntry(entry: entry, rrfScore: score, bm25Rank: bm25Rank)
            }
            .sorted { $0.rrfScore > $1.rrfScore }
    }
}
