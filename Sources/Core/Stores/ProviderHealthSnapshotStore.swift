import Foundation
import SQLite3

/// Phase V.17b-1 — owns the `provider_health_snapshot` table (migration
/// v48). Upsert/read keyed by `provider_id`. Mirrors the V.17a-1
/// `ProviderRuntimeEventStore` posture: shared `SessionDatabase` queue,
/// no actor, per-method `queue.sync` for queue-affinity safety.
///
/// No-network: this store performs only LOCAL SQLite writes/reads. It
/// never makes a network call and never writes to `egress_decisions`.
/// The probe that fills a snapshot (local `--version`) lives in the CLI
/// command, not here.
public final class ProviderHealthSnapshotStore: @unchecked Sendable {
    private unowned let parent: SessionDatabase

    public init(parent: SessionDatabase) {
        self.parent = parent
    }

    /// Schema ownership: migration v48 owns the table + index. No-op
    /// kept for symmetry with the other stores.
    public func setupSchema() {
        // Intentionally empty.
    }

    // MARK: - Writes

    /// Upsert one snapshot keyed by `provider_id`. A second upsert for
    /// the same provider replaces the row (last-write-wins) — there is
    /// exactly one current snapshot per provider.
    public func upsert(_ snapshot: ProviderHealthSnapshot) {
        parent.queue.sync {
            guard let db = parent.db else { return }
            let sql = """
                INSERT INTO provider_health_snapshot
                    (provider_id, cli_installed, version, auth_state,
                     selected_model, subscription_state, last_refresh,
                     ttl_stale_s, ttl_error_s, remediation_hint)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(provider_id) DO UPDATE SET
                    cli_installed = excluded.cli_installed,
                    version = excluded.version,
                    auth_state = excluded.auth_state,
                    selected_model = excluded.selected_model,
                    subscription_state = excluded.subscription_state,
                    last_refresh = excluded.last_refresh,
                    ttl_stale_s = excluded.ttl_stale_s,
                    ttl_error_s = excluded.ttl_error_s,
                    remediation_hint = excluded.remediation_hint;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (snapshot.providerID as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int(stmt, 2, snapshot.cliInstalled ? 1 : 0)
            Self.bindOptionalText(stmt, 3, snapshot.version)
            sqlite3_bind_text(stmt, 4, (snapshot.authState.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            Self.bindOptionalText(stmt, 5, snapshot.selectedModel)
            Self.bindOptionalText(stmt, 6, snapshot.subscriptionState)
            sqlite3_bind_double(stmt, 7, snapshot.lastRefresh.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 8, snapshot.ttl.staleSeconds)
            sqlite3_bind_double(stmt, 9, snapshot.ttl.errorSeconds)
            Self.bindOptionalText(stmt, 10, snapshot.remediationHint)
            _ = sqlite3_step(stmt)
        }
    }

    /// Flip ONLY `last_refresh` forward for an existing provider row
    /// (the event-driven refresh: a `turn_completed` event freshens the
    /// snapshot without re-probing the CLI). No-op when the provider has
    /// no snapshot yet — an event for an un-probed provider does not
    /// fabricate a row (the CLI probe owns row creation). Returns true
    /// when a row was updated.
    @discardableResult
    public func touchLastRefresh(providerID: String, at date: Date) -> Bool {
        parent.queue.sync {
            guard let db = parent.db else { return false }
            var stmt: OpaquePointer?
            let sql = "UPDATE provider_health_snapshot SET last_refresh = ? WHERE provider_id = ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, (providerID as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
            return sqlite3_changes(db) > 0
        }
    }

    // MARK: - Reads

    /// Read the current snapshot for a provider, or nil if none exists.
    public func read(providerID: String) -> ProviderHealthSnapshot? {
        parent.queue.sync {
            guard let db = parent.db else { return nil }
            let sql = """
                SELECT provider_id, cli_installed, version, auth_state,
                       selected_model, subscription_state, last_refresh,
                       ttl_stale_s, ttl_error_s, remediation_hint
                  FROM provider_health_snapshot WHERE provider_id = ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (providerID as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Self.rowToSnapshot(stmt)
        }
    }

    /// Read every snapshot, oldest-refresh first (the GUI sibling's
    /// primary render order: most-stale at the top).
    public func readAll() -> [ProviderHealthSnapshot] {
        parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT provider_id, cli_installed, version, auth_state,
                       selected_model, subscription_state, last_refresh,
                       ttl_stale_s, ttl_error_s, remediation_hint
                  FROM provider_health_snapshot ORDER BY last_refresh ASC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var rows: [ProviderHealthSnapshot] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let snap = Self.rowToSnapshot(stmt) { rows.append(snap) }
            }
            return rows
        }
    }

    // MARK: - Internal helpers

    private static func rowToSnapshot(_ stmt: OpaquePointer?) -> ProviderHealthSnapshot? {
        guard let providerCStr = sqlite3_column_text(stmt, 0) else { return nil }
        let providerID = String(cString: providerCStr)
        let cliInstalled = sqlite3_column_int(stmt, 1) != 0
        let version = columnOptionalText(stmt, 2)
        let authRaw = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "unknown"
        let authState = ProviderHealthSnapshot.AuthState(rawValue: authRaw) ?? .unknown
        let selectedModel = columnOptionalText(stmt, 4)
        let subscriptionState = columnOptionalText(stmt, 5)
        let lastRefresh = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
        let ttlStale = sqlite3_column_double(stmt, 7)
        let ttlError = sqlite3_column_double(stmt, 8)
        let remediationHint = columnOptionalText(stmt, 9)
        return ProviderHealthSnapshot(
            providerID: providerID,
            cliInstalled: cliInstalled,
            version: version,
            authState: authState,
            selectedModel: selectedModel,
            subscriptionState: subscriptionState,
            lastRefresh: lastRefresh,
            ttl: ProviderHealthSnapshot.TTL(staleSeconds: ttlStale, errorSeconds: ttlError),
            remediationHint: remediationHint
        )
    }

    private static func columnOptionalText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cstr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cstr)
    }

    private static func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let val = value {
            sqlite3_bind_text(stmt, index, (val as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}
