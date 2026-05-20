import Foundation

/// U.9a — feature-flag scaffolding for U.9b's dual-write consumer
/// migration. Default `dualWrite: false` in U.9a (substrate exists but
/// no production caller routes through the outbox helper). U.9b
/// flips per project root to run both the old in-process actor AND
/// the new bus side-by-side; U.9c retires the old path once parity is
/// observed.
///
/// Per the operator scope-groom Q4 verdict (feature-flagged dual-
/// write), the flag lives in a small standalone config file at
/// `~/.senkani/work-bus.json` rather than threading through
/// `PolicyConfig` — PolicyConfig is an immutable Hashable snapshot
/// captured per session, and threading an operational mode flag
/// through that surface would force a `policy_hash` rebump on every
/// dual-write change. A standalone `WorkBusConfig` keeps the
/// operational knob orthogonal to the audit snapshot.
public struct WorkBusConfig: Sendable, Equatable {
    /// When `true`, U.9b consumers route writes through the outbox
    /// helper in addition to the legacy in-process path. Default
    /// `false` in U.9a — substrate ships unused.
    public var dualWrite: Bool

    public init(dualWrite: Bool = false) {
        self.dualWrite = dualWrite
    }
}

public enum WorkBusConfigPath {
    /// Resolve the canonical path. Honors `SENKANI_HOME` env override
    /// for tests; defaults to `~/.senkani/work-bus.json` in production.
    public static func canonical() -> String {
        if let home = ProcessInfo.processInfo.environment["SENKANI_HOME"], !home.isEmpty {
            return "\(home)/work-bus.json"
        }
        let home = NSString(string: "~/.senkani/work-bus.json").expandingTildeInPath
        return home
    }
}

public enum WorkBusConfigStore {
    /// Read the on-disk config. Returns `WorkBusConfig()` (dualWrite=false)
    /// when the file is missing — operator-set defaults stay opt-in.
    /// Throws when the file exists but contains corrupt JSON.
    public static func load(path: String = WorkBusConfigPath.canonical()) throws -> WorkBusConfig {
        let dict = try SettingsIO.readJSONOrEmpty(at: path)
        var cfg = WorkBusConfig()
        if let dw = dict["dual_write"] as? Bool {
            cfg.dualWrite = dw
        }
        return cfg
    }

    /// Atomic write via `SettingsIO.writeJSONAtomically`. Ensures
    /// `~/.senkani/` exists; emits a `.bak` backup on first write.
    public static func save(_ config: WorkBusConfig, path: String = WorkBusConfigPath.canonical()) throws {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        SettingsIO.backupIfFirstWrite(path: path)
        let dict: [String: Any] = [
            "dual_write": config.dualWrite,
        ]
        try SettingsIO.writeJSONAtomically(dict, to: path)
    }
}
