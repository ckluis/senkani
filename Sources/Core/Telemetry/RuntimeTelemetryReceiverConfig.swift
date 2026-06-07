import Foundation

/// V.18a-3 — persisted config for the local OTLP receiver. Stores the
/// kernel-assigned port from first-bind so subsequent launches re-use
/// the same loopback endpoint, plus a snapshot of the cumulative
/// drop counter so `senkani doctor` can surface it without owning a
/// live connection to the running receiver.
///
/// Loopback bind is performative — any local user / local process
/// can bind a competing receiver on a different loopback port. See
/// `spec/architecture.md#runtime-telemetry-receiver-trust-boundary`.
public struct RuntimeTelemetryReceiverConfig: Sendable, Equatable, Codable {
    /// Port the receiver last bound. 0 = pick at next start.
    public var port: Int
    /// Cumulative drop count (rate-cap overflows) snapshotted by the
    /// receiver at last shutdown / periodic flush.
    public var totalDrops: Int
    /// Per-source rate cap (spans/s). Defaults to 1000 per the V.18a-3
    /// acceptance bullet. Persisted so an operator override survives
    /// restart.
    public var perSourceSpansPerSecond: Int

    public init(port: Int = 0, totalDrops: Int = 0, perSourceSpansPerSecond: Int = 1000) {
        self.port = port
        self.totalDrops = totalDrops
        self.perSourceSpansPerSecond = perSourceSpansPerSecond
    }
}

public enum RuntimeTelemetryReceiverConfigPath {
    /// Canonical path. Honors `SENKANI_HOME` env override for tests;
    /// defaults to `~/.senkani/runtime-telemetry-receiver.json`.
    public static func canonical() -> String {
        if let home = ProcessInfo.processInfo.environment["SENKANI_HOME"], !home.isEmpty {
            return "\(home)/runtime-telemetry-receiver.json"
        }
        return NSString(string: "~/.senkani/runtime-telemetry-receiver.json").expandingTildeInPath
    }
}

/// V.18b-1 — resolves the local OTLP/HTTP endpoint URL pane subprocesses
/// should target when the dev-server allowlist matches. Reads the same
/// on-disk config the receiver persists at first-bind, so a restarted
/// receiver keeps the same port and existing panes keep working without
/// app restart.
public enum RuntimeTelemetryEndpoint {
    /// Returns `http://127.0.0.1:<port>` when the receiver has a bound
    /// port persisted; nil when the config is missing, unreadable, or
    /// the persisted port is zero (receiver hasn't bound yet).
    ///
    /// The path argument exists so unit tests can point at a fixture
    /// config instead of the operator's `~/.senkani/`.
    public static func localLoopback(path: String = RuntimeTelemetryReceiverConfigPath.canonical()) -> String? {
        guard let cfg = try? RuntimeTelemetryReceiverConfigStore.load(path: path) else { return nil }
        guard cfg.port > 0 else { return nil }
        return "http://127.0.0.1:\(cfg.port)"
    }
}

public enum RuntimeTelemetryReceiverConfigStore {
    /// Read on-disk config. Returns defaults (port=0, drops=0) on
    /// missing file. Throws on corrupt JSON.
    public static func load(path: String = RuntimeTelemetryReceiverConfigPath.canonical()) throws -> RuntimeTelemetryReceiverConfig {
        let dict = try SettingsIO.readJSONOrEmpty(at: path)
        var cfg = RuntimeTelemetryReceiverConfig()
        if let p = dict["port"] as? Int { cfg.port = p }
        if let d = dict["total_drops"] as? Int { cfg.totalDrops = d }
        if let r = dict["per_source_spans_per_second"] as? Int { cfg.perSourceSpansPerSecond = r }
        return cfg
    }

    /// Atomic write via `SettingsIO.writeJSONAtomically`. Creates
    /// `~/.senkani/` if needed; emits a `.bak` on first write.
    public static func save(_ config: RuntimeTelemetryReceiverConfig, path: String = RuntimeTelemetryReceiverConfigPath.canonical()) throws {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        SettingsIO.backupIfFirstWrite(path: path)
        let dict: [String: Any] = [
            "port": config.port,
            "total_drops": config.totalDrops,
            "per_source_spans_per_second": config.perSourceSpansPerSecond,
        ]
        try SettingsIO.writeJSONAtomically(dict, to: path)
    }
}
