import Foundation
import SQLite3

/// Owns `openai_request_log` end-to-end: schema (migration v41), chained
/// writes, trailing-24h telemetry reads, and 30-day retention pruning.
/// Mirrors `EvalResultsStore` / `EgressDecisionStore` so the chain
/// mechanics stay uniform across participants.
///
/// Phase V.13e-1 — DB-backed persistent request log for the OpenAI-
/// compatible endpoint, replacing the in-memory `OpenAIAuditChain`
/// (`Sources/Core/OpenAIEndpoint/OpenAIAuditChain.swift`) for *cross-
/// process* telemetry. The in-memory chain dies with the process; this
/// store persists one metadata row per served request so v13e-2's
/// doctor check and v13e-5's burst test can read trailing-24h request
/// count + 429-rate after a restart.
///
/// **Privacy.** The raw API key is NEVER written — only `keyLabel`
/// (the provisioned key's label). The `record` API has no raw-key
/// parameter, so a raw key cannot reach disk through this surface.
/// There are no request/response body columns: this is a metadata-only
/// observability log, distinct from the in-memory chain's opt-in
/// `--audit-bodies` shape.
///
/// Concurrency: every `sqlite3_*` call against `parent.db` runs on
/// `parent.queue` (the SessionDatabase queue-affinity invariant I1).
/// The chain-participating write commits synchronously from the caller
/// (invariant I10) so a short-lived `senkani` subprocess that records a
/// request observes a durable row before it exits.
public final class OpenAIRequestLogStore: @unchecked Sendable {
    private unowned let parent: SessionDatabase
    private let chain = ChainState(table: "openai_request_log")

    /// Canonical table name fed to `ChainHasher`.
    static let table = "openai_request_log"

    init(parent: SessionDatabase) {
        self.parent = parent
    }

    /// The served-request surface. Stored as TEXT; the enum gives
    /// compile-time safety at the call site (mirrors how the egress
    /// store takes `EgressRule.Decision`).
    ///
    /// `.other` is the bucket for a `/v1/*` request whose path has no
    /// specific surface scope (e.g. `/v1/models`, the bare `/v1`).
    /// Used by `OpenAIServedRequestSink.recordRefusal` so a 401 / 403 /
    /// 429 on a surface-less path records honestly instead of bucketing
    /// to `.chat`. Telemetry consumers reading per-surface ratios see
    /// the real attribution; security analysis can slice
    /// unauthenticated-probe signal (e.g. enumeration of `/v1/models`)
    /// off it. The doctor `429-rate` is surface-agnostic and untouched.
    public enum Surface: String, Sendable, CaseIterable {
        case chat
        case chatStream = "chat_stream"
        case embeddings
        case toolUse = "tool_use"
        case other
    }

    /// Drop the chain cache after a `--repair-chain` motion. Caller
    /// must already be on `parent.queue`.
    func invalidateChainCache() { chain.invalidate() }

    /// Record one served-request row. Synchronous-on-queue (I10) so the
    /// caller observes a durable row on a non-error return. Returns true
    /// on success, false on any SQLite failure (best-effort: a write
    /// failure must NOT crash the listener or the doctor command).
    ///
    /// - Parameters:
    ///   - ts: the request timestamp. Callers pass `Date()`; tests pass
    ///     an arbitrary instant to exercise the trailing-window /
    ///     retention boundaries deterministically.
    ///   - surface: which OpenAI surface served the request.
    ///   - status: the HTTP status code returned.
    ///   - keyLabel: the provisioned key's label, or nil. NEVER the raw
    ///     API key.
    ///   - modelLogged: the producer-side model identity. Success-path
    ///     callers pass the **already-sanitized** value (see
    ///     `OpenAIServedRequestSink.sanitize(modelLogged:)`); refusal-
    ///     path callers pass the literal `<refused>`. Pass `nil` to
    ///     persist SQL NULL (legacy callers that don't have a model
    ///     identity yet — e.g. the V.13e-5 burst test). Migration v42.
    ///   - resolvedTier: the routed tier name (e.g. `local`, `cloud`),
    ///     or nil when no routing decision exists (refusals).
    ///   - inputTokens: prompt token count, or nil when no count exists
    ///     (refusals).
    ///   - outputTokens: completion token count, or nil when no count
    ///     exists (refusals).
    @discardableResult
    public func record(
        ts: Date = Date(),
        surface: Surface,
        status: Int,
        keyLabel: String?,
        modelLogged: String? = nil,
        resolvedTier: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil
    ) -> Bool {
        let tsEpoch = ts.timeIntervalSince1970
        return parent.queue.sync { [parent, chain] in
            guard let db = parent.db else { return false }
            let anchorId = chain.resolveAnchorId(db: db)
            let prevHash = chain.latestEntryHash(db: db, anchorId: anchorId)

            // Migration v42 — the four producer-metadata columns ride the
            // tamper-evident chain. NULL handling matches the verifier's
            // anchor-aware shape branch (see `ChainVerifier
            // .verifyAnchorOpenAIRequestLog`). The writer is single-shape
            // post-v42; legacy pre-v42 rows live under
            // `fresh-install-pre-v42` and the verifier omits these keys
            // from their canonical map.
            let columns: [String: ChainHasher.CanonicalValue] = [
                "ts":            .real(tsEpoch),
                "surface":       .text(surface.rawValue),
                "status":        .integer(Int64(status)),
                "key_label":     keyLabel.map { .text($0) } ?? .null,
                "model_logged":  modelLogged.map { .text($0) } ?? .null,
                "resolved_tier": resolvedTier.map { .text($0) } ?? .null,
                "input_tokens":  inputTokens.map { .integer(Int64($0)) } ?? .null,
                "output_tokens": outputTokens.map { .integer(Int64($0)) } ?? .null,
            ]
            let entryHash = ChainHasher.entryHash(
                table: OpenAIRequestLogStore.table, columns: columns, prev: prevHash
            )

            let sql = """
                INSERT INTO openai_request_log
                    (ts, surface, status, key_label,
                     model_logged, resolved_tier, input_tokens, output_tokens,
                     prev_hash, entry_hash, chain_anchor_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, tsEpoch)
            sqlite3_bind_text(stmt, 2, (surface.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int64(stmt, 3, Int64(status))
            if let keyLabel {
                sqlite3_bind_text(stmt, 4, (keyLabel as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            if let modelLogged {
                sqlite3_bind_text(stmt, 5, (modelLogged as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            if let resolvedTier {
                sqlite3_bind_text(stmt, 6, (resolvedTier as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            if let inputTokens {
                sqlite3_bind_int64(stmt, 7, Int64(inputTokens))
            } else {
                sqlite3_bind_null(stmt, 7)
            }
            if let outputTokens {
                sqlite3_bind_int64(stmt, 8, Int64(outputTokens))
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            if let prevHash {
                sqlite3_bind_text(stmt, 9, (prevHash as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            } else {
                sqlite3_bind_null(stmt, 9)
            }
            sqlite3_bind_text(stmt, 10, (entryHash as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int64(stmt, 11, anchorId)

            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
            chain.recordWrite(anchorId: anchorId, entryHash: entryHash)
            return true
        }
    }

    /// Trailing-window telemetry — the v13e-2 doctor check + v13e-5 burst
    /// test consume this. `rate429` is `count429 / count24h`, or 0 when
    /// no requests landed in the window (no division by zero).
    public struct TrailingStats: Sendable, Equatable {
        public let count24h: Int
        public let count429: Int
        public let rate429: Double
        public init(count24h: Int, count429: Int, rate429: Double) {
            self.count24h = count24h
            self.count429 = count429
            self.rate429 = rate429
        }
    }

    /// Request count + 429-rate over the trailing 24h ending at `now`.
    /// Computed straight from the persisted rows, so it is correct
    /// cross-process: a fresh handle opened at the same DB path returns
    /// the same answer.
    public func trailing24hStats(now: Date = Date()) -> TrailingStats {
        let cutoff = now.timeIntervalSince1970 - 86_400
        let upper = now.timeIntervalSince1970
        return parent.queue.sync {
            guard let db = parent.db else { return TrailingStats(count24h: 0, count429: 0, rate429: 0) }
            let sql = """
                SELECT
                    COUNT(*),
                    SUM(CASE WHEN status = 429 THEN 1 ELSE 0 END)
                  FROM openai_request_log
                 WHERE ts >= ? AND ts <= ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return TrailingStats(count24h: 0, count429: 0, rate429: 0)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_bind_double(stmt, 2, upper)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return TrailingStats(count24h: 0, count429: 0, rate429: 0)
            }
            let total = Int(sqlite3_column_int64(stmt, 0))
            // SUM over zero rows is NULL — treat as 0.
            let n429 = sqlite3_column_type(stmt, 1) == SQLITE_NULL
                ? 0 : Int(sqlite3_column_int64(stmt, 1))
            let rate = total > 0 ? Double(n429) / Double(total) : 0
            return TrailingStats(count24h: total, count429: n429, rate429: rate)
        }
    }

    /// Prune rows older than `retentionDays` (default 30) relative to
    /// `now`. Returns the number of rows deleted. Best-effort: a SQLite
    /// failure returns 0 without throwing.
    ///
    /// Pruning does not touch `chain_anchors` — verification of the
    /// retained tail still walks from the anchor's first surviving
    /// hashed row, exactly as `token_events`' 90-day prune does.
    @discardableResult
    public func prune(retentionDays: Int = 30, now: Date = Date()) -> Int {
        let cutoff = now.timeIntervalSince1970 - Double(retentionDays) * 86_400
        return parent.queue.sync {
            guard let db = parent.db else { return 0 }
            let sql = "DELETE FROM openai_request_log WHERE ts < ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
            return Int(sqlite3_changes(db))
        }
    }

    /// One row as read back from the table (metadata only — no bodies).
    ///
    /// `modelLogged` / `resolvedTier` / `inputTokens` / `outputTokens`
    /// are the V.13e-7 producer-metadata columns (Migration v42). Pre-
    /// v42 rows persist NULL in all four; consumers MUST tolerate `nil`
    /// when surfacing legacy traffic.
    public struct Row: Sendable, Equatable {
        public let id: Int64
        public let ts: Date
        public let surface: String
        public let status: Int
        public let keyLabel: String?
        public let modelLogged: String?
        public let resolvedTier: String?
        public let inputTokens: Int?
        public let outputTokens: Int?
    }

    /// Return the N most recent rows in descending id order.
    public func recent(limit: Int = 100) -> [Row] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT id, ts, surface, status, key_label,
                       model_logged, resolved_tier, input_tokens, output_tokens
                  FROM openai_request_log
                 ORDER BY id DESC
                 LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var out: [Row] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(decodeRow(stmt))
            }
            return out
        }
    }

    /// Total row count.
    public func count() -> Int64 {
        return parent.queue.sync {
            guard let db = parent.db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM openai_request_log;", -1, &stmt, nil) == SQLITE_OK else {
                return 0
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return sqlite3_column_int64(stmt, 0)
        }
    }

    private func decodeRow(_ stmt: OpaquePointer?) -> Row {
        let id = sqlite3_column_int64(stmt, 0)
        let ts = sqlite3_column_double(stmt, 1)
        let surface = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        let status = Int(sqlite3_column_int64(stmt, 3))
        let keyLabel = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
        let modelLogged = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
        let resolvedTier = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
        let inputTokens: Int? = sqlite3_column_type(stmt, 7) == SQLITE_NULL
            ? nil : Int(sqlite3_column_int64(stmt, 7))
        let outputTokens: Int? = sqlite3_column_type(stmt, 8) == SQLITE_NULL
            ? nil : Int(sqlite3_column_int64(stmt, 8))
        return Row(
            id: id,
            ts: Date(timeIntervalSince1970: ts),
            surface: surface,
            status: status,
            keyLabel: keyLabel,
            modelLogged: modelLogged,
            resolvedTier: resolvedTier,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
    }
}
