import Foundation

/// Outcome of one PIIClassifier eval-harness invocation. Either the
/// run was skipped (dataset not pulled, backend not ready, etc.) or
/// it completed with an F1 band verdict.
public enum PIIClassifierEvalOutcome: Equatable, Sendable {
    case skipped(reason: String)
    case completed(f1: Double, status: F1Status)
}

/// PII-Masking-300k eval harness (T.2b-2). Reads dataset status,
/// runs inference per fixture, computes precision/recall/F1 against
/// labeled spans, writes one `eval_results` row, and returns the
/// band verdict. Today the inference step is gated behind
/// T.2a-followup (`phase-t2-pii-classifier-backend-wiring`) — until
/// that round ships the harness short-circuits on
/// `BackendNotReadyError` and returns `.skipped`. The threshold
/// logic + writer + warning buffer surface (the contracts T.2b-2
/// owns) are exercised via the `runWithCachedF1(_:)` injection
/// path, which mocks the inference + scoring step.
///
/// Cavoukian P0: the conditional-skip path keeps `swift test`
/// runnable on dev machines without forcing the multi-GB dataset
/// pull. CI configures the pull explicitly via the operator-
/// runnable T.2a-followup test plan.
public struct PIIClassifierEvalHarness: Sendable {

    /// Senkani model id for the dataset model. Lives in `ModelManager`
    /// and gates the conditional-skip path.
    public static let datasetModelId = "pii-masking-300k-eval"

    /// Senkani model id for the classifier whose F1 the harness
    /// scores. Eval_results rows use this id so doctor's
    /// "last eval" line resolves correctly.
    public static let classifierModelId = "pii-classifier-int8"

    /// Resolves the dataset model's status. Production reads from
    /// `ModelManager.shared`; tests inject a constant.
    public let datasetStatusProvider: @Sendable () -> ModelStatus?

    /// Resolves the classifier model's status. Used to decide whether
    /// inference is even attempted (the Layer 3 gate). Production
    /// reads from `ModelManager.shared`; tests inject a constant.
    public let classifierStatusProvider: @Sendable () -> ModelStatus?

    /// Layer 3 inference seam — same shape as the FilterPipeline
    /// uses. Production default throws `BackendNotReadyError` until
    /// T.2a-followup wires inference.
    public let layer3: Layer3Inference

    /// Sink for the chained eval result. Production passes the
    /// SessionDatabase facade; tests inject a fake closure.
    public let resultsSink: @Sendable (_ fixtureId: String,
                                       _ precision: Double,
                                       _ recall: Double,
                                       _ f1: Double,
                                       _ durationMs: Int64) -> Void

    /// Warn-band buffer. Production writes to `MLWarningBuffer.shared`;
    /// tests inject a fresh buffer at a temp path.
    public let warningBuffer: MLWarningBuffer

    public init(
        datasetStatusProvider: @escaping @Sendable () -> ModelStatus? = {
            ModelManager.shared.models
                .first(where: { $0.id == PIIClassifierEvalHarness.datasetModelId })?
                .status
        },
        classifierStatusProvider: @escaping @Sendable () -> ModelStatus? = {
            ModelManager.shared.models
                .first(where: { $0.id == PIIClassifierEvalHarness.classifierModelId })?
                .status
        },
        layer3: Layer3Inference = .productionDefault,
        resultsSink: @escaping @Sendable (String, Double, Double, Double, Int64) -> Void = { fixtureId, p, r, f1, dur in
            SessionDatabase.shared.recordEvalResult(
                modelId: PIIClassifierEvalHarness.classifierModelId,
                fixtureId: fixtureId,
                precision: p,
                recall: r,
                f1: f1,
                durationMs: dur
            )
        },
        warningBuffer: MLWarningBuffer = .shared
    ) {
        self.datasetStatusProvider = datasetStatusProvider
        self.classifierStatusProvider = classifierStatusProvider
        self.layer3 = layer3
        self.resultsSink = resultsSink
        self.warningBuffer = warningBuffer
    }

    /// Top-level harness motion. Today this is the conditional-skip
    /// shell: when the dataset model isn't `.verified`, the run is
    /// skipped immediately. When the classifier model isn't `.verified`,
    /// also skip — there's nothing to score. When both are `.verified`
    /// but the inference seam throws `BackendNotReadyError`, the run
    /// is skipped with that reason. Real per-fixture inference +
    /// scoring lands in T.2a-followup (once `forward(_:)` returns
    /// `[T, 33]` logits) and replaces this body's "BackendNotReadyError
    /// catch" with a fixture loop.
    public func runOrSkip(fixtureId: String = "smoke-probe") -> PIIClassifierEvalOutcome {
        guard let datasetStatus = datasetStatusProvider() else {
            return .skipped(reason: "dataset model '\(Self.datasetModelId)' not registered")
        }
        guard datasetStatus == .verified else {
            return .skipped(reason: "dataset not pulled (status: \(datasetStatus.rawValue))")
        }
        guard let classifierStatus = classifierStatusProvider() else {
            return .skipped(reason: "classifier model '\(Self.classifierModelId)' not registered")
        }
        guard classifierStatus == .verified else {
            return .skipped(reason: "classifier not pulled (status: \(classifierStatus.rawValue))")
        }
        // Smoke-probe the inference path. Until T.2a-followup wires
        // forward + tokenize + decode, this throws BackendNotReadyError
        // every time and the harness returns .skipped.
        do {
            _ = try layer3.detectSpans("ping")
        } catch is PIIClassifierAdapter.BackendNotReadyError {
            return .skipped(reason: "classifier backend not ready (T.2a-followup not yet wired)")
        } catch {
            return .skipped(reason: "classifier inference probe failed: \(error)")
        }
        // T.2a-followup lands here: walk PII-Masking-300k fixtures,
        // compute precision/recall/F1, sink one row, apply gate.
        // For now we declare unreachable — the round's gate logic is
        // exercised via runWithCachedF1.
        return .skipped(reason: "harness fixture-loop lands in T.2a-followup")
    }

    /// Test-friendly path that bypasses inference and runs the
    /// gate over a cached / mocked F1 score. This is the entry
    /// point T.2b-2's unit tests exercise to verify the warn-band
    /// write, the abort-band assertion, and the clean-band silence.
    /// Also written by the eventual real harness once the per-
    /// fixture loop computes the aggregate F1.
    ///
    /// Side effects (in order):
    /// 1. Sinks one `eval_results` row with the cached F1 + a
    ///    timestamp derived from `Date()`.
    /// 2. On `.warn` / `.abort`, appends a `MLWarningBuffer.Entry`.
    @discardableResult
    public func runWithCachedF1(
        fixtureId: String,
        precision: Double,
        recall: Double,
        f1: Double,
        durationMs: Int64 = 0
    ) -> PIIClassifierEvalOutcome {
        resultsSink(fixtureId, precision, recall, f1, durationMs)
        let status = PIIClassifierEvalGate.f1Status(f1)
        if let warningLine = PIIClassifierEvalGate.changelogWarningLine(
            modelId: Self.classifierModelId,
            status: status
        ) {
            // Best-effort warning persistence — a filesystem failure
            // here MUST NOT crash the harness or the test.
            try? warningBuffer.append(MLWarningBuffer.Entry(
                timestamp: Date(),
                modelId: Self.classifierModelId,
                f1: f1,
                message: warningLine
            ))
        }
        return .completed(f1: f1, status: status)
    }
}
