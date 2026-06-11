import Core
import Foundation

// MARK: - Backend seam

/// Injection seam for the PII bench harness. The bench NEVER talks to
/// MLX directly — callers hand it a backend whose two closures stand in
/// for the real classifier lifecycle:
///
///   • `load` — the cold-start surrogate (model load / graph warm). The
///     runner calls it exactly once, inside the cold-row timing window.
///   • `detectSpans` — the Layer 3 call shape (`Layer3Inference`-
///     compatible: text + per-pane softmax floor → `[PIISpan]`).
///
/// `PIIBenchRunner.stubBackend()` ships the headless default (synthetic
/// one-hot logits through the REAL `BIOESDecoder`). The operator
/// real-model perf leg (parent leg D of
/// `phase-t2-pii-classifier-backend-wiring`) reuses this seam by
/// injecting `ensureModel` + tokenize → forward → decode.
public struct PIIBenchBackend: Sendable {
    public let load: @Sendable () throws -> Void
    public let detectSpans: @Sendable (_ text: String, _ threshold: Double) throws -> [PIISpan]

    public init(
        load: @escaping @Sendable () throws -> Void,
        detectSpans: @escaping @Sendable (_ text: String, _ threshold: Double) throws -> [PIISpan]
    ) {
        self.load = load
        self.detectSpans = detectSpans
    }
}

// MARK: - Measurement

/// Raw output of one `PIIBenchRunner.run` invocation. Three slices:
/// cold (load + first call), warm (reuse-call latency samples), and
/// shape (assertion sweep over the produced spans + cross-call
/// stability). `PIIBenchRunner.report` folds this into the standard
/// `BenchmarkReport` row format.
public struct PIIBenchMeasurement: Sendable {
    /// Wall-clock ms for `backend.load()` + the FIRST `detectSpans`
    /// call. The runner guarantees `load` ran exactly once.
    public let coldMs: Double
    /// Per-call wall-clock ms for each warm (reuse) call.
    public let warmSamplesMs: [Double]
    /// Spans produced by the cold call. The runner asserts every warm
    /// call reproduces these exactly (stub determinism contract).
    public let spans: [PIISpan]
    /// Output-shape violations. Empty == shape gate passes.
    public let shapeIssues: [String]
    /// UTF-8 byte count of the fixture text (feeds the report rows).
    public let fixtureBytes: Int

    public var shapeOK: Bool { shapeIssues.isEmpty }

    public var warmMedianMs: Double {
        guard !warmSamplesMs.isEmpty else { return 0 }
        let sorted = warmSamplesMs.sorted()
        let n = sorted.count
        if n % 2 == 1 { return sorted[n / 2] }
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }
}

// MARK: - Runner

/// Headless PII-classifier bench harness — T.2 carve child A
/// (`phase-t2-pii-bench-target-2026-06-09`). Times the classifier path
/// with an INJECTED backend: no MLX model load, no network, no weights
/// on disk. Surfaced as `senkani bench pii`; emits three rows in the
/// existing Bench report format:
///
///   pii: pii_cold_start   — backend load + first detectSpans call
///   pii: pii_warm_call    — median of N reuse calls (no reload)
///   pii: pii_output_shape — span-shape assertion sweep (durationless)
///
/// Cold/warm rows carry `.estimated` confidence (stub-backend latency
/// shape, NOT real-model perf — that walk stays operator leg D of the
/// parent). The shape row is `.exact` (deterministic decode).
public enum PIIBenchRunner {

    public static let category = "pii"
    public static let coldTaskId = "pii_cold_start"
    public static let warmTaskId = "pii_warm_call"
    public static let shapeTaskId = "pii_output_shape"
    /// Report config-column label — names the injected backend so a
    /// future real-model report (`mlx_backend`) is distinguishable.
    public static let stubConfigName = "stub_backend"

    /// Default per-pane softmax floor — mirrors
    /// `PaneMode.general.piiSensitivityThreshold` (0.85) without
    /// importing the pane layer into Bench.
    public static let defaultThreshold = 0.85
    public static let defaultWarmIterations = 32

    /// Deterministic PII fixture. ASCII, single-space separated, so the
    /// stub tokenizer's char offsets equal substring offsets.
    public static let fixtureText =
        "Contact Maria Rojas at maria.rojas@example.net before the audit window opens"

    // MARK: Run

    /// Drive one cold + N warm passes through `backend` and assert the
    /// output shape. `load` is invoked exactly once (inside the cold
    /// window); every warm call must reproduce the cold call's spans.
    public static func run(
        backend: PIIBenchBackend,
        fixture: String = fixtureText,
        threshold: Double = defaultThreshold,
        warmIterations: Int = defaultWarmIterations,
        clock: @Sendable () -> Date = { Date() }
    ) throws -> PIIBenchMeasurement {
        let iterations = max(1, warmIterations)

        // Cold: load once + first call, one timing window.
        let coldStart = clock()
        try backend.load()
        let coldSpans = try backend.detectSpans(fixture, threshold)
        let coldMs = clock().timeIntervalSince(coldStart) * 1000

        // Warm: reuse the loaded backend; never re-load.
        var warmSamples: [Double] = []
        warmSamples.reserveCapacity(iterations)
        var stable = true
        for _ in 0..<iterations {
            let start = clock()
            let warmSpans = try backend.detectSpans(fixture, threshold)
            warmSamples.append(clock().timeIntervalSince(start) * 1000)
            if warmSpans != coldSpans { stable = false }
        }

        var issues = shapeIssues(spans: coldSpans, fixture: fixture)
        if !stable {
            issues.append("warm calls did not reproduce the cold call's spans (non-deterministic backend)")
        }

        return PIIBenchMeasurement(
            coldMs: coldMs,
            warmSamplesMs: warmSamples,
            spans: coldSpans,
            shapeIssues: issues,
            fixtureBytes: fixture.utf8.count
        )
    }

    // MARK: Shape sweep

    /// Output-shape assertions over a span list: non-empty for the PII
    /// fixture, in-bounds half-open char offsets, scores in 0…1,
    /// `text` matching the fixture substring, and ascending
    /// non-overlapping ordering. Returns human-readable violations
    /// (empty == pass).
    public static func shapeIssues(spans: [PIISpan], fixture: String) -> [String] {
        var issues: [String] = []
        if spans.isEmpty {
            issues.append("no spans surfaced for the PII fixture")
            return issues
        }
        let charCount = fixture.count
        for (i, span) in spans.enumerated() {
            if span.charStart < 0 || span.charEnd > charCount || span.charStart >= span.charEnd {
                issues.append("span[\(i)] has invalid offsets [\(span.charStart), \(span.charEnd)) for a \(charCount)-char fixture")
                continue
            }
            if span.score < 0 || span.score > 1 {
                issues.append("span[\(i)] score \(span.score) outside 0…1")
            }
            let lo = fixture.index(fixture.startIndex, offsetBy: span.charStart)
            let hi = fixture.index(fixture.startIndex, offsetBy: span.charEnd)
            let substring = String(fixture[lo..<hi])
            if span.text != substring {
                issues.append("span[\(i)] text '\(span.text)' != fixture substring '\(substring)'")
            }
            if i > 0, span.charStart < spans[i - 1].charEnd {
                issues.append("span[\(i)] overlaps or precedes span[\(i - 1)] (not ascending non-overlapping)")
            }
        }
        return issues
    }

    // MARK: Report

    /// Fold a measurement into the standard Bench report shape so
    /// `BenchmarkReporter.textReport` / `jsonReport` render it with
    /// zero new formatting code. Latency rows keep raw == compressed
    /// (this is a timing bench — no savings claim) and carry the
    /// timing in `durationMs`.
    public static func report(
        measurement: PIIBenchMeasurement,
        configName: String = stubConfigName,
        timestamp: Date = Date()
    ) -> BenchmarkReport {
        let bytes = measurement.fixtureBytes
        let results = [
            TaskResult(
                taskId: coldTaskId,
                configName: configName,
                category: category,
                rawBytes: bytes,
                compressedBytes: bytes,
                durationMs: measurement.coldMs,
                confidence: .estimated
            ),
            TaskResult(
                taskId: warmTaskId,
                configName: configName,
                category: category,
                rawBytes: bytes,
                compressedBytes: bytes,
                durationMs: measurement.warmMedianMs,
                confidence: .estimated
            ),
            TaskResult(
                taskId: shapeTaskId,
                configName: configName,
                category: category,
                rawBytes: bytes,
                compressedBytes: bytes,
                durationMs: 0,
                error: measurement.shapeOK ? nil : measurement.shapeIssues.joined(separator: "; "),
                confidence: .exact
            ),
        ]
        let gates = [
            QualityGate(
                name: "pii_output_shape",
                category: category,
                threshold: 100,
                actual: measurement.shapeOK ? 100 : 0
            ),
        ]
        let config = BenchmarkConfig(
            name: configName,
            filter: false, cache: false, secrets: true, indexer: false, terse: false
        )
        return BenchmarkReport(
            timestamp: timestamp,
            durationMs: measurement.coldMs + measurement.warmSamplesMs.reduce(0, +),
            configs: [config],
            results: results,
            gates: gates,
            overallMultiplier: 1.0,
            allGatesPassed: gates.allSatisfy(\.passed),
            confidence: .estimated
        )
    }

    // MARK: Stub backend

    /// Headless default backend: synthetic one-hot logits through the
    /// REAL `BIOESDecoder` (softmax + constrained Viterbi + span
    /// collapse) — so the bench times the actual pure-Swift classifier
    /// decode path with zero model bytes. Tagging is a deterministic
    /// token→tag map over the fixture vocabulary:
    ///
    ///   Maria → B-private_person, Rojas → E-private_person,
    ///   maria.rojas@example.net → S-private_email, else O.
    ///
    /// `load()` is the cold-init surrogate: it pre-runs one decode so
    /// the cold row includes a non-trivial first-touch cost, mirroring
    /// where the real backend pays its model-load.
    public static func stubBackend() -> PIIBenchBackend {
        PIIBenchBackend(
            load: {
                _ = stubDetectSpans(text: fixtureText, threshold: defaultThreshold)
            },
            detectSpans: { text, threshold in
                stubDetectSpans(text: text, threshold: threshold)
            }
        )
    }

    /// Deterministic stub classifier body. Internal so tests can call
    /// it directly when pinning determinism.
    static func stubDetectSpans(text: String, threshold: Double) -> [PIISpan] {
        let alignments = whitespaceAlignments(text)
        guard !alignments.isEmpty else { return [] }
        let logits = alignments.map { token in
            oneHotRow(tag: stubTagMap[token.text] ?? .O)
        }
        let spans = BIOESDecoder.decode(logits: logits, alignments: alignments)
        return spans.filter { $0.score >= Float(threshold) }
    }

    /// Fixture-vocabulary tag map for the stub backend.
    static let stubTagMap: [String: BIOESTag] = [
        "Maria": .B(.privatePerson),
        "Rojas": .E(.privatePerson),
        "maria.rojas@example.net": .S(.privateEmail),
    ]

    /// Single-space tokenizer with exact char offsets — token text at
    /// `[charStart, charEnd)` always equals the source substring, so
    /// the shape sweep's substring assertion holds for stub spans.
    static func whitespaceAlignments(_ text: String) -> [TokenAlignment] {
        var alignments: [TokenAlignment] = []
        var tokenStart: Int? = nil
        var current = ""
        var offset = 0
        for ch in text {
            if ch == " " {
                if let start = tokenStart {
                    alignments.append(TokenAlignment(charStart: start, charEnd: offset, text: current))
                    tokenStart = nil
                    current = ""
                }
            } else {
                if tokenStart == nil { tokenStart = offset }
                current.append(ch)
            }
            offset += 1
        }
        if let start = tokenStart {
            alignments.append(TokenAlignment(charStart: start, charEnd: offset, text: current))
        }
        return alignments
    }

    /// One-hot logit row in the 33-way BIOES tag space. Winner logit 10
    /// vs 0 elsewhere softmaxes to ≈0.999 — comfortably above the 0.85
    /// production floor.
    static func oneHotRow(tag: BIOESTag, winnerLogit: Float = 10.0) -> [Float] {
        var row = [Float](repeating: 0, count: BIOESTag.tagCount)
        row[rawIndex(tag)] = winnerLogit
        return row
    }

    /// Tag → 33-way row index. Mirrors `BIOESDecoder.rawIndex` (internal
    /// to Core, so Bench re-derives it from the public layout contract:
    /// 0 = O, then 1 + 4·category + {B,I,E,S}).
    static func rawIndex(_ tag: BIOESTag) -> Int {
        switch tag {
        case .O: return 0
        case .B(let c): return 1 + c.index * 4 + 0
        case .I(let c): return 1 + c.index * 4 + 1
        case .E(let c): return 1 + c.index * 4 + 2
        case .S(let c): return 1 + c.index * 4 + 3
        }
    }
}
