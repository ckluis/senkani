import Foundation
import SQLite3

/// Phase V.17a-1 — owns the `provider_runtime_event` table and the
/// `projectIntoAgentTrace(_:)` write-through that feeds V.2's
/// `agent_trace_event` canonical row from `toolCallFinished` and
/// `turnCompleted` events. Mirrors the V.18 `RuntimeTelemetryStore`
/// pattern: shared `SessionDatabase` queue, no actor, per-method
/// `queue.sync` blocks for queue-affinity safety.
///
/// Audit-chain note: this store does NOT participate in the T.5
/// audit chain. The table's `raw_payload_hash UNIQUE` gives at-source
/// idempotency, and any downstream tamper is detectable by re-
/// deriving from the underlying CLI session logs. The store mirrors
/// the V.2 `AgentTraceEventStore` posture (also outside the chain)
/// because the two stores are tiered-derivative pairs.
public final class ProviderRuntimeEventStore: @unchecked Sendable {
    private unowned let parent: SessionDatabase

    /// Outcome of an `insert(event:)` call. Explicit two-case enum so
    /// call sites can branch on dedup without re-reading
    /// `sqlite3_changes` — V.18 surfaced this affordance gap on its
    /// store; V.17a-1 ships with it from day one.
    public enum InsertOutcome: Sendable, Equatable {
        /// The event was new and a row was inserted.
        case insertedRow
        /// The event's `rawPayloadHash` already existed; nothing was
        /// written.
        case idempotencyHit
    }

    public init(parent: SessionDatabase) {
        self.parent = parent
    }

    // MARK: - Schema

    /// Schema ownership: migration v36 (V.17a-1) owns the table +
    /// indexes. No residual DDL — this is a no-op kept for symmetry
    /// with the other stores.
    public func setupSchema() {
        // Intentionally empty.
    }

    // MARK: - Writes

    /// Record one provider runtime event. UNIQUE on
    /// `raw_payload_hash` dedupes at the SQL layer. Returns
    /// `.insertedRow` if a new row landed; `.idempotencyHit` if the
    /// payload hash was already present.
    @discardableResult
    public func insert(event: ProviderRuntimeEvent) -> InsertOutcome {
        return parent.queue.sync {
            guard let db = parent.db else { return .idempotencyHit }
            let sql = """
                INSERT INTO provider_runtime_event
                    (raw_payload_hash, provider_id, session_id, thread_id, turn_id, pane,
                     event_type, observed_at,
                     prompt_tokens, completion_tokens, cached_tokens,
                     tool_call_id, tool_name, tool_result, approval_id,
                     warnings_json, projection_status)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(raw_payload_hash) DO NOTHING;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return .idempotencyHit
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (event.rawPayloadHash as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 2, (event.providerID as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            Self.bindOptionalText(stmt, 3, event.sessionID)
            Self.bindOptionalText(stmt, 4, event.threadID)
            Self.bindOptionalText(stmt, 5, event.turnID)
            Self.bindOptionalText(stmt, 6, event.pane)
            sqlite3_bind_text(stmt, 7, (event.type.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_double(stmt, 8, event.observedAt.timeIntervalSince1970)
            Self.bindOptionalInt(stmt, 9, event.tokens?.promptTokens)
            Self.bindOptionalInt(stmt, 10, event.tokens?.completionTokens)
            Self.bindOptionalInt(stmt, 11, event.tokens?.cachedTokens)
            Self.bindOptionalText(stmt, 12, event.toolCallID)
            Self.bindOptionalText(stmt, 13, event.toolName)
            Self.bindOptionalText(stmt, 14, event.toolResult)
            Self.bindOptionalText(stmt, 15, event.approvalID)
            let warningsJSON = Self.encodeWarnings(event.warnings)
            Self.bindOptionalText(stmt, 16, warningsJSON)
            // Auto-stamp ineligible events as `.ineligible` even when
            // a caller passes the default — keeps the column truthful
            // about derived state vs. caller intent.
            let stampedStatus: ProviderRuntimeEvent.ProjectionStatus
            if event.isProjectable {
                stampedStatus = (event.projectionStatus == .ineligible) ? .pending : event.projectionStatus
            } else {
                stampedStatus = .ineligible
            }
            sqlite3_bind_text(stmt, 17, (stampedStatus.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)

            guard sqlite3_step(stmt) == SQLITE_DONE else { return .idempotencyHit }
            return sqlite3_changes(db) > 0 ? .insertedRow : .idempotencyHit
        }
    }

    // MARK: - Projection (V.17a-1 → V.2 write-through)

    /// Project a `toolCallFinished` or `turnCompleted` event into a
    /// canonical `AgentTraceEvent`. Returns `true` if a new row was
    /// inserted, `false` if the projection was deduped (idempotency
    /// hit on the V.2 store) or if the event is ineligible.
    ///
    /// Idempotency: the V.2 store keys on `idempotency_key` UNIQUE.
    /// This helper derives the key from `rawPayloadHash` so a replay
    /// of the same provider event projects to the same trace row.
    @discardableResult
    public func projectIntoAgentTrace(_ event: ProviderRuntimeEvent) -> Bool {
        guard event.isProjectable else { return false }

        let key = "v17a:\(event.rawPayloadHash)"
        let row = AgentTraceEvent(
            idempotencyKey: key,
            pane: event.pane,
            project: nil,
            model: nil,
            tier: nil,
            ladderPosition: nil,
            feature: nil,
            result: deriveResult(event),
            startedAt: event.observedAt,
            completedAt: event.observedAt,
            latencyMs: 0,
            tokensIn: event.tokens?.promptTokens ?? 0,
            tokensOut: event.tokens?.completionTokens ?? 0,
            costCents: 0,
            redactionCount: 0,
            validationStatus: nil,
            confirmationRequired: false,
            egressDecisions: 0,
            planId: nil,
            costLedgerVersion: nil,
            sessionId: event.sessionID,
            toolCallId: event.toolCallID
        )

        let inserted = parent.agentTraceEventStore.record(row)

        // Flip the projection_status column to reflect what happened
        // downstream. Idempotent — replays land on the same row and
        // set the same status.
        let newStatus: ProviderRuntimeEvent.ProjectionStatus =
            inserted ? .projected : .dedup
        updateProjectionStatus(
            rawPayloadHash: event.rawPayloadHash,
            status: newStatus
        )
        return inserted
    }

    /// Derive a `CallResult` from a provider event. The V.2 column
    /// is NOT NULL, so this always returns a typed value. Provider-
    /// specific `toolResult` strings map heuristically — adapters in
    /// v17a-2..5 may extend this once provider vocabularies stabilise.
    private func deriveResult(_ event: ProviderRuntimeEvent) -> CallResult {
        guard let raw = event.toolResult?.lowercased() else {
            // turnCompleted with no toolResult: treat as success
            // unless warnings present.
            return event.warnings.isEmpty ? .success : .error
        }
        if raw.contains("success") || raw == "ok" || raw == "done" {
            return .success
        }
        if raw.contains("timeout") {
            return .timeout
        }
        if raw.contains("deny") || raw.contains("denied") || raw.contains("blocked") {
            return .denied
        }
        if raw.contains("error") || raw.contains("fail") {
            return .error
        }
        return .unknown
    }

    // MARK: - Counts + reads (test affordances)

    public func countAll() -> Int {
        return parent.queue.sync {
            guard let db = parent.db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM provider_runtime_event;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }

    /// Read the stored `projection_status` for a payload hash.
    /// Returns nil if the row doesn't exist.
    public func projectionStatus(rawPayloadHash: String) -> ProviderRuntimeEvent.ProjectionStatus? {
        return parent.queue.sync {
            guard let db = parent.db else { return nil }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT projection_status FROM provider_runtime_event WHERE raw_payload_hash = ?;", -1, &stmt, nil) == SQLITE_OK else {
                return nil
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (rawPayloadHash as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let raw = String(cString: sqlite3_column_text(stmt, 0))
            return ProviderRuntimeEvent.ProjectionStatus(rawValue: raw)
        }
    }

    // MARK: - Internal helpers

    private func updateProjectionStatus(rawPayloadHash: String, status: ProviderRuntimeEvent.ProjectionStatus) {
        parent.queue.sync {
            guard let db = parent.db else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE provider_runtime_event SET projection_status = ? WHERE raw_payload_hash = ?;", -1, &stmt, nil) == SQLITE_OK else {
                return
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (status.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 2, (rawPayloadHash as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            _ = sqlite3_step(stmt)
        }
    }

    private static func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let val = value {
            sqlite3_bind_text(stmt, index, (val as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private static func bindOptionalInt(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int?) {
        if let val = value {
            sqlite3_bind_int64(stmt, index, Int64(val))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private static func encodeWarnings(_ warnings: [String]) -> String? {
        if warnings.isEmpty { return nil }
        guard let data = try? JSONEncoder().encode(warnings) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
