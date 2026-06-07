import Foundation

/// U.4b-1 — operator-set trust-gate settings persisted to
/// `~/.senkani/trust.json`. Holds the `FragmentationDetector.Mode`
/// choice plus the two gate knobs (`fp_rate_max`, `min_labeled_sample`)
/// the `set-mode blocking` flow checks.
///
/// Per the operator scope-groom Q4 verdict (no defaults), the file
/// is missing-on-fresh-install and `fpRateMax` / `minLabeledSample`
/// stay nil until the operator runs `senkani trust threshold …`.
/// `mode` defaults to `.softFlag` so the detector is non-blocking
/// on a fresh install — matches U.4a posture.
public struct TrustSettings: Sendable, Equatable {
    public var mode: TrustMode
    /// Maximum FP-rate the operator is willing to tolerate before
    /// `set-mode blocking` is accepted. 0.0–1.0. nil = unset.
    public var fpRateMax: Double?
    /// Minimum labeled-sample count over the prior 30 days. nil = unset.
    public var minLabeledSample: Int?

    public init(mode: TrustMode = .softFlag, fpRateMax: Double? = nil, minLabeledSample: Int? = nil) {
        self.mode = mode
        self.fpRateMax = fpRateMax
        self.minLabeledSample = minLabeledSample
    }
}

/// `FragmentationDetector` operating mode. U.4a shipped `.softFlag`
/// posture; U.4b-1 adds `.blocking` as an operator-flippable mode
/// behind the promotion gate. Persisted by rawValue — renaming a case
/// is a schema break (lives in `~/.senkani/trust.json`).
public enum TrustMode: String, Sendable, Codable, Equatable, CaseIterable {
    case softFlag = "softFlag"
    case blocking = "blocking"
}

/// Default path under `$HOME/.senkani/`. Resolved lazily so tests can
/// inject an alternate root via `URLSession`-style overrides.
public enum TrustSettingsPath {
    /// Resolve the canonical path. Honors `SENKANI_HOME` env override
    /// for tests; defaults to `~/.senkani/trust.json` in production.
    public static func canonical() -> String {
        if let home = ProcessInfo.processInfo.environment["SENKANI_HOME"], !home.isEmpty {
            return "\(home)/trust.json"
        }
        let home = NSString(string: "~/.senkani/trust.json").expandingTildeInPath
        return home
    }
}

/// Load + save for `TrustSettings`. Wraps `SettingsIO` with the
/// rawValue translation for `TrustMode` so the JSON file shape stays
/// human-readable.
public enum TrustSettingsStore {
    /// Read the on-disk settings. Returns defaults (mode=.softFlag,
    /// fpRateMax=nil, minLabeledSample=nil) when the file is missing.
    /// Throws when the file exists but contains corrupt JSON — never
    /// silently overrides operator-set values.
    public static func load(path: String = TrustSettingsPath.canonical()) throws -> TrustSettings {
        let dict = try SettingsIO.readJSONOrEmpty(at: path)
        var settings = TrustSettings()
        if let modeStr = dict["mode"] as? String, let parsed = TrustMode(rawValue: modeStr) {
            settings.mode = parsed
        }
        if let rate = dict["fp_rate_max"] as? Double {
            settings.fpRateMax = rate
        } else if let rateInt = dict["fp_rate_max"] as? Int {
            settings.fpRateMax = Double(rateInt)
        }
        if let n = dict["min_labeled_sample"] as? Int {
            settings.minLabeledSample = n
        }
        return settings
    }

    /// Atomic write. Ensures `~/.senkani/` exists; emits a `.bak`
    /// backup on the first write per the SettingsIO convention.
    public static func save(_ settings: TrustSettings, path: String = TrustSettingsPath.canonical()) throws {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        SettingsIO.backupIfFirstWrite(path: path)
        var dict: [String: Any] = [
            "mode": settings.mode.rawValue,
        ]
        if let rate = settings.fpRateMax { dict["fp_rate_max"] = rate }
        if let n = settings.minLabeledSample { dict["min_labeled_sample"] = n }
        try SettingsIO.writeJSONAtomically(dict, to: path)
    }
}
