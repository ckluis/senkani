import Foundation
import SQLite3

/// Round 4 of Phase T.5 — admin-confirmed chain repair.
///
/// A repair opens a NEW `chain_anchors` row whose `reason = "repair-<N>"`
/// and `started_at_rowid = N`. Rows from `N` onward in the affected table
/// are re-bound to the new anchor — but their `prev_hash` and `entry_hash`
/// are wiped to NULL, mirroring the anchor-from-now strategy used by the
/// migration anchors (round 1 + round 3). Subsequent inserts produce real
/// hashes under the new anchor; verification of the new segment starts at
/// the first hashed write.
///
/// The PRE-repair chain segment (rows with id < N under the old anchor)
/// remains intact and continues to verify against its own anchor. So
/// `senkani doctor --verify-chain` after a repair shows:
///   - old anchor: OK (its tip is still hashed)
///   - new anchor: OK (its rows are anchor-from-now until next write)
/// and the summary `<repairs>` count is non-zero.
///
/// `operator_note` on the new anchor records the previous chain's tip
/// hash so a third party can audit "the repair acknowledged this prior
/// state" — even if the post-repair chain disagrees with the pre-repair
/// chain about what should happen next, the cryptographic linkage from
/// the previous tip is preserved.
public enum ChainRepairer {

    public enum RepairError: Error, CustomStringConvertible {
        case unsupportedTable(String)
        case noAnchor(table: String)
        case fromRowidOutOfRange(table: String, fromRowid: Int64, maxRowid: Int64)
        case repairAnchorAlreadyExists(table: String, existingAnchorId: Int64)
        case sqlFailed(stage: String, detail: String)

        public var description: String {
            switch self {
            case .unsupportedTable(let t):
                return "ChainRepairer: table '\(t)' is not a chain participant. Supported: token_events, validation_results, sandboxed_results, commands."
            case .noAnchor(let t):
                return "ChainRepairer: table '\(t)' has no chain anchor — nothing to repair."
            case .fromRowidOutOfRange(let t, let from, let max):
                return "ChainRepairer: --from-rowid \(from) for '\(t)' is out of range (max id is \(max))."
            case .repairAnchorAlreadyExists(let t, let id):
                return "ChainRepairer: a repair anchor already exists for '\(t)' (anchor id \(id)). Use --force to open a second repair anchor."
            case .sqlFailed(let stage, let detail):
                return "ChainRepairer: SQL failure during \(stage): \(detail)"
            }
        }
    }

    public struct RepairOutcome: Sendable {
        public let table: String
        public let fromRowid: Int64
        public let newAnchorId: Int64
        public let priorTipHash: String?
        public let rowsRebound: Int
    }

    /// Tables that participate in the chain. `sandboxed_results` uses TEXT
    /// PKs and is currently repairable only by the operator-edit-by-hand
    /// path; `--repair-chain` for it would require an `--from-created-at`
    /// flag instead. Round 4 ships repair for the three integer-keyed
    /// participants.
    public static let supportedTables: Set<String> = [
        "token_events", "validation_results", "commands",
    ]

    /// Open a new `chain_anchors` row (`reason="repair-<fromRowid>"`),
    /// re-bind every row with `id >= fromRowid` to the new anchor, and
    /// wipe their hashes (anchor-from-now). Returns the outcome.
    ///
    /// Caller is responsible for serialization — execute inside
    /// `SessionDatabase.queue.sync`. The implementation keeps the entire
    /// motion inside one BEGIN IMMEDIATE / COMMIT transaction so a
    /// crash mid-repair leaves the DB in its pre-repair state.
    public static func repair(
        db: OpaquePointer,
        table: String,
        fromRowid: Int64,
        operatorNote: String? = nil,
        force: Bool = false
    ) throws -> RepairOutcome {
        guard supportedTables.contains(table) else {
            throw RepairError.unsupportedTable(table)
        }

        // Probe the table for the rowid bound and the prior-tip hash. The
        // prior tip is the latest entry_hash under the most recent anchor
        // for this table (whatever segment is active at repair time).
        let maxRowid = try queryMaxRowid(db: db, table: table)
        guard maxRowid >= fromRowid else {
            throw RepairError.fromRowidOutOfRange(table: table, fromRowid: fromRowid, maxRowid: maxRowid)
        }

        let priorAnchorId = try queryLatestAnchorId(db: db, table: table)
            ?? { throw RepairError.noAnchor(table: table) }()
        let priorTipHash = try queryLatestEntryHash(db: db, table: table, anchorId: priorAnchorId)

        // Idempotency / repeat-repair guard: refuse a second repair against
        // the same table if the latest anchor is already a repair anchor,
        // unless --force.
        if !force {
            let priorReason = try queryAnchorReason(db: db, anchorId: priorAnchorId)
            if priorReason.hasPrefix("repair-") {
                throw RepairError.repairAnchorAlreadyExists(
                    table: table,
                    existingAnchorId: priorAnchorId
                )
            }
        }

        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            throw RepairError.sqlFailed(stage: "begin", detail: String(cString: sqlite3_errmsg(db)))
        }
        var committed = false
        defer {
            if !committed {
                _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            }
        }

        let newAnchorId = try insertRepairAnchor(
            db: db,
            table: table,
            fromRowid: fromRowid,
            priorTipHash: priorTipHash,
            operatorNote: operatorNote
        )

        let rowsRebound = try rebindRowsToNewAnchor(
            db: db,
            table: table,
            fromRowid: fromRowid,
            newAnchorId: newAnchorId
        )

        guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            throw RepairError.sqlFailed(stage: "commit", detail: String(cString: sqlite3_errmsg(db)))
        }
        committed = true

        return RepairOutcome(
            table: table,
            fromRowid: fromRowid,
            newAnchorId: newAnchorId,
            priorTipHash: priorTipHash,
            rowsRebound: rowsRebound
        )
    }

    /// Count `chain_anchors WHERE reason LIKE 'repair-%'` for the given
    /// table — surfaced as the "/ N repairs" suffix in the doctor summary.
    public static func repairCount(db: OpaquePointer, table: String) -> Int {
        let sql = "SELECT COUNT(*) FROM chain_anchors WHERE table_name = ? AND reason LIKE 'repair-%';"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (table as NSString).utf8String, -1, nil)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    // MARK: - SQL primitives

    private static func queryMaxRowid(db: OpaquePointer, table: String) throws -> Int64 {
        let sql = "SELECT COALESCE(MAX(id), 0) FROM \(table);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw RepairError.sqlFailed(stage: "max-rowid(\(table))", detail: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(stmt, 0)
    }

    private static func queryLatestAnchorId(db: OpaquePointer, table: String) throws -> Int64? {
        let sql = "SELECT MAX(id) FROM chain_anchors WHERE table_name = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw RepairError.sqlFailed(stage: "latest-anchor(\(table))", detail: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (table as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_type(stmt, 0) != SQLITE_NULL
        else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private static func queryLatestEntryHash(
        db: OpaquePointer,
        table: String,
        anchorId: Int64
    ) throws -> String? {
        let sql = """
            SELECT entry_hash FROM \(table)
             WHERE chain_anchor_id = ? AND entry_hash IS NOT NULL
             ORDER BY id DESC LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw RepairError.sqlFailed(stage: "latest-entry(\(table))", detail: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, anchorId)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cstr = sqlite3_column_text(stmt, 0)
        else { return nil }
        return String(cString: cstr)
    }

    private static func queryAnchorReason(db: OpaquePointer, anchorId: Int64) throws -> String {
        let sql = "SELECT reason FROM chain_anchors WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw RepairError.sqlFailed(stage: "anchor-reason", detail: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, anchorId)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cstr = sqlite3_column_text(stmt, 0)
        else { return "" }
        return String(cString: cstr)
    }

    private static func insertRepairAnchor(
        db: OpaquePointer,
        table: String,
        fromRowid: Int64,
        priorTipHash: String?,
        operatorNote: String?
    ) throws -> Int64 {
        // Encode the prior-tip hash into operator_note alongside any caller-
        // supplied note, so the repair carries cryptographic linkage to the
        // segment it superseded.
        let note: String
        switch (priorTipHash, operatorNote) {
        case let (.some(tip), .some(n)):
            note = "prior_tip=\(tip); \(n)"
        case let (.some(tip), .none):
            note = "prior_tip=\(tip)"
        case let (.none, .some(n)):
            note = n
        case (.none, .none):
            note = "prior_tip=<empty>"
        }

        let now = Date().timeIntervalSince1970
        let reason = "repair-\(fromRowid)"
        let sql = """
            INSERT INTO chain_anchors
                (table_name, started_at, started_at_rowid, reason, operator_note)
            VALUES (?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw RepairError.sqlFailed(stage: "anchor-insert", detail: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (table as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 2, now)
        sqlite3_bind_int64(stmt, 3, fromRowid)
        sqlite3_bind_text(stmt, 4, (reason as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 5, (note as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw RepairError.sqlFailed(stage: "anchor-step", detail: String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_last_insert_rowid(db)
    }

    /// Re-bind rows with `id >= fromRowid` in the affected table to the new
    /// anchor and wipe their hashes (anchor-from-now). The chain re-grows
    /// from the next insert.
    private static func rebindRowsToNewAnchor(
        db: OpaquePointer,
        table: String,
        fromRowid: Int64,
        newAnchorId: Int64
    ) throws -> Int {
        let sql = """
            UPDATE \(table)
               SET chain_anchor_id = ?, prev_hash = NULL, entry_hash = NULL
             WHERE id >= ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw RepairError.sqlFailed(stage: "rebind-prepare(\(table))", detail: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, newAnchorId)
        sqlite3_bind_int64(stmt, 2, fromRowid)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw RepairError.sqlFailed(stage: "rebind-step(\(table))", detail: String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_changes(db))
    }
}

// MARK: - Public SessionDatabase API

extension SessionDatabase {

    /// Run a repair on the chain for `table` starting at `fromRowid`. Reads
    /// + writes happen inside the single-writer queue, then per-store
    /// caches are invalidated so the next insert picks up the new anchor.
    ///
    /// CLI callers:
    ///   `senkani doctor --repair-chain --table <T> --from-rowid <N>`
    ///
    /// Returns the outcome on success; throws `ChainRepairer.RepairError`
    /// on failure. Caller should surface `error.description` to the
    /// operator.
    public func repairChain(
        table: String,
        fromRowid: Int64,
        operatorNote: String? = nil,
        force: Bool = false
    ) throws -> ChainRepairer.RepairOutcome {
        var outcome: ChainRepairer.RepairOutcome?
        var caught: Error?
        queue.sync {
            guard let db else {
                caught = ChainRepairer.RepairError.sqlFailed(stage: "open", detail: "no database handle")
                return
            }
            do {
                outcome = try ChainRepairer.repair(
                    db: db,
                    table: table,
                    fromRowid: fromRowid,
                    operatorNote: operatorNote,
                    force: force
                )
                // Drop per-store caches so the next insert picks up the new
                // anchor. Each store holds its own cache; the closures run
                // on the same queue, so this is race-free.
                tokenEventStore?.invalidateChainCache()
                validationStore?.invalidateChainCache()
                sandboxStore?.invalidateChainCache()
                commandStore?.invalidateChainCache()
            } catch {
                caught = error
            }
        }
        if let caught { throw caught }
        guard let outcome else {
            throw ChainRepairer.RepairError.sqlFailed(stage: "post-condition", detail: "no outcome produced")
        }
        return outcome
    }

    /// Total number of `repair-*` anchors across every chain participant.
    /// Surfaced as `… / N repairs` in `senkani doctor --verify-chain`.
    public func totalRepairCount() -> Int {
        return queue.sync {
            guard let db else { return 0 }
            var total = 0
            for table in ChainRepairer.supportedTables {
                total += ChainRepairer.repairCount(db: db, table: table)
            }
            return total
        }
    }
}
