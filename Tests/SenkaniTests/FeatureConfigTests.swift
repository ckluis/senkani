import Testing
import Foundation
@testable import Core

@Suite("FeatureConfig")
struct FeatureConfigTests {
    @Test func defaultAllEnabled() {
        let config = FeatureConfig()
        #expect(config.isEnabled(.filter))
        #expect(config.isEnabled(.secrets))
        #expect(config.isEnabled(.indexer))
    }

    @Test func disableIndividualFeatures() {
        let config = FeatureConfig(filter: false, secrets: true, indexer: false)
        #expect(!config.isEnabled(.filter))
        #expect(config.isEnabled(.secrets))
        #expect(!config.isEnabled(.indexer))
    }

    @Test func cliFlgOverridesDefault() {
        let config = FeatureConfig.resolve(filterFlag: false)
        #expect(!config.filter)
        #expect(config.secrets) // default
        #expect(config.indexer) // default
    }

    @Test func nilFlagUsesDefault() {
        let config = FeatureConfig.resolve(filterFlag: nil, secretsFlag: nil, indexerFlag: nil)
        #expect(config.filter)
        #expect(config.secrets)
        #expect(config.indexer)
    }

    // Default policy — terse defaults OFF (opt-in), injectionGuard ON.
    // Guards against a regression where someone flipping the constructor
    // default on `terse` silently slows down every session.
    @Test func terseDefaultsOffInjectionGuardDefaultsOn() {
        let config = FeatureConfig()
        #expect(!config.isEnabled(.terse))
        #expect(config.isEnabled(.injectionGuard))
    }

    // CLI flag wins over every other layer. This is the top of the
    // precedence chain (flag > env > file > default) and is the path a
    // human types at the command line — must never be silently overridden.
    @Test func resolveAppliesAllFlagsIndependently() {
        let config = FeatureConfig.resolve(
            filterFlag: false,
            secretsFlag: false,
            indexerFlag: false,
            terseFlag: true,
            injectionGuardFlag: false
        )
        #expect(!config.filter)
        #expect(!config.secrets)
        #expect(!config.indexer)
        #expect(config.terse)
        #expect(!config.injectionGuard)
    }

    // Feature enum is CaseIterable and isEnabled returns a definite
    // answer for every case — prevents a switch-exhaustiveness hole
    // when a new feature case is added without updating `isEnabled`.
    @Test func isEnabledCoversEveryFeatureCase() {
        let config = FeatureConfig()
        for feature in Feature.allCases {
            // Trivial coverage — the key point is the switch compiles
            // exhaustively and returns a Bool for every case.
            _ = config.isEnabled(feature)
        }
        #expect(Feature.allCases.count == 5)
    }

    // FeatureContribution arithmetic: savedBytes is the difference between
    // input and output. Negative values (compression increasing size) are
    // reported as negative — callers aggregate across many contributions
    // so no clamping at this layer.
    @Test func featureContributionSavedBytesArithmetic() {
        let pos = FeatureContribution(feature: .filter, inputBytes: 1000, outputBytes: 200)
        #expect(pos.savedBytes == 800)

        let zero = FeatureContribution(feature: .secrets, inputBytes: 500, outputBytes: 500)
        #expect(zero.savedBytes == 0)

        let neg = FeatureContribution(feature: .terse, inputBytes: 100, outputBytes: 130)
        #expect(neg.savedBytes == -30)
    }

    // Feature enum raw values are the stable keys written to config JSON
    // and DB. Renaming one silently breaks user config files, so pin them.
    @Test func featureRawValuesAreStableContract() {
        #expect(Feature.filter.rawValue == "filter")
        #expect(Feature.secrets.rawValue == "secrets")
        #expect(Feature.indexer.rawValue == "indexer")
        #expect(Feature.terse.rawValue == "terse")
        #expect(Feature.injectionGuard.rawValue == "injectionGuard")
    }

    // Config file precedence: when no flag and no env var is set, the
    // on-disk `.senkani/config.json` wins. Regression guard for the file
    // loader being skipped entirely.
    @Test func configFileOverridesDefault() throws {
        let root = NSTemporaryDirectory() + "senkani-fcfg-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root + "/.senkani", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let body = #"{"features":{"filter":false,"terse":true}}"#
        try body.write(toFile: root + "/.senkani/config.json", atomically: true, encoding: .utf8)

        let config = FeatureConfig.resolve(projectRoot: root)
        #expect(!config.filter, "filter=false from config.json overrides default-on")
        #expect(config.terse, "terse=true from config.json overrides default-off")
        // Unmentioned features fall through to default.
        #expect(config.secrets)
        #expect(config.indexer)
        #expect(config.injectionGuard)
    }

    // Flag beats config file — top of precedence chain stays on top
    // even when the file tries to override.
    @Test func cliFlagBeatsConfigFile() throws {
        let root = NSTemporaryDirectory() + "senkani-fcfg-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root + "/.senkani", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let body = #"{"features":{"filter":false}}"#
        try body.write(toFile: root + "/.senkani/config.json", atomically: true, encoding: .utf8)

        let config = FeatureConfig.resolve(filterFlag: true, projectRoot: root)
        #expect(config.filter, "explicit flag=true must win over config.json false")
    }

    // Malformed config file is treated as absent — we never crash the
    // server because a user hand-edited the JSON and left a stray comma.
    @Test func malformedConfigFileFallsBackToDefaults() throws {
        let root = NSTemporaryDirectory() + "senkani-fcfg-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root + "/.senkani", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        try "not json {".write(toFile: root + "/.senkani/config.json", atomically: true, encoding: .utf8)

        let config = FeatureConfig.resolve(projectRoot: root)
        #expect(config.filter)
        #expect(config.secrets)
        #expect(config.indexer)
        #expect(!config.terse)
        #expect(config.injectionGuard)
    }
}
