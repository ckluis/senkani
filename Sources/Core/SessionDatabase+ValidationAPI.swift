import Foundation

extension SessionDatabase {
    /// A stored validation result row.
    public struct ValidationResultRow: Sendable {
        public let id: Int64
        public let filePath: String
        public let validatorName: String
        public let category: String
        public let exitCode: Int32
        public let advisory: String
        public let durationMs: Int
        public let createdAt: Date
        public let outcome: String
        public let reason: String?
        public let surfacedAt: Date?
    }

    /// Store a validation result from auto-validate.
    ///
    /// V.18a-5 — optional `validationRunId` tags the row for the
    /// cross-cutting JOIN against `runtime_telemetry_span`.
    public func insertValidationResult(
        sessionId: String,
        filePath: String,
        validatorName: String,
        category: String,
        exitCode: Int32,
        rawOutput: String?,
        advisory: String,
        durationMs: Int,
        outcome: String? = nil,
        reason: String? = nil,
        validationRunId: String? = nil
    ) {
        validationStore.insertValidationResult(
            sessionId: sessionId,
            filePath: filePath,
            validatorName: validatorName,
            category: category,
            exitCode: exitCode,
            rawOutput: rawOutput,
            advisory: advisory,
            durationMs: durationMs,
            outcome: outcome,
            reason: reason,
            validationRunId: validationRunId
        )
    }

    /// U.9c-1 — outbox-atomic validation insert: the canonical
    /// `validation_results` row plus a paired `session_event_stream` row in
    /// ONE transaction. Called by `AutoValidateQueue` ONLY when
    /// `WorkBusConfig.dualWrite` is on; the default path stays on the
    /// fire-and-forget `insertValidationResult` and is byte-identical to
    /// pre-U.9c. Returns `(resultId, streamId)` on success, `nil` on
    /// rollback.
    @discardableResult
    public func insertValidationResultWithOutbox(
        sessionId: String,
        filePath: String,
        validatorName: String,
        category: String,
        exitCode: Int32,
        rawOutput: String?,
        advisory: String,
        durationMs: Int,
        projectRoot: String?,
        outcome: String? = nil,
        reason: String? = nil,
        validationRunId: String? = nil
    ) -> (resultId: Int64, streamId: Int64)? {
        validationStore.insertValidationResultWithOutbox(
            sessionId: sessionId,
            filePath: filePath,
            validatorName: validatorName,
            category: category,
            exitCode: exitCode,
            rawOutput: rawOutput,
            advisory: advisory,
            durationMs: durationMs,
            projectRoot: projectRoot,
            outcome: outcome,
            reason: reason,
            validationRunId: validationRunId
        )
    }

    /// U.9c-1 — total canonical `validation_results` rows (parity audit).
    public func validationResultsRowCount() -> Int {
        validationStore.validationResultsRowCount()
    }

    /// V.18a-5 — read the `validation_run_id` stored on a row.
    public func validationRunId(forResultId id: Int64) -> String? {
        validationStore.validationRunId(forResultId: id)
    }

    /// V.18a-5 — find the most recent validation_results.id for a session.
    public func mostRecentValidationResultId(sessionId: String) -> Int64? {
        validationStore.mostRecentValidationResultId(sessionId: sessionId)
    }

    /// U.2a-2b — minimal row shape returned by
    /// `firstFailingBrowserValidation(sessionId:)`. `axesJSON` is the
    /// raw `axes` column (JSON array, e.g. `["perf","completeness"]`)
    /// for HookRouter to derive a single representative `failing_axis`
    /// without re-querying. Schneier side-channel guard: the row
    /// deliberately omits raw assertion output.
    public struct BrowserValidationFailRow: Sendable, Equatable {
        public let id: Int64
        public let targetURL: String?
        public let axesJSON: String
        public let advisory: String
        public let createdAt: Date
    }

    /// U.2a-2b — insert a structured browser-validation row.
    ///
    /// V.18a-5 — optional `validationRunId` tags the row for the
    /// cross-cutting JOIN against `runtime_telemetry_span`.
    public func insertBrowserValidationResult(
        sessionId: String,
        targetURL: String,
        axes: [String],
        planStepsJSON: String,
        resultStatus: String,
        assertionsPassed: Int,
        assertionsFailed: Int,
        advisory: String,
        screenshotPath: String?,
        validationRunId: String? = nil
    ) {
        validationStore.insertBrowserValidationResult(
            sessionId: sessionId,
            targetURL: targetURL,
            axes: axes,
            planStepsJSON: planStepsJSON,
            resultStatus: resultStatus,
            assertionsPassed: assertionsPassed,
            assertionsFailed: assertionsFailed,
            advisory: advisory,
            screenshotPath: screenshotPath,
            validationRunId: validationRunId
        )
    }

    /// U.2a-2b — first failing browser-validation row for a session
    /// (HookRouter PreToolUse hard-block reader).
    public func firstFailingBrowserValidation(sessionId: String) -> BrowserValidationFailRow? {
        validationStore.firstFailingBrowserValidation(sessionId: sessionId)
    }

    /// Fetch undelivered validation results with errors for a session.
    public func pendingValidationAdvisories(sessionId: String) -> [ValidationResultRow] {
        validationStore.pendingValidationAdvisories(sessionId: sessionId)
    }

    /// Fetch validation rows for inspection/diagnostics.
    public func validationResults(sessionId: String, outcome: String? = nil) -> [ValidationResultRow] {
        validationStore.validationResults(sessionId: sessionId, outcome: outcome)
    }

    /// Mark advisory rows as surfaced after their text was placed into a hook response.
    public func markValidationAdvisoriesSurfaced(ids: [Int64]) {
        validationStore.markValidationAdvisoriesSurfaced(ids: ids)
    }

    /// U.9b-3b — synchronous, idempotent delivery claim for the bus-side
    /// `validation` consumer. Returns `true` only when THIS call flipped a
    /// still-pending advisory row to delivered (guarded UPDATE — replays
    /// and rows the in-process leg already surfaced lose the claim).
    public func claimValidationDelivery(resultId: Int64) -> Bool {
        validationStore.claimValidationDelivery(resultId: resultId)
    }

    /// Legacy compatibility helper for callers/tests that explicitly want the old destructive read.
    public func fetchAndMarkDelivered(sessionId: String) -> [ValidationResultRow] {
        validationStore.fetchAndMarkDelivered(sessionId: sessionId)
    }

    /// U.11a-2 — resolve a batch of `validation_run_id` UUIDs against
    /// `validation_results`. Returns a structured `(resolved,
    /// unresolved)` partition; unresolved IDs are surfaced as data,
    /// not thrown. Used by `ValidationAssertion` resolution.
    public func resolveValidationRuns(_ runIDs: [UUID]) -> ValidationEvidenceResolution {
        validationStore.resolveValidationRuns(runIDs)
    }

    /// Prune old validation results.
    @discardableResult
    public func pruneValidationResults(olderThanHours: Int = 24) -> Int {
        validationStore.pruneValidationResults(olderThanHours: olderThanHours)
    }
}
