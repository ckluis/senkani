import Foundation

// MARK: - CompoundLearningConfig
//
// Phase H+2a: user-overridable thresholds for the compound-learning
// proposal loop. Phase K shipped hardcoded values (`minConfidence=0.60`,
// `dailySweepRecurrenceThreshold=3`, `dailySweepConfidenceThreshold=0.70`)
// marked "frozen pending real-session telemetry" by the Luminary audit.
//
// H+2a lets operators override these values without a rebuild. Real
// threshold recalibration (from distribution data) still waits on real
// sessions — that's the Manual test queue's job. This scaffolding just
// gets the knobs in place so the calibration work is a data update,
// not a code change.
//
// Precedence chain (highest wins):
//   1. Env var  (e.g. `SENKANI_COMPOUND_MIN_CONFIDENCE=0.75`)
//   2. File     (`~/.senkani/compound-learning.json`)
//   3. Code default (the value shipped in Phase K)
//
// CLI flags could layer on top (precedence 0) — `senkani learn` does
// not currently take per-invocation threshold flags, so we skip that
// for this round.

public struct CompoundLearningConfig: Codable, Sendable, Equatable {
    public var minConfidence: Double?
    public var dailySweepRecurrenceThreshold: Int?
    public var dailySweepConfidenceThreshold: Double?

    public init(
        minConfidence: Double? = nil,
        dailySweepRecurrenceThreshold: Int? = nil,
        dailySweepConfidenceThreshold: Double? = nil
    ) {
        self.minConfidence = minConfidence
        self.dailySweepRecurrenceThreshold = dailySweepRecurrenceThreshold
        self.dailySweepConfidenceThreshold = dailySweepConfidenceThreshold
    }

    /// Effective thresholds after resolving env + file + code defaults.
    public struct Effective: Sendable, Equatable {
        public let minConfidence: Double
        public let dailySweepRecurrenceThreshold: Int
        public let dailySweepConfidenceThreshold: Double
    }

    /// Code defaults — kept in sync with Phase K constants.
    public static let codeDefault = Effective(
        minConfidence: 0.60,
        dailySweepRecurrenceThreshold: 3,
        dailySweepConfidenceThreshold: 0.70
    )

    public static let defaultPath: String = NSHomeDirectory() + "/.senkani/compound-learning.json"

    /// Load the file config. Returns an empty config on missing file,
    /// malformed JSON, or read errors — broken user JSON must never
    /// crash the MCP server.
    public static func loadFile(at path: String = defaultPath) -> CompoundLearningConfig {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return CompoundLearningConfig()
        }
        return (try? JSONDecoder().decode(CompoundLearningConfig.self, from: data))
            ?? CompoundLearningConfig()
    }

    /// Persist to disk at `path`, creating the parent dir if needed.
    public static func save(_ config: CompoundLearningConfig, at path: String = defaultPath) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(config)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Resolve the effective thresholds. Test seams: inject
    /// `environment` and `filePath` so call sites don't have to mutate
    /// process-wide state or hit the real `~/.senkani` path.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        filePath: String = defaultPath
    ) -> Effective {
        let file = loadFile(at: filePath)

        let minConf = envDouble("SENKANI_COMPOUND_MIN_CONFIDENCE", in: environment)
            ?? file.minConfidence
            ?? codeDefault.minConfidence

        let recur = envInt("SENKANI_COMPOUND_DAILY_RECURRENCE", in: environment)
            ?? file.dailySweepRecurrenceThreshold
            ?? codeDefault.dailySweepRecurrenceThreshold

        let dailyConf = envDouble("SENKANI_COMPOUND_DAILY_CONFIDENCE", in: environment)
            ?? file.dailySweepConfidenceThreshold
            ?? codeDefault.dailySweepConfidenceThreshold

        return Effective(
            minConfidence: clamp(minConf, 0.0, 1.0),
            dailySweepRecurrenceThreshold: max(1, recur),
            dailySweepConfidenceThreshold: clamp(dailyConf, 0.0, 1.0)
        )
    }

    // MARK: - Env parsing (narrow helpers)

    private static func envDouble(_ key: String, in env: [String: String]) -> Double? {
        guard let raw = env[key], !raw.isEmpty else { return nil }
        return Double(raw)
    }
    private static func envInt(_ key: String, in env: [String: String]) -> Int? {
        guard let raw = env[key], !raw.isEmpty else { return nil }
        return Int(raw)
    }
    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        max(lo, min(hi, v))
    }
}
