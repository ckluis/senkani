import Testing
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
}
