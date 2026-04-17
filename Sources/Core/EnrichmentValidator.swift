import Foundation

// MARK: - EnrichmentValidator
//
// Phase F+3 (Round 6) — safety check before an enrichment commits.
// Runs on the (live, proposed) pair and returns a list of concerns.
// Empty list → safe to commit. Non-empty → caller surfaces for human
// review instead of auto-committing.
//
// Checks:
//   1. Information loss — proposed compiled-understanding section is
//      substantially shorter than live (>40% reduction).
//   2. Contradiction — an "understanding" line in proposed directly
//      negates a line in live (simple keyword-antonym heuristic).
//   3. Excessive rewrite — >60% of the compiled-understanding section
//      replaced. Triggers review even if no other flag fires.
//
// The validator is deliberately conservative: these are heuristics,
// not guarantees. Their purpose is to surface suspicious cases, not
// to decide correctness. A flagged commit goes through
// `senkani kb review` (future) or the operator runs `senkani kb rollback`.

public enum EnrichmentValidator {

    public struct ValidationResult: Sendable, Equatable {
        public let concerns: [ValidationConcern]
        public var isSafe: Bool { concerns.isEmpty }
    }

    public enum ValidationConcern: Sendable, Equatable, CustomStringConvertible {
        case informationLoss(liveChars: Int, proposedChars: Int, reductionPct: Double)
        case contradiction(livePhrase: String, proposedPhrase: String)
        case excessiveRewrite(changedPct: Double)

        public var description: String {
            switch self {
            case .informationLoss(let l, let p, let pct):
                return "information loss: \(l) → \(p) chars (-\(Int(pct))%)"
            case .contradiction(let lp, let pp):
                return "potential contradiction: '\(lp)' vs '\(pp)'"
            case .excessiveRewrite(let pct):
                return "excessive rewrite: \(Int(pct))% of content changed"
            }
        }
    }

    /// Run validation. Extracts the `## Compiled Understanding` section
    /// from both markdown bodies and compares. If the proposed body
    /// lacks that section entirely, returns the informationLoss flag.
    public static func validate(
        live: String,
        proposed: String,
        informationLossThresholdPct: Double = 40,
        excessiveRewriteThresholdPct: Double = 60
    ) -> ValidationResult {
        let liveSection = extractCompiledUnderstanding(live)
        let proposedSection = extractCompiledUnderstanding(proposed)

        var concerns: [ValidationConcern] = []

        // 1. Information loss.
        if !liveSection.isEmpty {
            let liveLen = liveSection.count
            let propLen = proposedSection.count
            let reduction = Double(liveLen - propLen) / Double(max(liveLen, 1)) * 100.0
            if reduction > informationLossThresholdPct {
                concerns.append(.informationLoss(
                    liveChars: liveLen, proposedChars: propLen,
                    reductionPct: reduction))
            }
        }

        // 2. Contradiction — simple negation heuristic on sentence pairs.
        for (lp, pp) in contradictionPairs(live: liveSection, proposed: proposedSection) {
            concerns.append(.contradiction(livePhrase: lp, proposedPhrase: pp))
        }

        // 3. Excessive rewrite — Jaccard-style word overlap.
        if !liveSection.isEmpty && !proposedSection.isEmpty {
            let changed = wordChangedPct(live: liveSection, proposed: proposedSection)
            if changed > excessiveRewriteThresholdPct {
                concerns.append(.excessiveRewrite(changedPct: changed))
            }
        }

        return ValidationResult(concerns: concerns)
    }

    // MARK: - Helpers

    /// Grab everything under the first `## Compiled Understanding`
    /// heading, up to the next `## ` heading or EOF.
    static func extractCompiledUnderstanding(_ body: String) -> String {
        let marker = "## Compiled Understanding"
        guard let start = body.range(of: marker) else { return "" }
        let afterMarker = body[start.upperBound...]
        // Scan forward for the next "## " at column 0.
        var lines: [Substring] = []
        for line in afterMarker.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") && !lines.isEmpty { break }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Look for simple "A is X" vs "A is not X" / "A is Y" contradictions.
    /// Returns matching pairs. Overly simple — catches the common case.
    static func contradictionPairs(live: String, proposed: String) -> [(String, String)] {
        let liveSents = sentences(live)
        let propSents = sentences(proposed)
        var out: [(String, String)] = []
        for l in liveSents {
            for p in propSents {
                if let pair = contradictionPair(l, p) { out.append(pair) }
            }
        }
        return out
    }

    private static func sentences(_ s: String) -> [String] {
        s.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// A very narrow contradiction detector: if `a` says "X is ..."
    /// and `b` says "X is not ..." (or vice versa), flag.
    private static func contradictionPair(_ a: String, _ b: String) -> (String, String)? {
        let negationMarkers = [" is not ", " isn't ", " never ", " does not ", " doesn't "]
        let aHasNeg = negationMarkers.contains { a.lowercased().contains($0) }
        let bHasNeg = negationMarkers.contains { b.lowercased().contains($0) }
        guard aHasNeg != bHasNeg else { return nil }  // both-positive or both-negative — no pair
        // Subject-overlap heuristic: share at least one noun-like word
        // (capitalized or length >= 4) in the first 5 words.
        let aPrefix = Array(a.split(separator: " ").prefix(5))
        let bPrefix = Array(b.split(separator: " ").prefix(5))
        let aNouns = Set(aPrefix.filter { $0.first?.isUppercase == true || $0.count >= 4 }.map { String($0).lowercased() })
        let bNouns = Set(bPrefix.filter { $0.first?.isUppercase == true || $0.count >= 4 }.map { String($0).lowercased() })
        guard !aNouns.isDisjoint(with: bNouns) else { return nil }
        return (a, b)
    }

    /// Word-level Jaccard distance expressed as "percent of words changed."
    static func wordChangedPct(live: String, proposed: String) -> Double {
        let liveWords = Set(live.lowercased().split(separator: " ").map(String.init))
        let propWords = Set(proposed.lowercased().split(separator: " ").map(String.init))
        guard !liveWords.isEmpty else { return 0 }
        let intersection = liveWords.intersection(propWords).count
        let union = liveWords.union(propWords).count
        guard union > 0 else { return 0 }
        // Jaccard similarity. "Changed" = 1 - similarity.
        let similarity = Double(intersection) / Double(union)
        return (1 - similarity) * 100
    }
}
