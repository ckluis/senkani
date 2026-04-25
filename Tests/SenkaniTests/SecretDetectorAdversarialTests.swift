import Testing
import Foundation
@testable import Core

/// Adversarial corpus + precision/recall harness for the Stage-2 secret
/// pipeline (SecretDetector + EntropyScanner). Replaces the older
/// "100% redaction" claim — measured against a hand-curated fixture
/// suite — with honest per-family numbers measured against ≥50
/// adversarial inputs.
///
/// Round: luminary-2026-04-24-2-secretdetector-adversarial-corpus.
///
/// Fixtures live in `Tests/SenkaniTests/Fixtures/secrets-adversarial/*.txt`
/// and are bundled via the test target's `.copy` resource. Each file
/// has a `# key: value` header followed by `---\n` and a body.
@Suite("SecretDetectorAdversarial") struct SecretDetectorAdversarialTests {

    // MARK: - Corpus loader

    struct Fixture: Sendable, CustomStringConvertible {
        enum MatchMode: String, Sendable { case any, all, none }
        let id: String
        let family: String
        let expected: Set<String>
        let matchMode: MatchMode
        let summary: String
        /// True when the fixture documents a known recall gap. Per-fixture
        /// test asserts the gap is still present (no expected pattern fires);
        /// metrics still count the miss as FN. If a future scanner change
        /// closes the gap, the per-fixture test fails — flip the field
        /// to false and the gap fixture becomes a coverage fixture.
        let documentedGap: Bool
        let body: String

        var description: String { id }
    }

    static let corpus: [Fixture] = loadCorpus()

    private static func loadCorpus() -> [Fixture] {
        let bundle = Bundle.module
        guard let dir = bundle.resourceURL?
            .appendingPathComponent("secrets-adversarial", isDirectory: true)
        else { return [] }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let files = entries.filter { $0.pathExtension == "txt" }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        return files.compactMap { url -> Fixture? in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return parse(text, fileName: url.lastPathComponent)
        }
    }

    private static func parse(_ text: String, fileName: String) -> Fixture? {
        guard let separatorRange = text.range(of: "\n---\n") else { return nil }
        let header = text[text.startIndex..<separatorRange.lowerBound]
        let body = String(text[separatorRange.upperBound...])
        var fields: [String: String] = [:]
        for line in header.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            let after = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            guard let colon = after.firstIndex(of: ":") else { continue }
            let key = after[..<colon].trimmingCharacters(in: .whitespaces)
            let value = after[after.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        guard let id = fields["id"],
              let family = fields["family"],
              let expectedRaw = fields["expected"],
              let modeRaw = fields["match_mode"],
              let mode = Fixture.MatchMode(rawValue: modeRaw)
        else { return nil }
        let expected: Set<String> = expectedRaw == "NONE"
            ? []
            : Set(expectedRaw.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            })
        let documentedGap = (fields["documented_gap"] ?? "false")
            .lowercased() == "true"
        return Fixture(
            id: id,
            family: family,
            expected: expected,
            matchMode: mode,
            summary: fields["description"] ?? fileName,
            documentedGap: documentedGap,
            body: body
        )
    }

    /// Stage-2 pipeline (named patterns + entropy) — what the
    /// FilterPipeline actually runs in production.
    private static func stage2Scan(_ input: String) -> Set<String> {
        let named = SecretDetector.scan(input)
        let entropy = EntropyScanner.scan(named.redacted)
        return Set(named.patterns).union(entropy.patterns)
    }

    // MARK: - Per-family thresholds
    //
    // Calibrated 2026-04-24 against the corpus. Families with known
    // recall gaps document them here (rather than in the test failure
    // log) so the round can ship honest numbers without a noisy red
    // CI. Any divergence from these floors is flagged to
    // spec/cleanup.md as a follow-up.

    struct Threshold: Sendable, CustomStringConvertible {
        let family: String
        let minPrecision: Double
        let minRecall: Double
        let note: String

        var description: String { family }
    }

    static let thresholds: [Threshold] = [
        // Calibration baseline: 2026-04-24 corpus run on 53 fixtures.
        // Floors at or just below measured numbers — a regression that
        // drops a family below its floor fails the test.
        .init(family: "anthropic",            minPrecision: 1.00, minRecall: 1.00, note: "sk-ant- prefix is unique."),
        .init(family: "openai",               minPrecision: 1.00, minRecall: 1.00, note: "sk- prefix + 20-char body."),
        .init(family: "openai_project",       minPrecision: 1.00, minRecall: 1.00, note: "sk-proj- dedicated pattern."),
        .init(family: "aws_keyid",            minPrecision: 1.00, minRecall: 1.00, note: "AKIA + 16 alphanum is unique."),
        .init(family: "aws_secret",           minPrecision: 1.00, minRecall: 1.00, note: "Hyphenated key names fall back to entropy (still redacted)."),
        .init(family: "github",               minPrecision: 1.00, minRecall: 1.00, note: "gh[pousr]_ prefixes; URL host residual may also trip entropy."),
        .init(family: "slack",                minPrecision: 1.00, minRecall: 1.00, note: "xox[abprs] prefixes covered."),
        .init(family: "gcp",                  minPrecision: 1.00, minRecall: 1.00, note: "ya29. prefix."),
        .init(family: "stripe",               minPrecision: 1.00, minRecall: 1.00, note: "sk_(live|test)_ prefix."),
        .init(family: "npm",                  minPrecision: 1.00, minRecall: 1.00, note: "npm_ prefix."),
        .init(family: "huggingface",          minPrecision: 1.00, minRecall: 1.00, note: "hf_ prefix."),
        .init(family: "bearer",               minPrecision: 1.00, minRecall: 1.00, note: "Case-insensitive Bearer prefix."),
        .init(family: "generic_api",          minPrecision: 1.00, minRecall: 1.00, note: "Keyword regex + entropy fallback covers all measured shapes."),
        .init(family: "jwt_bare",             minPrecision: 1.00, minRecall: 1.00, note: "Bare JWTs detected via entropy on the long base64 token."),
        .init(family: "pem_key",              minPrecision: 1.00, minRecall: 1.00, note: "PEM body lines redacted via entropy."),
        .init(family: "signed_url",           minPrecision: 1.00, minRecall: 0.50, note: "GAP: GCS-style signed URLs leak (URL-prefix exclusion swallows the whole token). 1/2 fixtures detected."),
        .init(family: "short_token",          minPrecision: 1.00, minRecall: 0.00, note: "GAP: sub-threshold tokens (Slack <10ch body, Stripe <24ch, Twilio AC unsupported) cannot match by design."),
        .init(family: "dotenv",               minPrecision: 1.00, minRecall: 1.00, note: "PASSWORD/SECRET env names use entropy fallback."),
        .init(family: "obfuscated",           minPrecision: 1.00, minRecall: 0.50, note: "GAP: 66-char pure-hex blobs sit below the 4.5 entropy floor (max 4.0 for hex)."),
        .init(family: "multi_secret",         minPrecision: 1.00, minRecall: 1.00, note: "All secrets in fixture must redact (match_mode: all)."),
        .init(family: "high_entropy",         minPrecision: 1.00, minRecall: 1.00, note: "Direct entropy detection."),
        .init(family: "false_positive_guard", minPrecision: 1.00, minRecall: 1.00, note: "Precision = no FPs (recall is trivially 1.0 with no expected positives)."),
    ]

    // MARK: - Per-fixture parameterized test
    //
    // 53 fixture rows = 53 test invocations. Each row asserts the
    // fixture's local expectation (any/all/none) — a single fixture
    // failure points at the file by id. Family-level thresholds are
    // checked by `reportFamilyMetrics`.

    @Test("fixture-level expectation", arguments: SecretDetectorAdversarialTests.corpus)
    func fixtureLevelExpectation(_ fixture: Fixture) {
        let detected = Self.stage2Scan(fixture.body)
        if fixture.documentedGap {
            #expect(
                detected.isDisjoint(with: fixture.expected),
                "[\(fixture.id)] documented gap appears closed — got \(detected.sorted()). Flip documented_gap to false and update spec/testing.md."
            )
            return
        }
        switch fixture.matchMode {
        case .any:
            #expect(
                !detected.isDisjoint(with: fixture.expected),
                "[\(fixture.id)] expected ANY of \(fixture.expected.sorted()) but got \(detected.sorted())"
            )
        case .all:
            #expect(
                fixture.expected.isSubset(of: detected),
                "[\(fixture.id)] expected ALL of \(fixture.expected.sorted()) but got \(detected.sorted())"
            )
        case .none:
            #expect(
                detected.isEmpty,
                "[\(fixture.id)] expected NO matches but got \(detected.sorted())"
            )
        }
    }

    // MARK: - Per-family threshold tests

    @Test("family thresholds", arguments: SecretDetectorAdversarialTests.thresholds)
    func familyThreshold(_ threshold: Threshold) {
        let metrics = Self.metricsForFamily(threshold.family)
        #expect(
            metrics.precision >= threshold.minPrecision,
            "[\(threshold.family)] precision \(metrics.precision) < floor \(threshold.minPrecision) — \(threshold.note)"
        )
        #expect(
            metrics.recall >= threshold.minRecall,
            "[\(threshold.family)] recall \(metrics.recall) < floor \(threshold.minRecall) — \(threshold.note)"
        )
    }

    // MARK: - Summary reporter (also asserts ≥1 fixture per family)

    @Test func reportFamilyMetrics() {
        let report = Self.buildReport()

        // Print the table to stdout so CI / `swift test` captures it.
        // Pure Swift formatting (no `String(format:)` with `%s` — that
        // can segfault when passed a Swift `String` because `%s` reads
        // a `char*` while the bridge produces an NSString).
        print("\n=== SecretDetector adversarial corpus — \(Self.corpus.count) fixtures ===")
        print(Self.formatRow("family", "TP", "FP", "FN", "TN", "precision", "recall"))
        print(String(repeating: "-", count: 78))
        for row in report.rows.sorted(by: { $0.family < $1.family }) {
            print(Self.formatRow(
                row.family,
                String(row.tp), String(row.fp), String(row.fn), String(row.tn),
                String(format: "%.3f", row.precision),
                String(format: "%.3f", row.recall)
            ))
        }
        print(String(repeating: "-", count: 78))
        print(Self.formatRow(
            "TOTAL",
            String(report.tp), String(report.fp), String(report.fn), String(report.tn),
            String(format: "%.3f", report.precision),
            String(format: "%.3f", report.recall)
        ))
        print("=== end report ===\n")

        #expect(Self.corpus.count >= 50, "Corpus must contain ≥50 fixtures, got \(Self.corpus.count)")
        #expect(report.rows.count >= 10, "Need ≥10 distinct families, got \(report.rows.count)")

        // Per-fixture truth dump — useful when calibrating thresholds
        // or chasing a precision/recall regression. Always emitted; the
        // test runner aggregates stdout per-test so this is searchable
        // by `swift test --filter SecretDetectorAdversarial`.
        print("--- per-fixture detections ---")
        for fixture in Self.corpus.sorted(by: { $0.id < $1.id }) {
            let detected = Self.stage2Scan(fixture.body)
            print("  \(fixture.id) [\(fixture.family)/\(fixture.matchMode.rawValue)] expected=\(fixture.expected.sorted()) got=\(detected.sorted())")
        }
        print("--- end per-fixture dump ---")
    }

    private static func formatRow(
        _ family: String, _ tp: String, _ fp: String, _ fn: String,
        _ tn: String, _ precision: String, _ recall: String
    ) -> String {
        let pad = { (s: String, w: Int) -> String in
            s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
        }
        let lpad = { (s: String, w: Int) -> String in
            s.count >= w ? s : String(repeating: " ", count: w - s.count) + s
        }
        return [
            pad(family, 22),
            lpad(tp, 4), lpad(fp, 4), lpad(fn, 4), lpad(tn, 4),
            " ",
            pad(precision, 9), pad(recall, 9)
        ].joined(separator: " ")
    }

    // MARK: - Metrics math

    struct FamilyMetrics: Sendable {
        let family: String
        let tp: Int
        let fp: Int
        let fn: Int
        let tn: Int

        /// Precision = TP / (TP + FP). Defined as 1.0 when no
        /// positives were expected (FP-guard families).
        var precision: Double {
            let denom = tp + fp
            return denom == 0 ? 1.0 : Double(tp) / Double(denom)
        }

        /// Recall = TP / (TP + FN). Defined as 1.0 when no positives
        /// were expected.
        var recall: Double {
            let denom = tp + fn
            return denom == 0 ? 1.0 : Double(tp) / Double(denom)
        }
    }

    struct Report: Sendable {
        let rows: [FamilyMetrics]
        let tp: Int
        let fp: Int
        let fn: Int
        let tn: Int
        var precision: Double {
            let denom = tp + fp
            return denom == 0 ? 1.0 : Double(tp) / Double(denom)
        }
        var recall: Double {
            let denom = tp + fn
            return denom == 0 ? 1.0 : Double(tp) / Double(denom)
        }
    }

    /// Metric semantics:
    ///   - `match_mode: any`   — TP if any expected pattern fires, FN otherwise.
    ///                            Any pattern outside the expected set on the
    ///                            same fixture counts as 1 FP for *this fixture*
    ///                            (precision tracks "extra" detections).
    ///   - `match_mode: all`   — TP only if all expected fire; FN otherwise.
    ///                            Extras still count as FP.
    ///   - `match_mode: none`  — Any detection is an FP; otherwise TN.
    private static func metricsForFamily(_ family: String) -> FamilyMetrics {
        var tp = 0, fp = 0, fn = 0, tn = 0
        for fixture in corpus where fixture.family == family {
            let detected = stage2Scan(fixture.body)
            switch fixture.matchMode {
            case .any:
                if !detected.isDisjoint(with: fixture.expected) { tp += 1 } else { fn += 1 }
                let extras = detected.subtracting(fixture.expected)
                if !extras.isEmpty { fp += 1 }
            case .all:
                if fixture.expected.isSubset(of: detected) { tp += 1 } else { fn += 1 }
                let extras = detected.subtracting(fixture.expected)
                if !extras.isEmpty { fp += 1 }
            case .none:
                if detected.isEmpty { tn += 1 } else { fp += 1 }
            }
        }
        return FamilyMetrics(family: family, tp: tp, fp: fp, fn: fn, tn: tn)
    }

    private static func buildReport() -> Report {
        let families = Set(corpus.map(\.family))
        var rows: [FamilyMetrics] = []
        var tp = 0, fp = 0, fn = 0, tn = 0
        for family in families {
            let row = metricsForFamily(family)
            rows.append(row)
            tp += row.tp; fp += row.fp; fn += row.fn; tn += row.tn
        }
        return Report(rows: rows, tp: tp, fp: fp, fn: fn, tn: tn)
    }
}
