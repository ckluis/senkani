import Filter

/// Orchestrates the filter engine, secret detection, and metrics collection.
public struct FilterPipeline: Sendable {
    let engine: FilterEngine
    let config: FeatureConfig

    public init(rules: [FilterRule]? = nil, config: FeatureConfig = FeatureConfig()) {
        self.engine = FilterEngine(rules: rules ?? BuiltinRules.rules)
        self.config = config
    }

    /// Run the full pipeline: filter + secret detection.
    /// Returns filtered output and per-feature metrics.
    public func process(command: String, output: String) -> PipelineResult {
        let rawBytes = output.utf8.count
        var currentOutput = output
        var breakdown: [FeatureContribution] = []
        var secretsFound: [String] = []

        // Stage 1: FilterEngine
        if config.isEnabled(.filter) {
            let filterResult = engine.filter(command: command, output: currentOutput)
            let afterBytes = filterResult.output.utf8.count
            breakdown.append(FeatureContribution(
                feature: .filter,
                inputBytes: rawBytes,
                outputBytes: afterBytes
            ))
            currentOutput = filterResult.output
        }

        // Stage 2: SecretDetector
        if config.isEnabled(.secrets) {
            let beforeBytes = currentOutput.utf8.count
            let detection = SecretDetector.scan(currentOutput)
            let afterBytes = detection.redacted.utf8.count
            breakdown.append(FeatureContribution(
                feature: .secrets,
                inputBytes: beforeBytes,
                outputBytes: afterBytes
            ))
            currentOutput = detection.redacted
            secretsFound = detection.patterns
        }

        let filteredBytes = currentOutput.utf8.count
        return PipelineResult(
            output: currentOutput,
            wasFiltered: filteredBytes != rawBytes || !secretsFound.isEmpty,
            rawBytes: rawBytes,
            filteredBytes: filteredBytes,
            command: command,
            secretsFound: secretsFound,
            featureBreakdown: breakdown
        )
    }
}

public struct PipelineResult: Sendable {
    public let output: String
    public let wasFiltered: Bool
    public let rawBytes: Int
    public let filteredBytes: Int
    public let command: String
    public let secretsFound: [String]
    public let featureBreakdown: [FeatureContribution]

    public var savedBytes: Int { rawBytes - filteredBytes }
    public var savingsPercent: Double {
        guard rawBytes > 0 else { return 0 }
        return Double(savedBytes) / Double(rawBytes) * 100
    }
}
