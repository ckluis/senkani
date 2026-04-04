import Foundation

/// Features that can be independently toggled.
public enum Feature: String, Codable, Sendable, CaseIterable {
    case filter   // FilterEngine command rules
    case secrets  // SecretDetector redaction
    case indexer  // Symbol indexer
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

    public init(filter: Bool = true, secrets: Bool = true, indexer: Bool = true) {
        self.filter = filter
        self.secrets = secrets
        self.indexer = indexer
    }

    /// Check if a specific feature is enabled.
    public func isEnabled(_ feature: Feature) -> Bool {
        switch feature {
        case .filter: return filter
        case .secrets: return secrets
        case .indexer: return indexer
        }
    }

    /// Resolve config from environment variables and optional config file.
    /// CLI flag overrides are passed in directly.
    public static func resolve(
        filterFlag: Bool? = nil,
        secretsFlag: Bool? = nil,
        indexerFlag: Bool? = nil,
        projectRoot: String? = nil
    ) -> FeatureConfig {
        // Layer 1: config file
        let fileConfig = projectRoot.flatMap { loadConfigFile(projectRoot: $0) }

        // Layer 2: env vars
        let envFilter = envBool("SENKANI_FILTER")
        let envSecrets = envBool("SENKANI_SECRETS")
        let envIndexer = envBool("SENKANI_INDEXER")

        // Resolution: flag > env > file > default(true)
        return FeatureConfig(
            filter: filterFlag ?? envFilter ?? fileConfig?.filter ?? true,
            secrets: secretsFlag ?? envSecrets ?? fileConfig?.secrets ?? true,
            indexer: indexerFlag ?? envIndexer ?? fileConfig?.indexer ?? true
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
        }

        var filter: Bool? { features?.filter }
        var secrets: Bool? { features?.secrets }
        var indexer: Bool? { features?.indexer }
    }
}
