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
        reason: String? = nil
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
            reason: reason
        )
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

    /// Legacy compatibility helper for callers/tests that explicitly want the old destructive read.
    public func fetchAndMarkDelivered(sessionId: String) -> [ValidationResultRow] {
        validationStore.fetchAndMarkDelivered(sessionId: sessionId)
    }

    /// Prune old validation results.
    @discardableResult
    public func pruneValidationResults(olderThanHours: Int = 24) -> Int {
        validationStore.pruneValidationResults(olderThanHours: olderThanHours)
    }
}
