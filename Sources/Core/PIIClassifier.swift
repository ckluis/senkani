import Foundation

/// PII categories produced by the openai/privacy-filter classifier (Layer 3
/// of `SecretDetector`). Tag space is 1 + 8*4 = 33: one background `O` plus
/// 8 categories each carrying BIOES boundaries.
public enum PIICategory: String, CaseIterable, Codable, Sendable, Equatable {
    case accountNumber  = "account_number"
    case privateAddress = "private_address"
    case privateEmail   = "private_email"
    case privatePerson  = "private_person"
    case privatePhone   = "private_phone"
    case privateURL     = "private_url"
    case privateDate    = "private_date"
    case secret         = "secret"

    /// Stable index used to compute the tag space layout.
    public var index: Int {
        switch self {
        case .accountNumber:  return 0
        case .privateAddress: return 1
        case .privateEmail:   return 2
        case .privatePerson:  return 3
        case .privatePhone:   return 4
        case .privateURL:     return 5
        case .privateDate:    return 6
        case .secret:         return 7
        }
    }

    public init?(index: Int) {
        guard index >= 0, index < PIICategory.allCases.count else { return nil }
        self = PIICategory.allCases[index]
    }
}

/// One detected span of PII inside a piece of text.
public struct PIISpan: Sendable, Equatable {
    public let category: PIICategory
    /// Average per-token tag probability across the span. Range 0…1 when
    /// logits are passed through softmax; raw-logit callers see
    /// non-normalized averages.
    public let score: Float
    /// Half-open character offsets `[charStart, charEnd)` in the original
    /// text. Always derived from the supplied `TokenAlignment` rows.
    public let charStart: Int
    public let charEnd: Int
    public let text: String

    public init(category: PIICategory, score: Float, charStart: Int, charEnd: Int, text: String) {
        self.category = category
        self.score = score
        self.charStart = charStart
        self.charEnd = charEnd
        self.text = text
    }
}

/// Per-token alignment back into the original text. The decoder consumes
/// `[T]` of these alongside the `[T, 33]` logits matrix and returns spans
/// whose offsets are taken from the matching alignment rows.
public struct TokenAlignment: Sendable, Equatable {
    public let charStart: Int
    public let charEnd: Int
    public let text: String

    public init(charStart: Int, charEnd: Int, text: String) {
        self.charStart = charStart
        self.charEnd = charEnd
        self.text = text
    }
}

// MARK: - BIOES tag layout

/// Tag-space helpers. The 33-way tag layout is:
///
///     index 0           → O (background)
///     index 1 + 4c + 0  → B-<category c>
///     index 1 + 4c + 1  → I-<category c>
///     index 1 + 4c + 2  → E-<category c>
///     index 1 + 4c + 3  → S-<category c>
///
/// where category index `c ∈ 0..<8`. The decoder is agnostic to which row
/// of the model actually carries which category — the calling adapter is
/// responsible for matching the model card's tag order to `PIICategory.index`.
public enum BIOESTag: Sendable, Equatable {
    case O
    case B(PIICategory)
    case I(PIICategory)
    case E(PIICategory)
    case S(PIICategory)

    /// 33-way tag count: 1 background + 8 categories × 4 BIOES tags.
    public static let tagCount = 1 + PIICategory.allCases.count * 4

    /// Decode a tag-space integer into a `BIOESTag`. Returns `nil` when out
    /// of range (the decoder treats out-of-range tags as `O`).
    public static func from(rawIndex i: Int) -> BIOESTag? {
        if i == 0 { return .O }
        let r = i - 1
        guard r >= 0, r < PIICategory.allCases.count * 4 else { return nil }
        let category = PIICategory(index: r / 4)!
        switch r % 4 {
        case 0: return .B(category)
        case 1: return .I(category)
        case 2: return .E(category)
        case 3: return .S(category)
        default: return nil
        }
    }

    /// Convenience: collapse the tag's BIOES boundary to the underlying
    /// category (or `nil` for `O`).
    public var category: PIICategory? {
        switch self {
        case .O: return nil
        case .B(let c), .I(let c), .E(let c), .S(let c): return c
        }
    }

    /// `true` if the (prev → curr) transition is allowed by the constraint
    /// table:
    ///
    ///     O → O|B|S
    ///     B-X → I-X | E-X     (must keep category)
    ///     I-X → I-X | E-X     (must keep category)
    ///     E-X → O | B-* | S-*
    ///     S-X → O | B-* | S-*
    ///
    /// Cross-category transitions only happen via O / B / S — never I / E.
    public static func isTransitionAllowed(_ prev: BIOESTag, _ curr: BIOESTag) -> Bool {
        switch prev {
        case .O:
            switch curr {
            case .O, .B, .S: return true
            case .I, .E: return false
            }
        case .B(let pc):
            switch curr {
            case .I(let cc), .E(let cc): return pc == cc
            default: return false
            }
        case .I(let pc):
            switch curr {
            case .I(let cc), .E(let cc): return pc == cc
            default: return false
            }
        case .E:
            switch curr {
            case .O, .B, .S: return true
            case .I, .E: return false
            }
        case .S:
            switch curr {
            case .O, .B, .S: return true
            case .I, .E: return false
            }
        }
    }
}

// MARK: - Decoder

/// Pure-Swift BIOES + constrained Viterbi decoder. Token-classifier output
/// (`[T, 33]` logits) collapses to a list of `PIISpan`s honoring the
/// transition table above.
public enum BIOESDecoder {

    /// Run constrained Viterbi over `logits` and emit the resulting spans.
    ///
    /// - Parameters:
    ///   - logits: `[T][33]` row-major matrix. May be raw logits or
    ///     log-probabilities — Viterbi only needs a relative score per row.
    ///     For the span-score calculation we softmax each row so the
    ///     reported `PIISpan.score` is comparable across calls.
    ///   - alignments: `[T]` token → text offset rows. Must have the same
    ///     length as `logits`.
    /// - Returns: detected spans in order of `charStart`.
    ///
    /// - Note: `[]` and one-token inputs are short-circuited. For
    ///   multi-token argmax sequences that violate the BIOES constraints
    ///   (e.g. three consecutive `B-person` tags), Viterbi rebalances the
    ///   path so the output is either a single coherent span or empty —
    ///   never a malformed boundary.
    public static func decode(
        logits: [[Float]],
        alignments: [TokenAlignment]
    ) -> [PIISpan] {
        precondition(logits.count == alignments.count,
                     "logits and alignments must align: got \(logits.count) vs \(alignments.count) rows")

        let T = logits.count
        if T == 0 { return [] }

        // 1. Softmax each row so per-token probabilities are comparable.
        let probs = logits.map(Self.softmax)
        // 2. Run constrained Viterbi to pick the best tag sequence.
        let path = viterbi(probs: probs)
        // 3. Walk the path and emit spans.
        return collapseSpans(path: path, probs: probs, alignments: alignments)
    }

    // MARK: - Softmax

    /// Numerically stable softmax. Subtracts the row max before exponentiating.
    static func softmax(_ row: [Float]) -> [Float] {
        guard !row.isEmpty else { return row }
        let m = row.max()!
        let exps = row.map { Float(exp(Double($0 - m))) }
        let sum = exps.reduce(Float(0), +)
        guard sum > 0 else { return row.map { _ in 1 / Float(row.count) } }
        return exps.map { $0 / sum }
    }

    // MARK: - Viterbi

    /// Constrained Viterbi over the BIOES tag space. Disallowed transitions
    /// are pruned by setting their score to `-infinity` in log-space.
    /// Returns `[T]` of `BIOESTag` (the decoded sequence).
    static func viterbi(probs: [[Float]]) -> [BIOESTag] {
        let T = probs.count
        let K = BIOESTag.tagCount
        guard T > 0 else { return [] }

        // Enumerate all 33 tag instances once — the decoder reuses them.
        let tags: [BIOESTag] = (0..<K).compactMap { BIOESTag.from(rawIndex: $0) }
        precondition(tags.count == K, "BIOES tag enumeration broken: expected \(K), got \(tags.count)")

        let negInf: Float = -.greatestFiniteMagnitude

        // dp[t][k] = log-probability of best path ending at tag k at step t.
        // bp[t][k] = back-pointer (best prev tag) at step (t, k).
        var dp = Array(repeating: Array(repeating: negInf, count: K), count: T)
        var bp = Array(repeating: Array(repeating: -1, count: K), count: T)

        // Initialization — step 0. Only emissions valid as a start tag get
        // weight; per the table, step 0's "prev" is implicit O so allowed
        // start tags are O, B-*, S-*.
        for k in 0..<K {
            let tag = tags[k]
            switch tag {
            case .O, .B, .S:
                dp[0][k] = Self.logSafe(probs[0][k])
            case .I, .E:
                dp[0][k] = negInf
            }
        }

        // Recurrence.
        for t in 1..<T {
            for kCurr in 0..<K {
                let curr = tags[kCurr]
                let emit = Self.logSafe(probs[t][kCurr])
                if emit == negInf { continue }
                var best: Float = negInf
                var bestPrev = -1
                for kPrev in 0..<K {
                    let prev = tags[kPrev]
                    guard BIOESTag.isTransitionAllowed(prev, curr) else { continue }
                    let cand = dp[t-1][kPrev] + emit
                    if cand > best {
                        best = cand
                        bestPrev = kPrev
                    }
                }
                dp[t][kCurr] = best
                bp[t][kCurr] = bestPrev
            }
        }

        // Termination — pick best tag at step T-1 that's a valid end tag.
        // Per the constraints, valid end tags are O, E-*, S-*. (A path
        // ending in B-* or I-* would be mid-entity and is rejected.)
        var bestEnd = -1
        var bestScore: Float = negInf
        for k in 0..<K {
            switch tags[k] {
            case .O, .E, .S:
                if dp[T-1][k] > bestScore {
                    bestScore = dp[T-1][k]
                    bestEnd = k
                }
            case .B, .I:
                continue
            }
        }
        // Fallback: if every path is -inf (e.g. T==1 with only I/E mass),
        // collapse to all-O. The decoder must never crash on adversarial
        // logits.
        if bestEnd < 0 {
            return Array(repeating: .O, count: T)
        }

        // Backtrack.
        var path = Array(repeating: BIOESTag.O, count: T)
        path[T-1] = tags[bestEnd]
        var k = bestEnd
        for t in stride(from: T-1, through: 1, by: -1) {
            let prev = bp[t][k]
            if prev < 0 {
                // The recurrence couldn't extend this step — force O for
                // the prefix. Shouldn't happen with consistent constraints,
                // but guards against numeric edge cases.
                for i in 0..<t { path[i] = .O }
                break
            }
            path[t-1] = tags[prev]
            k = prev
        }
        return path
    }

    /// Log of a probability with a `-inf` floor for zero / negative inputs.
    /// Avoids `log(0)` producing NaN under aggressive optimization settings.
    static func logSafe(_ p: Float) -> Float {
        guard p > 0 else { return -.greatestFiniteMagnitude }
        return Float(log(Double(p)))
    }

    // MARK: - Span collapse

    /// Walk a decoded BIOES path and emit `PIISpan`s.
    ///
    /// A span starts on `B-X` or `S-X` and ends on `E-X` or the same `S-X`.
    /// `I-X` extends an open span without changing its category. The
    /// decoder upstream guarantees boundary integrity via the transition
    /// table — this collapse is a straightforward state machine.
    static func collapseSpans(
        path: [BIOESTag],
        probs: [[Float]],
        alignments: [TokenAlignment]
    ) -> [PIISpan] {
        var spans: [PIISpan] = []
        var openCategory: PIICategory? = nil
        var openStart: Int = 0
        var openCharStart: Int = 0
        var openScoreSum: Float = 0
        var openTokenCount: Int = 0

        for (t, tag) in path.enumerated() {
            switch tag {
            case .O:
                openCategory = nil

            case .B(let c):
                openCategory = c
                openStart = t
                openCharStart = alignments[t].charStart
                openScoreSum = probs[t][rawIndex(.B(c))]
                openTokenCount = 1

            case .I(let c):
                if openCategory == c {
                    openScoreSum += probs[t][rawIndex(.I(c))]
                    openTokenCount += 1
                } else {
                    // Defensive — Viterbi shouldn't surface I without B.
                    openCategory = nil
                }

            case .E(let c):
                if openCategory == c {
                    openScoreSum += probs[t][rawIndex(.E(c))]
                    openTokenCount += 1
                    let charEnd = alignments[t].charEnd
                    let avg = openTokenCount > 0 ? openScoreSum / Float(openTokenCount) : 0
                    let text = textBetween(
                        from: openStart,
                        to: t,
                        alignments: alignments
                    )
                    spans.append(PIISpan(
                        category: c,
                        score: avg,
                        charStart: openCharStart,
                        charEnd: charEnd,
                        text: text
                    ))
                }
                openCategory = nil

            case .S(let c):
                let alignment = alignments[t]
                let prob = probs[t][rawIndex(.S(c))]
                spans.append(PIISpan(
                    category: c,
                    score: prob,
                    charStart: alignment.charStart,
                    charEnd: alignment.charEnd,
                    text: alignment.text
                ))
                openCategory = nil
            }
        }

        return spans
    }

    /// Map `BIOESTag` back to its 33-way row index. Used when reading a
    /// per-token probability for the picked tag.
    static func rawIndex(_ tag: BIOESTag) -> Int {
        switch tag {
        case .O: return 0
        case .B(let c): return 1 + c.index * 4 + 0
        case .I(let c): return 1 + c.index * 4 + 1
        case .E(let c): return 1 + c.index * 4 + 2
        case .S(let c): return 1 + c.index * 4 + 3
        }
    }

    /// Reconstruct the multi-token span text by concatenating per-token
    /// text. Inserts a single space between tokens whose alignments are
    /// non-adjacent in the original text — preserves whitespace shape
    /// without requiring the caller to retain the source string.
    static func textBetween(
        from i: Int,
        to j: Int,
        alignments: [TokenAlignment]
    ) -> String {
        guard i <= j, j < alignments.count else { return "" }
        var out = alignments[i].text
        var prevEnd = alignments[i].charEnd
        for k in (i+1)...j {
            let a = alignments[k]
            if a.charStart > prevEnd {
                out += " "
            }
            out += a.text
            prevEnd = a.charEnd
        }
        return out
    }
}
