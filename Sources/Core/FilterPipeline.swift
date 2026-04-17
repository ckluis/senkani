import Filter

/// Orchestrates the filter engine, secret detection, and metrics collection.
public struct FilterPipeline: Sendable {
    let engine: FilterEngine
    let config: FeatureConfig

    public init(rules: [FilterRule]? = nil, config: FeatureConfig = FeatureConfig()) {
        let baseRules = rules ?? BuiltinRules.rules
        let learned = LearnedRulesStore.loadApplied().map(\.asFilterRule)
        self.engine = FilterEngine(rules: baseRules + learned)
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

        // Stage 2: SecretDetector + EntropyScanner
        if config.isEnabled(.secrets) {
            let beforeBytes = currentOutput.utf8.count

            // Named-pattern detection (Anthropic, OpenAI, AWS, GitHub, bearer, generic)
            let namedDetection = SecretDetector.scan(currentOutput)
            currentOutput = namedDetection.redacted
            secretsFound = namedDetection.patterns

            // Entropy detection — unnamed high-entropy secrets (base64/hex blobs, random keys).
            // SecretDetector never emits "HIGH_ENTROPY", so secretsFound += is safe.
            let entropyDetection = EntropyScanner.scan(currentOutput)
            currentOutput = entropyDetection.redacted
            secretsFound += entropyDetection.patterns

            let afterBytes = currentOutput.utf8.count
            breakdown.append(FeatureContribution(
                feature: .secrets,
                inputBytes: beforeBytes,
                outputBytes: afterBytes
            ))
        }

        // Stage 3: TerseCompressor
        if config.isEnabled(.terse) {
            let beforeBytes = currentOutput.utf8.count
            currentOutput = TerseCompressor.compress(currentOutput)
            let afterBytes = currentOutput.utf8.count
            breakdown.append(FeatureContribution(
                feature: .terse,
                inputBytes: beforeBytes,
                outputBytes: afterBytes
            ))
        }

        // Stage 4: InjectionGuard
        var injectionsFound: [String] = []
        if config.isEnabled(.injectionGuard) {
            let beforeBytes = currentOutput.utf8.count
            let detection = InjectionGuard.scan(currentOutput)
            let afterBytes = detection.sanitized.utf8.count
            breakdown.append(FeatureContribution(
                feature: .injectionGuard,
                inputBytes: beforeBytes,
                outputBytes: afterBytes
            ))
            currentOutput = detection.sanitized
            injectionsFound = detection.detections
            // Observability: count each triggered detection so the
            // Gelman FP-rate analysis has a denominator.
            if !injectionsFound.isEmpty {
                SessionDatabase.shared.recordEvent(
                    type: "security.injection.detected",
                    delta: injectionsFound.count
                )
            }
        }

        let filteredBytes = currentOutput.utf8.count
        return PipelineResult(
            output: currentOutput,
            wasFiltered: filteredBytes != rawBytes || !secretsFound.isEmpty || !injectionsFound.isEmpty,
            rawBytes: rawBytes,
            filteredBytes: filteredBytes,
            command: command,
            secretsFound: secretsFound,
            injectionsFound: injectionsFound,
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
    public let injectionsFound: [String]
    public let featureBreakdown: [FeatureContribution]

    public var savedBytes: Int { rawBytes - filteredBytes }
    public var savingsPercent: Double {
        guard rawBytes > 0 else { return 0 }
        return Double(savedBytes) / Double(rawBytes) * 100
    }
}
