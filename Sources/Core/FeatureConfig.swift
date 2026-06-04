import Foundation

/// Features that can be independently toggled.
public enum Feature: String, Codable, Sendable, CaseIterable {
    case filter         // FilterEngine command rules
    case secrets        // SecretDetector redaction
    case indexer        // Symbol indexer
    case terse          // TerseCompressor word/phrase compression
    case injectionGuard // InjectionGuard prompt attack detection
    case mitmTlsTermination // Egress MITM TLS termination (T.1d-2b; default-ON as of T.1d-5)
}

/// Per-feature byte savings tracking.
public struct FeatureContribution: Codable, Sendable {
    public let feature: Feature
    public let inputBytes: Int
    public let outputBytes: Int

    public var savedBytes: Int { inputBytes - outputBytes }

    public init(feature: Feature, inputBytes: Int, outputBytes: Int) {
        self.feature = feature
        self.inputBytes = inputBytes
        self.outputBytes = outputBytes
    }
}

/// Resolves feature toggle state from CLI flags, env vars, and config file.
/// Resolution order: CLI flag > env var > config file > default (all on).
public struct FeatureConfig: Sendable {
    public let filter: Bool
    public let secrets: Bool
    public let indexer: Bool
    public let terse: Bool
    public let injectionGuard: Bool
    public let mitmTlsTermination: Bool

    // T.1d-5 (2026-06-04) MITM-FLAG FLIP-ON. The `mitmTlsTermination`
    // default for NEW configurations is now `true`. The flip is gated on
    // the 8-scenario adversarial body-inspection corpus shipping green
    // (Allspaw P1 activation-gate: no flip until the body-aware enforcement
    // path is proven). When the flag is ON but no CA pem is on disk,
    // `EgressListener.start()` emits a stderr WARN and
    // `senkani doctor` surfaces a `.fail` line — the listener falls
    // through to the opaque-tunnel path in that environmental case so
    // an operator who has not yet generated a CA is not locked out of
    // egress entirely (see DoctorCommand.checkMITMTerminationReadiness).
    //
    // BACK-COMPAT INVARIANT (Allspaw P1): the SNAPSHOT-side default in
    // `PolicyFeatures.init(from:)` STAYS `false` via
    // `decodeIfPresent(...) ?? false`. Existing `policy_snapshots` rows
    // written before this flag existed lack the key and MUST still
    // decode to `false` so the historical audit record is preserved
    // bit-for-bit. The audit-side default tracks what was ACTUALLY in
    // effect when the snapshot was captured (off, then); only NEW
    // FeatureConfig instances minted post-flip carry the `true`
    // default. Do NOT collapse the two defaults into one — they
    // serve different invariants.
    public init(filter: Bool = true, secrets: Bool = true, indexer: Bool = true, terse: Bool = false, injectionGuard: Bool = true, mitmTlsTermination: Bool = true) {
        self.filter = filter
        self.secrets = secrets
        self.indexer = indexer
        self.terse = terse
        self.injectionGuard = injectionGuard
        self.mitmTlsTermination = mitmTlsTermination
    }

    /// Check if a specific feature is enabled.
    public func isEnabled(_ feature: Feature) -> Bool {
        switch feature {
        case .filter: return filter
        case .secrets: return secrets
        case .indexer: return indexer
        case .terse: return terse
        case .injectionGuard: return injectionGuard
        case .mitmTlsTermination: return mitmTlsTermination
        }
    }

    /// Resolve config from environment variables and optional config file.
    /// CLI flag overrides are passed in directly.
    public static func resolve(
        filterFlag: Bool? = nil,
        secretsFlag: Bool? = nil,
        indexerFlag: Bool? = nil,
        terseFlag: Bool? = nil,
        injectionGuardFlag: Bool? = nil,
        mitmTlsTerminationFlag: Bool? = nil,
        projectRoot: String? = nil
    ) -> FeatureConfig {
        // Layer 1: config file
        let fileConfig = projectRoot.flatMap { loadConfigFile(projectRoot: $0) }

        // Layer 2: env vars
        let envFilter = envBool("SENKANI_FILTER")
        let envSecrets = envBool("SENKANI_SECRETS")
        let envIndexer = envBool("SENKANI_INDEXER")
        let envTerse = envBool("SENKANI_TERSE")
        let envInjection = envBool("SENKANI_INJECTION_GUARD")
        let envMitmTls = envBool("SENKANI_MITM_TLS_TERMINATION")

        // Resolution: flag > env > file > default (terse default off;
        // injectionGuard + mitmTlsTermination default on as of T.1d-5).
        return FeatureConfig(
            filter: filterFlag ?? envFilter ?? fileConfig?.filter ?? true,
            secrets: secretsFlag ?? envSecrets ?? fileConfig?.secrets ?? true,
            indexer: indexerFlag ?? envIndexer ?? fileConfig?.indexer ?? true,
            terse: terseFlag ?? envTerse ?? fileConfig?.terse ?? false,
            injectionGuard: injectionGuardFlag ?? envInjection ?? fileConfig?.injectionGuard ?? true,
            mitmTlsTermination: mitmTlsTerminationFlag ?? envMitmTls ?? fileConfig?.mitmTlsTermination ?? true
        )
    }

    private static func envBool(_ key: String) -> Bool? {
        guard let val = ProcessInfo.processInfo.environment[key]?.lowercased() else { return nil }
        switch val {
        case "true", "on", "1", "yes": return true
        case "false", "off", "0", "no": return false
        default: return nil
        }
    }

    private static func loadConfigFile(projectRoot: String) -> FileConfigData? {
        let path = projectRoot + "/.senkani/config.json"
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(FileConfigData.self, from: data)
    }

    struct FileConfigData: Codable {
        let features: FeatureFlags?

        struct FeatureFlags: Codable {
            let filter: Bool?
            let secrets: Bool?
            let indexer: Bool?
            let terse: Bool?
            let injectionGuard: Bool?
            let mitmTlsTermination: Bool?
        }

        var filter: Bool? { features?.filter }
        var secrets: Bool? { features?.secrets }
        var indexer: Bool? { features?.indexer }
        var terse: Bool? { features?.terse }
        var injectionGuard: Bool? { features?.injectionGuard }
        var mitmTlsTermination: Bool? { features?.mitmTlsTermination }
    }
}
