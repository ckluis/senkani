import Filter
import Foundation

/// Orchestrates the filter engine, secret detection, and metrics collection.
public struct FilterPipeline: Sendable {
    let engine: FilterEngine
    let config: FeatureConfig
    let layer3: Layer3Inference
    /// Resolves the `pii-classifier-int8` model status. Production
    /// reads from `ModelManager.shared`; tests inject a constant
    /// closure so they don't mutate global state.
    let layer3StatusProvider: @Sendable () -> ModelStatus?

    public init(
        rules: [FilterRule]? = nil,
        config: FeatureConfig = FeatureConfig(),
        layer3: Layer3Inference = .productionDefault,
        layer3StatusProvider: @escaping @Sendable () -> ModelStatus? = {
            ModelManager.shared.models
                .first(where: { $0.id == PIIClassifierAdapter.modelId })?
                .status
        }
    ) {
        let baseRules = rules ?? BuiltinRules.rules
        let learned = LearnedRulesStore.loadApplied().map(\.asFilterRule)
        self.engine = FilterEngine(rules: baseRules + learned)
        self.config = config
        self.layer3 = layer3
        self.layer3StatusProvider = layer3StatusProvider
    }

    /// Run the full pipeline: filter + secret detection.
    /// Returns filtered output and per-feature metrics.
    /// `paneMode` controls the Layer 3 PIIClassifier softmax floor —
    /// `.redteam` lowers the threshold (T.2c-2); other panes keep the
    /// production default. Non-test callers omit it (defaults to
    /// `.default`/`.general`).
    public func process(
        command: String,
        output: String,
        paneMode: PaneMode = .default
    ) -> PipelineResult {
        let sloStart = Date()
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

        // Stage 2: SecretDetector + EntropyScanner + (Layer 3) PIIClassifier
        if config.isEnabled(.secrets) {
            let beforeBytes = currentOutput.utf8.count

            // Layer 1 — Named-pattern detection (Anthropic, OpenAI, AWS, GitHub, bearer, generic)
            let namedDetection = SecretDetector.scan(currentOutput)
            currentOutput = namedDetection.redacted
            secretsFound = namedDetection.patterns

            // Layer 2 — Entropy detection (unnamed high-entropy secrets).
            // SecretDetector never emits "HIGH_ENTROPY", so secretsFound += is safe.
            let entropyDetection = EntropyScanner.scan(currentOutput)
            currentOutput = entropyDetection.redacted
            secretsFound += entropyDetection.patterns

            // Layer 3 — PII classifier (T.2b-1). Calls
            // `PIIClassifierAdapter.shared.forward` + `BIOESDecoder.decode`
            // through the injected `layer3` seam ONLY when the
            // `pii-classifier-int8` model status is `.verified`.
            // Non-verified status no-ops with a one-time `.info` log per
            // process boot. A `.verified` model whose adapter throws
            // `BackendNotReadyError` (the dev-machine state until
            // T.2a-followup wires the inference backend) also no-ops
            // gracefully with a one-time `.info` log under a separate
            // latch state. Regex+entropy spans always ship.
            let status = layer3StatusProvider()
            if status == .verified {
                do {
                    let spans = try layer3.detectSpans(currentOutput, paneMode.piiSensitivityThreshold)
                    if !spans.isEmpty {
                        let redaction = PIISpanRedactor.apply(spans: spans, to: currentOutput)
                        currentOutput = redaction.redacted
                        secretsFound += redaction.patterns
                    }
                    if Layer3GateState.shared.shouldEmit(.active) {
                        Logger.log("layer3.classifier.active", fields: [
                            "model_id": .string(PIIClassifierAdapter.modelId),
                        ])
                    }
                } catch is PIIClassifierAdapter.BackendNotReadyError {
                    if Layer3GateState.shared.shouldEmit(.backendNotReady) {
                        Logger.log("layer3.classifier.backend_not_ready", fields: [
                            "model_id": .string(PIIClassifierAdapter.modelId),
                            "note": .string("regex+entropy active; T.2a-followup not yet wired"),
                        ])
                    }
                } catch {
                    if Layer3GateState.shared.shouldEmit(.unexpectedError) {
                        Logger.log("layer3.classifier.unexpected_error", fields: [
                            "model_id": .string(PIIClassifierAdapter.modelId),
                            "error": .string(String(describing: error)),
                        ])
                    }
                }
            } else {
                if Layer3GateState.shared.shouldEmit(.notPulled) {
                    Logger.log("layer3.classifier.not_pulled", fields: [
                        "model_id": .string(PIIClassifierAdapter.modelId),
                        "status": .string(status?.rawValue ?? "unregistered"),
                    ])
                }
            }

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
        let elapsedMs = Date().timeIntervalSince(sloStart) * 1000
        SLOSampleStore.shared.record(.pipelineMiss, ms: elapsedMs)
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

// MARK: - Layer 3 (PII classifier) seam — T.2b-1

/// Sync seam used by `FilterPipeline.process` to dispatch into the
/// PII classifier (Layer 3). Production default bridges to
/// `PIIClassifierAdapter.shared` and throws `BackendNotReadyError`
/// until T.2a-followup wires `forward` + tokenize + decode. Tests
/// inject a synchronous closure for the contextual-PII path.
public struct Layer3Inference: Sendable {
    /// `threshold` is the per-pane PIIClassifier softmax floor — seam
    /// implementations decide which spans clear the floor (T.2c-2).
    public typealias DetectSpans = @Sendable (_ text: String, _ threshold: Double) throws -> [PIISpan]

    public let detectSpans: DetectSpans

    public init(detectSpans: @escaping DetectSpans) {
        self.detectSpans = detectSpans
    }

    /// Production default: the adapter's backend is not wired yet, so
    /// every call throws `BackendNotReadyError(stage: "inference")`.
    /// T.2a-followup replaces this default with a tokenize → forward →
    /// decode bridge backed by `MLXInferenceLock.shared`.
    public static let productionDefault = Layer3Inference { _, _ in
        throw PIIClassifierAdapter.BackendNotReadyError(stage: "inference")
    }
}

/// Per-process emit-once latch for the three Layer 3 info-log states.
/// Each state logs at most once per process boot so the operator sees
/// the gating without log flooding. Tests reset via `_resetForTests()`.
public final class Layer3GateState: @unchecked Sendable {
    public enum LogState: Hashable, Sendable {
        case notPulled
        case backendNotReady
        case active
        case unexpectedError
    }

    /// Process-wide singleton. FilterPipeline.process consults this.
    public static let shared = Layer3GateState()

    private let lock = NSLock()
    private var emitted: Set<LogState> = []

    public init() {}

    /// Returns true the FIRST time a given state is observed in this
    /// process, false on every subsequent call for the same state.
    public func shouldEmit(_ state: LogState) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if emitted.contains(state) { return false }
        emitted.insert(state)
        return true
    }

    /// Test seam — drops the emitted set so the next call re-emits.
    /// Call from test `setUp` / per-test prelude when validating the
    /// once-per-process semantics; never call from production code.
    public func _resetForTests() {
        lock.lock(); defer { lock.unlock() }
        emitted.removeAll()
    }
}

/// Apply `PIISpan` redactions to a piece of text. Spans use char
/// offsets into the *current* string (Layer 3 runs on the post-regex,
/// post-entropy text). Overlapping or out-of-range spans are skipped
/// defensively — the decoder upstream guarantees ordered, non-overlapping
/// emissions, but pipeline composition can re-arrange offsets, so the
/// redactor is conservative.
public enum PIISpanRedactor {
    public struct Result: Sendable, Equatable {
        public let redacted: String
        /// One pattern marker per redacted span, formatted as
        /// `PII_<CATEGORY>` (matches the `secretsFound` convention).
        public let patterns: [String]
    }

    public static func apply(spans: [PIISpan], to text: String) -> Result {
        guard !spans.isEmpty else { return Result(redacted: text, patterns: []) }

        // Sort by charStart so we process left-to-right.
        let sorted = spans.sorted { $0.charStart < $1.charStart }
        var out = ""
        var patterns: [String] = []
        var cursor = text.startIndex
        let end = text.endIndex
        var prevEndOffset = 0

        for span in sorted {
            guard span.charEnd > span.charStart else { continue }
            guard span.charStart >= prevEndOffset else { continue } // skip overlap
            guard let lo = text.index(text.startIndex, offsetBy: span.charStart, limitedBy: end),
                  let hi = text.index(text.startIndex, offsetBy: span.charEnd, limitedBy: end) else {
                continue
            }
            // Append everything from cursor up to span start.
            out.append(contentsOf: text[cursor..<lo])
            let pattern = "PII_" + span.category.rawValue.uppercased()
            out.append("[REDACTED:\(pattern)]")
            patterns.append(pattern)
            cursor = hi
            prevEndOffset = span.charEnd
        }
        out.append(contentsOf: text[cursor..<end])
        return Result(redacted: out, patterns: patterns)
    }
}
