import Foundation
import SQLite3

/// Owns the lifecycle of ONE workstream's pane session. Wraps the
/// `workstreams` SQLite table (migration v37, shipped in U.11-pre a-1)
/// with a strict state-machine surface — `start`, `pause`, `resume`,
/// `archive`, plus a read-side `currentState`.
///
/// **Not** an autorun loop. The driver is a state-machine wrapper;
/// the autorun scheduler that calls `start()` / `pause()` on a cadence
/// lands in U.3. **Not** an agent dispatcher either — no skills,
/// models, or tools are invoked here.
///
/// **Audit-chain integration is deferred to a-3.** Each transition
/// method's body has a marked hook point where a-3 will emit a
/// chained `workstream.<event>` row to `token_events` (under a v38
/// `ChainVerifier` anchor extension). Until a-3 ships, transitions
/// update the `workstreams.state` column and nothing else.
///
/// Concurrency: the actor isolation guarantees serial access to
/// `currentLifecycle` across awaits. Every SQL touch goes through
/// `database.queue` — never the raw `db` pointer — matching the
/// queue-affinity invariant documented on `SessionDatabase`.
public actor PaneSessionDriver {

    /// Identity of the workstream this driver owns. Matches
    /// `WorkstreamModel.id` in the App layer and
    /// `workstreams.id` (UUID bytes) in SQLite.
    public let workstreamID: UUID

    /// Stable slug used for CLI / log / audit-chain lookups. UNIQUE
    /// across the `workstreams` table.
    public let slug: String

    /// SQLite handle. The driver never reaches into `database.db`
    /// directly — every read/write goes through `database.queue`.
    private let database: SessionDatabase

    /// Cached in-memory copy of the persisted lifecycle. Populated
    /// lazily by `currentState()` / `start()`; rehydrated from the
    /// SQLite row on first access, then kept in sync with each
    /// successful transition.
    private var cached: WorkstreamLifecycle?

    public init(workstreamID: UUID, slug: String, database: SessionDatabase) {
        self.workstreamID = workstreamID
        self.slug = slug
        self.database = database
    }

    // MARK: - Lifecycle commands

    /// Start the workstream. If no row exists for `workstreamID`,
    /// inserts a fresh `.running` row (slug + createdAt = now). If
    /// a row already exists, validates the `<currentState> → running`
    /// transition and updates the `state` column.
    ///
    /// Throws `WorkstreamStateTransitionError` if the existing row's
    /// state cannot legally move to `.running` (e.g. `archived → running`).
    public func start() throws {
        try transition(to: .running, allowInitialInsert: true)
    }

    /// Pause the workstream. Requires the row to exist; throws
    /// `WorkstreamLifecycleError.notFound` otherwise (calling pause on
    /// a workstream that was never started is a programming error,
    /// not a state-machine transition).
    public func pause() throws {
        try transition(to: .paused, allowInitialInsert: false)
    }

    /// Resume a paused workstream. Same not-found semantics as `pause`.
    public func resume() throws {
        try transition(to: .running, allowInitialInsert: false)
    }

    /// Archive the workstream. Terminal — no transitions out of
    /// `.archived` per `WorkstreamState.validateTransition`.
    public func archive() throws {
        try transition(to: .archived, allowInitialInsert: false)
    }

    /// Read the current persisted state. Refreshes the cache from
    /// SQLite if no in-memory copy is held yet; otherwise returns the
    /// cached value. Returns `nil` if no row exists for
    /// `workstreamID` (workstream has never been started).
    public func currentState() throws -> WorkstreamState? {
        if let cached { return cached.state }
        guard let loaded = try loadRow() else { return nil }
        cached = loaded
        return loaded.state
    }

    // MARK: - Internal helpers

    private func transition(to next: WorkstreamState, allowInitialInsert: Bool) throws {
        let existingOrNil: WorkstreamLifecycle?
        if let cached {
            existingOrNil = cached
        } else {
            existingOrNil = try loadRow()
        }
        if let existing = existingOrNil {
            try existing.state.validateTransition(to: next)
            try updateState(next)
            var updated = existing
            updated.state = next
            cached = updated
            // a-3 hook: emit chained `workstream.<event>` row to
            // `token_events` referencing this transition. Until then,
            // the SQL update is the only persisted side effect.
        } else if allowInitialInsert {
            let now = Date()
            try insertRow(state: next, createdAt: now)
            cached = WorkstreamLifecycle(
                id: workstreamID,
                slug: slug,
                state: next,
                createdAt: now)
            // a-3 hook: emit chained `workstream.created` row alongside
            // the initial `workstream.<event>` transition row.
        } else {
            throw WorkstreamLifecycleError.notFound(id: workstreamID, slug: slug)
        }
    }

    // MARK: - SQL access

    private func loadRow() throws -> WorkstreamLifecycle? {
        var loaded: WorkstreamLifecycle?
        var caughtError: Error?
        database.queue.sync { [database, workstreamID] in
            guard let db = database.db else {
                caughtError = WorkstreamLifecycleError.databaseClosed
                return
            }
            let sql = """
                SELECT slug, state, created_at
                  FROM workstreams
                 WHERE id = ?
                 LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                caughtError = WorkstreamLifecycleError.sqlPrepareFailed(
                    stage: "loadRow",
                    detail: Self.lastErrorMessage(db))
                return
            }
            defer { sqlite3_finalize(stmt) }
            Self.bindUUID(stmt, idx: 1, uuid: workstreamID)
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return }
            guard rc == SQLITE_ROW else {
                caughtError = WorkstreamLifecycleError.sqlStepFailed(
                    stage: "loadRow",
                    detail: Self.lastErrorMessage(db))
                return
            }
            guard
                let slugPtr = sqlite3_column_text(stmt, 0),
                let statePtr = sqlite3_column_text(stmt, 1)
            else {
                caughtError = WorkstreamLifecycleError.decodeFailed(
                    stage: "loadRow",
                    detail: "NULL slug or state")
                return
            }
            let slugStr = String(cString: slugPtr)
            let stateStr = String(cString: statePtr)
            guard let state = WorkstreamState(rawValue: stateStr) else {
                caughtError = WorkstreamLifecycleError.decodeFailed(
                    stage: "loadRow",
                    detail: "unknown state \(stateStr)")
                return
            }
            let createdAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 2)))
            loaded = WorkstreamLifecycle(
                id: workstreamID,
                slug: slugStr,
                state: state,
                createdAt: createdAt)
        }
        if let caughtError { throw caughtError }
        return loaded
    }

    private func insertRow(state: WorkstreamState, createdAt: Date) throws {
        var caughtError: Error?
        database.queue.sync { [database, workstreamID, slug] in
            guard let db = database.db else {
                caughtError = WorkstreamLifecycleError.databaseClosed
                return
            }
            let sql = """
                INSERT INTO workstreams (id, slug, state, created_at)
                VALUES (?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                caughtError = WorkstreamLifecycleError.sqlPrepareFailed(
                    stage: "insertRow",
                    detail: Self.lastErrorMessage(db))
                return
            }
            defer { sqlite3_finalize(stmt) }
            Self.bindUUID(stmt, idx: 1, uuid: workstreamID)
            sqlite3_bind_text(stmt, 2, (slug as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 3, (state.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int64(stmt, 4, Int64(createdAt.timeIntervalSince1970))
            if sqlite3_step(stmt) != SQLITE_DONE {
                caughtError = WorkstreamLifecycleError.sqlStepFailed(
                    stage: "insertRow",
                    detail: Self.lastErrorMessage(db))
            }
        }
        if let caughtError { throw caughtError }
    }

    private func updateState(_ state: WorkstreamState) throws {
        var caughtError: Error?
        database.queue.sync { [database, workstreamID] in
            guard let db = database.db else {
                caughtError = WorkstreamLifecycleError.databaseClosed
                return
            }
            let sql = "UPDATE workstreams SET state = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                caughtError = WorkstreamLifecycleError.sqlPrepareFailed(
                    stage: "updateState",
                    detail: Self.lastErrorMessage(db))
                return
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (state.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            Self.bindUUID(stmt, idx: 2, uuid: workstreamID)
            if sqlite3_step(stmt) != SQLITE_DONE {
                caughtError = WorkstreamLifecycleError.sqlStepFailed(
                    stage: "updateState",
                    detail: Self.lastErrorMessage(db))
            }
        }
        if let caughtError { throw caughtError }
    }

    private static func bindUUID(_ stmt: OpaquePointer?, idx: Int32, uuid: UUID) {
        var bytes = uuid.uuid
        withUnsafeBytes(of: &bytes) { raw in
            _ = sqlite3_bind_blob(stmt, idx, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT_DESTRUCTOR)
        }
    }

    private static func lastErrorMessage(_ db: OpaquePointer?) -> String {
        guard let db, let cstr = sqlite3_errmsg(db) else { return "unknown" }
        return String(cString: cstr)
    }
}

/// Errors raised by `PaneSessionDriver` for non-transition failure
/// modes (state-machine rejections continue to surface as
/// `WorkstreamStateTransitionError`).
public enum WorkstreamLifecycleError: Error, Equatable, Sendable {
    case notFound(id: UUID, slug: String)
    case databaseClosed
    case sqlPrepareFailed(stage: String, detail: String)
    case sqlStepFailed(stage: String, detail: String)
    case decodeFailed(stage: String, detail: String)
}
