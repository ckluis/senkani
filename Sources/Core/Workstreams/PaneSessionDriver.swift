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

    /// U.11a-3 — optional contract attached to this driver. When set,
    /// the lifecycle methods consult any matching gate before applying
    /// the transition. When `nil`, lifecycle methods proceed exactly
    /// as the U.11-pre a-2 baseline (no gate hits, no `gate.evaluate`
    /// rows). The actor isolates the slot — callers must `await`
    /// `attach(contract:gates:)` / `detachContract()`.
    private var attachedContract: WorkstreamTaskContract?

    /// U.11a-3 — gates indexed by the transition point they guard.
    /// Populated via `attach(contract:gates:)`; cleared by
    /// `detachContract()`. Indexed-by-kind because each transition
    /// looks up exactly one gate; multiple gates per kind on the same
    /// contract is out of scope for a-3 (a later child can switch the
    /// shape to `[GateKind: [WorkflowGate]]` if needed).
    private var attachedGatesByKind: [GateKind: WorkflowGate] = [:]

    public init(workstreamID: UUID, slug: String, database: SessionDatabase) {
        self.workstreamID = workstreamID
        self.slug = slug
        self.database = database
    }

    // MARK: - Contract + gate attachment (U.11a-3)

    /// Read-side accessor for the attached contract. `nil` when no
    /// contract is attached (the U.11-pre baseline behavior path).
    public func currentContract() -> WorkstreamTaskContract? {
        attachedContract
    }

    /// Attach (or replace) the driver's contract + gates. The setter
    /// is actor-safe — concurrent calls serialize through the actor's
    /// queue. Passing an empty `gates` array attaches the contract
    /// with no gate hits, which is observably equivalent to no
    /// attachment for lifecycle methods (no `gate.evaluate` rows
    /// emitted) but `currentContract()` will return the contract.
    public func attach(
        contract: WorkstreamTaskContract,
        gates: [WorkflowGate]
    ) {
        self.attachedContract = contract
        var map: [GateKind: WorkflowGate] = [:]
        for gate in gates {
            map[gate.kind] = gate
        }
        self.attachedGatesByKind = map
    }

    /// Clear the attached contract + gates. Subsequent lifecycle
    /// calls fall through to the U.11-pre baseline.
    public func detachContract() {
        self.attachedContract = nil
        self.attachedGatesByKind = [:]
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
        try transition(to: .running, event: .start, allowInitialInsert: true)
    }

    /// Pause the workstream. Requires the row to exist; throws
    /// `WorkstreamLifecycleError.notFound` otherwise (calling pause on
    /// a workstream that was never started is a programming error,
    /// not a state-machine transition).
    public func pause() throws {
        try transition(to: .paused, event: .pause, allowInitialInsert: false)
    }

    /// Resume a paused workstream. Same not-found semantics as `pause`.
    public func resume() throws {
        try transition(to: .running, event: .resume, allowInitialInsert: false)
    }

    /// Archive the workstream. Terminal — no transitions out of
    /// `.archived` per `WorkstreamState.validateTransition`.
    public func archive() throws {
        try transition(to: .archived, event: .archive, allowInitialInsert: false)
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

    private func transition(
        to next: WorkstreamState,
        event: WorkstreamChainEvent,
        allowInitialInsert: Bool
    ) throws {
        let existingOrNil: WorkstreamLifecycle?
        if let cached {
            existingOrNil = cached
        } else {
            existingOrNil = try loadRow()
        }
        // U.11a-3: consult any matching gate BEFORE applying the SQL
        // state update. On `.blocked` outcome the gate.evaluate row is
        // written, then `GateRefusal` is thrown — state is NOT updated,
        // matching the acceptance bullet "the state does NOT transition
        // (currentState unchanged)".
        try consultGate(for: event, currentState: existingOrNil?.state)

        if let existing = existingOrNil {
            try existing.state.validateTransition(to: next)
            try updateState(next)
            var updated = existing
            updated.state = next
            cached = updated
            // U.11-pre a-3: emit chained `workstream.<event>` row to
            // `token_events` AFTER successful SQL update. Rejected
            // transitions throw above before reaching this point — no
            // chained row is written on rejection.
            database.recordWorkstreamEvent(
                workstreamID: workstreamID,
                slug: slug,
                event: event)
        } else if allowInitialInsert {
            let now = Date()
            try insertRow(state: next, createdAt: now)
            cached = WorkstreamLifecycle(
                id: workstreamID,
                slug: slug,
                state: next,
                createdAt: now)
            // U.11-pre a-3: initial insert emits one chained row
            // (`workstream.start`) — the same event the operator's
            // method call requested. No separate "workstream.created"
            // row, per the 2026-05-25 decompose Q1 split (4 row kinds
            // total, mapped 1:1 with driver methods).
            database.recordWorkstreamEvent(
                workstreamID: workstreamID,
                slug: slug,
                event: event)
        } else {
            throw WorkstreamLifecycleError.notFound(id: workstreamID, slug: slug)
        }
    }

    // MARK: - Gate consultation (U.11a-3)

    /// Map a driver lifecycle event to the gate kind that guards it.
    /// Per the 2026-05-25 decompose interview the mapping is fixed:
    ///   - `.start`   → `.preRun`
    ///   - `.pause`   → `.validation`
    ///   - `.resume`  → `.preRun` (re-enter from pause respects the same gate)
    ///   - `.archive` → `.archive`
    private static func gateKind(for event: WorkstreamChainEvent) -> GateKind {
        switch event {
        case .start:   return .preRun
        case .pause:   return .validation
        case .resume:  return .preRun
        case .archive: return .archive
        }
    }

    /// Consult the gate for `event`. No-op when no contract is
    /// attached or when the attached contract has no matching gate
    /// for the kind. Writes one `gate.evaluate` row on every non-
    /// `.allow` outcome (so `block` / `warn` / `advisory` all leave
    /// an audit trail). On `.blocked` outcome, throws `GateRefusal`
    /// AFTER the audit row is written.
    private func consultGate(
        for event: WorkstreamChainEvent,
        currentState: WorkstreamState?
    ) throws {
        guard let contract = attachedContract else { return }
        let kind = Self.gateKind(for: event)
        guard let gate = attachedGatesByKind[kind] else { return }

        let outcome = gate.evaluate(
            currentState: currentState,
            workstreamID: workstreamID
        )
        // `.allow` is a quiet no-op — no audit row, no throw.
        guard outcome != .allow else { return }

        database.recordGateEvent(
            gateID: gate.id,
            contractID: contract.id,
            outcome: outcome
        )
        if case .blocked(let handoff) = outcome {
            throw GateRefusal(handoff: handoff)
        }
        // `.warned` / `.advisory` fall through — driver proceeds to
        // apply the SQL transition. Operator surfaces still see the
        // outcome via the persisted gate.evaluate row.
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
