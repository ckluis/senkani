import Foundation

/// SLO module — see `spec/slos.md` for the spec.
///
/// Three contracts on the hot path. Samples persist to
/// `~/.senkani/slo-samples.json` so p99 survives CLI process exits.
/// `senkani doctor` reads the store and surfaces green / warn / burn /
/// unknown for each SLO. The CI perf gate
/// (`Tests/SenkaniTests/SLOPerfGateTests.swift`) synthesizes a
/// workload and asserts p99 stays under threshold.
public enum SLOName: String, Codable, CaseIterable, Sendable {
    case cacheHit        = "cache.hit"
    case pipelineMiss    = "pipeline.miss"
    case hookPassthrough = "hook.passthrough"
    case hookActive      = "hook.active"

    /// p99 ceiling in milliseconds.
    public var thresholdMs: Double {
        switch self {
        case .cacheHit:        return 1.0
        case .pipelineMiss:    return 20.0
        case .hookPassthrough: return 1.0
        case .hookActive:      return 3.0
        }
    }

    /// One-line description for `senkani doctor`.
    public var description: String {
        switch self {
        case .cacheHit:        return "KB/artifact cache lookup hit"
        case .pipelineMiss:    return "FilterPipeline.process fresh"
        case .hookPassthrough: return "Hook binary, intercept off"
        case .hookActive:      return "Hook binary, intercept on"
        }
    }
}

public struct SLOSample: Codable, Sendable, Equatable {
    public let ms: Double
    public let ts: Double  // UNIX epoch seconds

    public init(ms: Double, ts: Double) {
        self.ms = ms
        self.ts = ts
    }
}

/// Verdict surfaced to the user.
public enum SLOState: String, Sendable {
    case green   // p99 ≤ threshold AND ≤1% over budget
    case warn    // p99 in [80%, 100%) of threshold
    case burn    // p99 > threshold OR >1% of samples over threshold
    case unknown // fewer than `minSamples` in window
}

public struct SLOEvaluation: Sendable {
    public let slo: SLOName
    public let state: SLOState
    public let p99Ms: Double
    public let sampleCount: Int
    public let overBudgetPct: Double  // % of samples over threshold (0–100)

    public init(slo: SLOName, state: SLOState, p99Ms: Double, sampleCount: Int, overBudgetPct: Double) {
        self.slo = slo
        self.state = state
        self.p99Ms = p99Ms
        self.sampleCount = sampleCount
        self.overBudgetPct = overBudgetPct
    }
}

/// File-backed bounded ring buffer of latency samples per SLO.
///
/// Concurrency model: the underlying file is overwritten atomically on
/// every `record(...)` via NSLock + `Data.write(options: .atomic)`. The
/// in-process `lock` serialises mutators; the atomic write serialises
/// against other processes (last-writer-wins is acceptable — losing one
/// sample out of a 1k-deep buffer doesn't move p99).
public final class SLOSampleStore: @unchecked Sendable {
    public static let windowSeconds: Double = 24 * 60 * 60   // 24h rolling
    public static let bufferCap: Int = 1000                  // per-SLO cap
    public static let minSamples: Int = 30                   // for non-unknown verdict
    public static let warnFraction: Double = 0.80            // warn at 80% of threshold
    public static let budgetFraction: Double = 0.01          // 1% allowed over threshold

    public static let shared = SLOSampleStore()

    private let lock = NSLock()
    private let path: String

    /// `customPath` is for tests only; production uses `~/.senkani/slo-samples.json`.
    public init(customPath: String? = nil) {
        self.path = customPath ?? (NSHomeDirectory() + "/.senkani/slo-samples.json")
    }

    /// Record a single latency sample. Thread- and process-safe.
    ///
    /// Disabled by default — opt-in by setting `SENKANI_SLO_SAMPLES=1`.
    /// Recording does file I/O on every call (read-modify-write of the
    /// JSON store), and the SLOs measure operations on the order of
    /// 1–20 ms; doing that I/O on every hot-path call would dominate
    /// what we're trying to measure. The perf gate (and any operator
    /// who wants live samples) flips the env var.
    public func record(_ slo: SLOName, ms: Double, now: Date = Date()) {
        guard isEnabled() else { return }
        lock.lock()
        defer { lock.unlock() }
        var store = readUnlocked()
        var samples = store[slo.rawValue] ?? []
        samples.append(SLOSample(ms: ms, ts: now.timeIntervalSince1970))
        if samples.count > Self.bufferCap {
            samples.removeFirst(samples.count - Self.bufferCap)
        }
        store[slo.rawValue] = samples
        writeUnlocked(store)
    }

    /// Force-record bypassing the env-var gate (perf-gate + tests).
    public func recordForced(_ slo: SLOName, ms: Double, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        var store = readUnlocked()
        var samples = store[slo.rawValue] ?? []
        samples.append(SLOSample(ms: ms, ts: now.timeIntervalSince1970))
        if samples.count > Self.bufferCap {
            samples.removeFirst(samples.count - Self.bufferCap)
        }
        store[slo.rawValue] = samples
        writeUnlocked(store)
    }

    private func isEnabled() -> Bool {
        let v = ProcessInfo.processInfo.environment["SENKANI_SLO_SAMPLES"] ?? ""
        return v == "1" || v == "on" || v == "true"
    }

    /// Return all samples for `slo` within the rolling window.
    public func samples(for slo: SLOName, now: Date = Date()) -> [SLOSample] {
        lock.lock()
        defer { lock.unlock() }
        let store = readUnlocked()
        let cutoff = now.timeIntervalSince1970 - Self.windowSeconds
        return (store[slo.rawValue] ?? []).filter { $0.ts >= cutoff }
    }

    /// Drop every sample for every SLO (test affordance).
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Evaluate the current state of an SLO.
    public func evaluate(_ slo: SLOName, now: Date = Date()) -> SLOEvaluation {
        let inWindow = samples(for: slo, now: now)
        if inWindow.count < Self.minSamples {
            return SLOEvaluation(slo: slo, state: .unknown, p99Ms: 0,
                                 sampleCount: inWindow.count, overBudgetPct: 0)
        }
        let p99 = SLO.percentile(inWindow.map(\.ms), 0.99)
        let overCount = inWindow.filter { $0.ms > slo.thresholdMs }.count
        let overPct = Double(overCount) / Double(inWindow.count) * 100.0
        let state: SLOState
        if p99 > slo.thresholdMs || overPct > Self.budgetFraction * 100.0 {
            state = .burn
        } else if p99 >= slo.thresholdMs * Self.warnFraction {
            state = .warn
        } else {
            state = .green
        }
        return SLOEvaluation(slo: slo, state: state, p99Ms: p99,
                             sampleCount: inWindow.count, overBudgetPct: overPct)
    }

    /// Evaluate all four SLOs at once.
    public func evaluateAll(now: Date = Date()) -> [SLOEvaluation] {
        SLOName.allCases.map { evaluate($0, now: now) }
    }

    // MARK: - File I/O (must hold `lock`)

    private func readUnlocked() -> [String: [SLOSample]] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let decoded = try? JSONDecoder().decode([String: [SLOSample]].self, from: data)
        else { return [:] }
        return decoded
    }

    private func writeUnlocked(_ store: [String: [SLOSample]]) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(store) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

/// Math helpers — public so tests + the perf gate can use the same
/// percentile implementation as the doctor.
public enum SLO {

    /// Linear-interpolation p-th percentile (q in [0, 1]). Returns 0
    /// for empty input. Operates on a copy so `samples` need not be
    /// pre-sorted.
    public static func percentile(_ samples: [Double], _ q: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        if sorted.count == 1 { return sorted[0] }
        let qClamped = max(0, min(1, q))
        let idx = qClamped * Double(sorted.count - 1)
        let lo = Int(idx.rounded(.down))
        let hi = Int(idx.rounded(.up))
        if lo == hi { return sorted[lo] }
        let frac = idx - Double(lo)
        return sorted[lo] * (1 - frac) + sorted[hi] * frac
    }
}
