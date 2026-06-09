import Foundation

/// Release-commitment SLOs (Phase V.14).
///
/// Distinct from the runtime hot-path SLOs in `SLO.swift`. Where those
/// answer "is the hot path fast right now?", these answer "is what we
/// ship still small and snappy?". They are captured once per release
/// (or once per CI run) by `tools/measure-slos.sh` and persist as one
/// JSON object per line in `~/.senkani/slo-history.jsonl`.
///
/// `senkani doctor` reads the latest row, renders the four numbers,
/// and runs a regression check against a median-of-5 baseline.

public enum ReleaseSLOName: String, CaseIterable, Sendable {
    case coldStart       = "cold.start"
    case idleMemory      = "idle.memory"
    case installSize     = "install.size"
    case classifierP95   = "classifier.p95"
    case openaiColdStart = "openai.cold.start"

    public var thresholdLabel: String {
        switch self {
        case .coldStart:       return "< 250 ms p95"
        case .idleMemory:      return "< 75 MB"
        // install.size is enforced PER-BINARY (see ReleaseSLOInstallBudget),
        // not against one summed total. The label points there rather than
        // implying a single number the family can never meet (the MLX/Metal
        // daemon alone is ~67 MB stripped).
        case .installSize:     return "per-binary budgets (stripped)"
        case .classifierP95:   return "< 2 ms p95"
        case .openaiColdStart: return "< 1500 ms p95"
        }
    }

    public var threshold: Double {
        switch self {
        case .coldStart:       return 250.0
        case .idleMemory:      return 75.0
        // Retained as the SUM of the per-binary budgets so the legacy
        // single-value `install_size_mb` total still has a meaningful
        // ceiling for the doctor surface + the regression baseline.
        // The authoritative gate is ReleaseSLOInstallBudget (per-binary).
        case .installSize:     return ReleaseSLOInstallBudget.totalBudgetMB
        case .classifierP95:   return 2.0
        case .openaiColdStart: return 1500.0
        }
    }

    public var unit: String {
        switch self {
        case .coldStart, .classifierP95, .openaiColdStart:  return "ms"
        case .idleMemory, .installSize:                     return "MB"
        }
    }
}

/// Per-binary install-size budgets (D5,
/// slo-install-size-unstripped-exceeds-50mb-threshold-2026-05-27).
///
/// `install.size` is NOT one summed gate. The shipped product family
/// spans a 1 MB hook and a ~67 MB MLX/Metal daemon; no single total is
/// honest. Each `.executable` product carries its OWN falsifiable budget
/// against its STRIPPED size (stripping is lossless — every product has a
/// sibling `.dSYM`). Keep this list in sync with `tools/measure-install-size.sh`.
public enum ReleaseSLOInstallBudget: Sendable {
    /// One shipped product's budget. `measuredMB` is the STRIPPED size.
    public struct Budget: Sendable, Equatable {
        public let product: String
        public let budgetMB: Double
        public let rationale: String
        public init(product: String, budgetMB: Double, rationale: String) {
            self.product = product
            self.budgetMB = budgetMB
            self.rationale = rationale
        }
    }

    /// The canonical per-binary budget table. Budgets sit above the
    /// measured stripped size (in comments) with deliberate headroom; a
    /// product over its budget is a real regression, not noise.
    public static let budgets: [Budget] = [
        Budget(product: "senkani",            budgetMB: 50, rationale: "CLI; 44 MB stripped"),
        Budget(product: "senkani-mcp",        budgetMB: 70, rationale: "MLX/Metal daemon, irreducible; 67 MB stripped"),
        Budget(product: "senkani-hook",       budgetMB: 5,  rationale: "zero-dep hook; 1 MB stripped"),
        Budget(product: "senkani-mig-helper", budgetMB: 15, rationale: "migration helper; 5 MB stripped"),
    ]

    /// Sum of the per-binary budgets — the ceiling the legacy summed
    /// `install_size_mb` total is checked against.
    public static var totalBudgetMB: Double {
        budgets.reduce(0) { $0 + $1.budgetMB }
    }

    /// Budget for a named product, or `nil` if it carries no budget
    /// (e.g. the SenkaniApp GUI bundle, which ships via DMG not a CLI).
    public static func budget(for product: String) -> Double? {
        budgets.first { $0.product == product }?.budgetMB
    }

    /// Per-binary verdict: which measured products are over budget.
    /// `measured` maps product name → stripped MB. Products with no
    /// budget are ignored; budgeted products absent from `measured`
    /// are simply not evaluated (a measurement miss, not a breach).
    public struct CheckResult: Sendable, Equatable {
        public struct Line: Sendable, Equatable {
            public let product: String
            public let measuredMB: Double
            public let budgetMB: Double
            public var overBudget: Bool { measuredMB > budgetMB }
            public init(product: String, measuredMB: Double, budgetMB: Double) {
                self.product = product
                self.measuredMB = measuredMB
                self.budgetMB = budgetMB
            }
        }
        public let lines: [Line]
        public var anyOverBudget: Bool { lines.contains { $0.overBudget } }
        public var breaches: [Line] { lines.filter { $0.overBudget } }
        public init(lines: [Line]) { self.lines = lines }
    }

    /// Evaluate measured stripped sizes against the per-binary budgets.
    public static func check(measured: [String: Double]) -> CheckResult {
        let lines: [CheckResult.Line] = budgets.compactMap { b in
            guard let mb = measured[b.product] else { return nil }
            return CheckResult.Line(product: b.product, measuredMB: mb,
                                    budgetMB: b.budgetMB)
        }
        return CheckResult(lines: lines)
    }
}

/// One row in `slo-history.jsonl`. Fields default to `nil` when not
/// captured — the daemon-not-running case for `idleMemory`, the
/// pending-U.1 case for `classifierP95`.
public struct ReleaseSLORow: Codable, Sendable, Equatable {
    public let ts: Double
    public let gitSha: String?
    public let version: String?
    public let coldStartMsP95: Double?
    public let idleMemoryMB: Double?
    public let installSizeMB: Double?
    public let classifierP95Ms: Double?
    /// `senkani serve --openai` spawn → listener-ready p95 (V.13e-3).
    /// `nil` on rows written before V.13e-3, or when the endpoint
    /// never reached "listening on" at measure time.
    public let openaiColdStartMsP95: Double?
    /// Per-binary STRIPPED sizes in MB (D5,
    /// slo-install-size-...-2026-05-27), product-name → MB. `nil` on rows
    /// written before D5 (the legacy `installSizeMB` summed total is the
    /// only install figure those rows carry). When present, this is the
    /// authoritative input to the per-binary budget gate.
    public let installSizePerBinaryMB: [String: Double]?

    public init(ts: Double, gitSha: String?, version: String?,
                coldStartMsP95: Double?, idleMemoryMB: Double?,
                installSizeMB: Double?, classifierP95Ms: Double?,
                openaiColdStartMsP95: Double? = nil,
                installSizePerBinaryMB: [String: Double]? = nil) {
        self.ts = ts
        self.gitSha = gitSha
        self.version = version
        self.coldStartMsP95 = coldStartMsP95
        self.idleMemoryMB = idleMemoryMB
        self.installSizeMB = installSizeMB
        self.classifierP95Ms = classifierP95Ms
        self.openaiColdStartMsP95 = openaiColdStartMsP95
        self.installSizePerBinaryMB = installSizePerBinaryMB
    }

    enum CodingKeys: String, CodingKey {
        case ts
        case gitSha                 = "git_sha"
        case version
        case coldStartMsP95         = "cold_start_ms_p95"
        case idleMemoryMB           = "idle_memory_mb"
        case installSizeMB          = "install_size_mb"
        case classifierP95Ms        = "classifier_p95_ms"
        case openaiColdStartMsP95   = "openai_cold_start_ms_p95"
        case installSizePerBinaryMB = "install_size_per_binary_mb"
    }

    public func value(for slo: ReleaseSLOName) -> Double? {
        switch slo {
        case .coldStart:       return coldStartMsP95
        case .idleMemory:      return idleMemoryMB
        case .installSize:     return installSizeMB
        case .classifierP95:   return classifierP95Ms
        case .openaiColdStart: return openaiColdStartMsP95
        }
    }
}

public enum ReleaseSLOVerdict: String, Sendable {
    case ok          // measured, within threshold, not regressing
    case overBudget  // measured, exceeds the published threshold
    case regression  // measured, ≥10% over median-of-5 baseline
    case missing     // not measured this run (slot is null)
    case noHistory   // no JSONL yet
}

public struct ReleaseSLOEvaluation: Sendable {
    public let slo: ReleaseSLOName
    public let verdict: ReleaseSLOVerdict
    /// Latest captured value. `nil` when `verdict == .missing` or
    /// `.noHistory`.
    public let latest: Double?
    /// Median across the last `ReleaseSLOHistory.baselineWindow` rows
    /// that had a non-nil value for this SLO. `nil` when the window
    /// has no measured rows yet.
    public let baseline: Double?
    /// Percent over baseline (positive = regression direction). `nil`
    /// when baseline is `nil`.
    public let percentOverBaseline: Double?
    /// Reason string when slot is missing (e.g. "pending U.1").
    public let missingReason: String?

    public init(slo: ReleaseSLOName, verdict: ReleaseSLOVerdict,
                latest: Double?, baseline: Double?,
                percentOverBaseline: Double?, missingReason: String?) {
        self.slo = slo
        self.verdict = verdict
        self.latest = latest
        self.baseline = baseline
        self.percentOverBaseline = percentOverBaseline
        self.missingReason = missingReason
    }
}

/// Reads + evaluates `~/.senkani/slo-history.jsonl`.
///
/// File format: one `ReleaseSLORow` JSON object per line, append-only.
/// Older rows on top, newer rows on the bottom. Reads are tolerant of
/// blank lines and one bad row in the middle (logged, skipped).
public final class ReleaseSLOHistory: @unchecked Sendable {
    /// Median window for the regression baseline.
    public static let baselineWindow: Int = 5
    /// Regression threshold — a new value ≥ baseline * (1 + this) flags.
    public static let regressionFraction: Double = 0.10

    public static let shared = ReleaseSLOHistory()

    private let path: String

    public init(customPath: String? = nil) {
        self.path = customPath ?? (NSHomeDirectory() + "/.senkani/slo-history.jsonl")
    }

    public var historyPath: String { path }

    public func load() -> [ReleaseSLORow] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        var rows: [ReleaseSLORow] = []
        let decoder = JSONDecoder()
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let lineData = trimmed.data(using: .utf8),
               let row = try? decoder.decode(ReleaseSLORow.self, from: lineData) {
                rows.append(row)
            }
            // Bad row → silently skip. The script writes well-formed
            // rows; manual edits that corrupt one line shouldn't break
            // the doctor surface for the others.
        }
        return rows
    }

    /// Evaluate every SLO against the latest row + median-of-N baseline.
    public func evaluateAll() -> [ReleaseSLOEvaluation] {
        let rows = load()
        return ReleaseSLOName.allCases.map { evaluate($0, rows: rows) }
    }

    public func evaluate(_ slo: ReleaseSLOName, rows: [ReleaseSLORow])
        -> ReleaseSLOEvaluation
    {
        guard let latestRow = rows.last else {
            return ReleaseSLOEvaluation(
                slo: slo, verdict: .noHistory, latest: nil,
                baseline: nil, percentOverBaseline: nil, missingReason: nil)
        }
        guard let latest = latestRow.value(for: slo) else {
            return ReleaseSLOEvaluation(
                slo: slo, verdict: .missing, latest: nil,
                baseline: nil, percentOverBaseline: nil,
                missingReason: missingReason(for: slo))
        }

        // Median-of-N baseline across all rows that captured this SLO,
        // taking the most recent N. Excludes the latest row from the
        // baseline so it actually compares "now" against "history".
        let prior = rows.dropLast().compactMap { $0.value(for: slo) }
        let window = Array(prior.suffix(Self.baselineWindow))
        let baseline = window.isEmpty ? nil : median(window)

        let pct: Double?
        let regressing: Bool
        if let baseline, baseline > 0 {
            pct = (latest - baseline) / baseline * 100.0
            regressing = (pct! / 100.0) >= Self.regressionFraction
        } else {
            pct = nil
            regressing = false
        }

        let verdict: ReleaseSLOVerdict
        if latest > slo.threshold {
            verdict = .overBudget
        } else if regressing {
            verdict = .regression
        } else {
            verdict = .ok
        }

        return ReleaseSLOEvaluation(
            slo: slo, verdict: verdict, latest: latest,
            baseline: baseline, percentOverBaseline: pct,
            missingReason: nil)
    }

    /// Per-binary install-budget verdict for the LATEST row, or `nil`
    /// when the latest row carries no per-binary breakdown (pre-D5 rows,
    /// or a run where install size wasn't measured). The per-binary map
    /// is the authoritative install gate; the legacy summed
    /// `install_size_mb` total only feeds the doctor surface + regression
    /// baseline.
    public func latestInstallBudgetCheck() -> ReleaseSLOInstallBudget.CheckResult? {
        guard let measured = load().last?.installSizePerBinaryMB,
              !measured.isEmpty else { return nil }
        return ReleaseSLOInstallBudget.check(measured: measured)
    }

    /// Whether the gate should fail the build given the current history.
    /// `true` when ANY scalar SLO is `.overBudget` or `.regression`, OR
    /// when ANY shipped binary in the latest row exceeds its per-binary
    /// install budget (D5). `.missing` and `.noHistory` never fail the
    /// gate — fresh checkouts shouldn't break.
    public func shouldFailGate() -> Bool {
        let scalarFails = evaluateAll().contains { e in
            e.verdict == .overBudget || e.verdict == .regression
        }
        let perBinaryFails = latestInstallBudgetCheck()?.anyOverBudget ?? false
        return scalarFails || perBinaryFails
    }

    private func missingReason(for slo: ReleaseSLOName) -> String {
        switch slo {
        case .classifierP95:   return "pending U.1 TierScorer"
        case .idleMemory:      return "daemon not running at measure time"
        case .openaiColdStart: return "endpoint not reached at measure time"
        default:               return "not captured this run"
        }
    }

    private func median(_ xs: [Double]) -> Double {
        let sorted = xs.sorted()
        let n = sorted.count
        if n == 0 { return 0 }
        if n % 2 == 1 { return sorted[n / 2] }
        return (sorted[n/2 - 1] + sorted[n/2]) / 2.0
    }
}
