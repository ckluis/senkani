import Testing
import Foundation
import SQLite3
@testable import Core

/// `policy_snapshots` is the load-bearing audit baseline cited by
/// counterfactual replay reports. Without chain anchoring a write-
/// capable attacker can rewrite snapshot rows and the replay surface
/// silently lies. These tests exercise migration v17's schema shape +
/// PolicyStore's chain wiring + ChainVerifier's policy_snapshots
/// walker.
///
/// `.serialized` belt-and-suspenders alongside the busy_timeout fix in
/// `TempSessionDatabase.openSecondaryHandle`: helpers below tamper /
/// peek on-disk sqlite rows via a second handle, and parallel-runner
/// CPU/IO pressure was masking writer lock contention as `tamper code 2
/// "database is locked"` in the sibling ChainRepairTests suite. See
/// `chainverifier-policysnapshots-secondary-handle-busy-timeout-2026-05-04`.
@Suite("PolicySnapshotsChain — migration v17 schema + tamper-evidence", .serialized)
struct PolicySnapshotsChainTests {

    // MARK: - Helpers

    private static func makeDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-policy-chain-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        return (db, path)
    }

    private static func makeConfig(filter: Bool = true) -> PolicyConfig {
        PolicyConfig(
            features: PolicyFeatures(
                filter: filter, secrets: true, indexer: true,
                terse: false, injectionGuard: true
            ),
            budget: PolicyBudget(
                perSessionLimitCents: nil, dailyLimitCents: nil,
                weeklyLimitCents: nil, softLimitPercent: 0.8
            ),
            learnedRulesHash: "h-\(filter)",
            modelId: "claude-haiku-4-5",
            modelTier: nil,
            agentType: "claude_code",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// Tamper one column of one row directly via raw sqlite — chain
    /// columns left intact. Mirrors `ChainVerifierTests.tamper`.
    private static func tamper(_ path: String, rowid: Int64, column: String, value: String) throws {
        guard let db = TempSessionDatabase.openSecondaryHandle(path) else {
            throw NSError(domain: "tamper", code: 1)
        }
        defer { sqlite3_close(db) }
        let sql = "UPDATE policy_snapshots SET \(column) = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "tamper", code: 2)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (value as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 2, rowid)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "tamper", code: 3)
        }
    }

    private static func selectAllRowids(path: String) throws -> [Int64] {
        guard let db = TempSessionDatabase.openSecondaryHandle(path) else {
            throw NSError(domain: "select", code: 1)
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM policy_snapshots ORDER BY id;", -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "select", code: 2)
        }
        defer { sqlite3_finalize(stmt) }
        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(sqlite3_column_int64(stmt, 0))
        }
        return ids
    }

    // MARK: - 1. Schema shape

    @Test("v17 schema: policy_snapshots carries the three chain columns")
    func schemaShape() throws {
        let (db, path) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: path) }

        // PRAGMA table_info — direct read over the raw handle.
        let raw = try #require(TempSessionDatabase.openSecondaryHandle(path))
        defer { sqlite3_close(raw) }
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(raw, "PRAGMA table_info(policy_snapshots);", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }

        var columns: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cstr = sqlite3_column_text(stmt, 1) {
                columns.insert(String(cString: cstr))
            }
        }
        #expect(columns.contains("prev_hash"))
        #expect(columns.contains("entry_hash"))
        #expect(columns.contains("chain_anchor_id"))
    }

    @Test("schema: policy_snapshots.session_id declares REFERENCES sessions(id)")
    func sessionIdForeignKey() throws {
        let (db, path) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let raw = try #require(TempSessionDatabase.openSecondaryHandle(path))
        defer { sqlite3_close(raw) }
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(raw, "PRAGMA foreign_key_list(policy_snapshots);", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }

        // PRAGMA foreign_key_list columns: id, seq, table, from, to, on_update, on_delete, match.
        var found = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            let table = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let from = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let to = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            if table == "sessions" && from == "session_id" && to == "id" {
                found = true
            }
        }
        #expect(found, "policy_snapshots.session_id must declare REFERENCES sessions(id) — documents the relational intent that commands.session_id and other per-session tables already carry, even with PRAGMA foreign_keys off.")
    }

    // MARK: - 2. Happy path: chain of three verifies

    @Test("Chain of three distinct snapshots verifies OK")
    func chainOfThreeVerifies() {
        let (db, path) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let sid = db.createSession(projectRoot: "/tmp/proj", agentType: .claudeCode)
        // Three distinct configs — distinct `learnedRulesHash` values
        // ensure each `policy_hash` differs and the UNIQUE constraint
        // doesn't dedup.
        #expect(db.recordPolicySnapshot(sessionId: sid, config: Self.makeConfig(filter: true)) == true)
        #expect(db.recordPolicySnapshot(sessionId: sid, config: Self.makeConfig(filter: false)) == true)
        let cfg3 = PolicyConfig(
            features: PolicyFeatures(filter: true, secrets: false, indexer: true,
                                     terse: false, injectionGuard: true),
            budget: PolicyBudget(perSessionLimitCents: nil, dailyLimitCents: nil,
                                 weeklyLimitCents: nil, softLimitPercent: 0.8),
            learnedRulesHash: "h-3", modelId: "claude-haiku-4-5",
            modelTier: nil, agentType: "claude_code",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        #expect(db.recordPolicySnapshot(sessionId: sid, config: cfg3) == true)

        let result = ChainVerifier.verifyPolicySnapshots(db)
        guard case .ok = result else {
            Issue.record("expected .ok, got \(result)")
            return
        }
    }

    // MARK: - 3. verifyAll surfaces policy_snapshots

    @Test("verifyAll includes policy_snapshots in its per-table output")
    func verifyAllIncludesPolicySnapshots() {
        let (db, path) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let sid = db.createSession(projectRoot: "/tmp/proj", agentType: .claudeCode)
        #expect(db.recordPolicySnapshot(sessionId: sid, config: Self.makeConfig()) == true)

        let perTable = ChainVerifier.verifyAll(db)
        let psResult = perTable["policy_snapshots"]
        #expect(psResult != nil, "verifyAll must include policy_snapshots")
        if case .ok = psResult {
            // pass
        } else {
            Issue.record("expected policy_snapshots .ok in verifyAll, got \(String(describing: psResult))")
        }
    }

    // MARK: - 4. Tamper policy_json caught

    @Test("Tamper policy_json on row K is caught at row K")
    func tamperPolicyJSONCaught() throws {
        let (db, path) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let sid = db.createSession(projectRoot: "/tmp/proj", agentType: .claudeCode)
        for i in 0..<3 {
            #expect(db.recordPolicySnapshot(sessionId: sid, config: Self.makeConfig(filter: i.isMultiple(of: 2))) == true)
        }
        // recordPolicySnapshot above only inserts two distinct rows
        // because filter alternates true/false/true — the third write
        // dedups against row 1. Use distinct configs explicitly.
        let cfg2 = PolicyConfig(
            features: PolicyFeatures(filter: true, secrets: false, indexer: false,
                                     terse: false, injectionGuard: true),
            budget: PolicyBudget(perSessionLimitCents: nil, dailyLimitCents: nil,
                                 weeklyLimitCents: nil, softLimitPercent: 0.8),
            learnedRulesHash: "h-distinct", modelId: "claude-haiku-4-5",
            modelTier: nil, agentType: "claude_code",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_002)
        )
        #expect(db.recordPolicySnapshot(sessionId: sid, config: cfg2) == true)

        let rowids = try Self.selectAllRowids(path: path)
        #expect(rowids.count >= 2)
        let target = rowids[1]
        try Self.tamper(path, rowid: target, column: "policy_json", value: "{\"tampered\":true}")

        let result = ChainVerifier.verifyPolicySnapshots(db)
        guard case .brokenAt(let table, let rowid, _, _) = result else {
            Issue.record("expected .brokenAt, got \(result)")
            return
        }
        #expect(table == "policy_snapshots")
        #expect(rowid == target)
    }

    // MARK: - 5. Tamper policy_hash caught

    @Test("Tamper policy_hash on row K is caught at row K")
    func tamperPolicyHashCaught() throws {
        let (db, path) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let sid = db.createSession(projectRoot: "/tmp/proj", agentType: .claudeCode)
        #expect(db.recordPolicySnapshot(sessionId: sid, config: Self.makeConfig(filter: true)) == true)
        #expect(db.recordPolicySnapshot(sessionId: sid, config: Self.makeConfig(filter: false)) == true)

        let rowids = try Self.selectAllRowids(path: path)
        #expect(rowids.count == 2)
        // Tamper row 1 (the first, oldest row).
        try Self.tamper(path, rowid: rowids[0], column: "policy_hash", value: "deadbeef-tampered")

        let result = ChainVerifier.verifyPolicySnapshots(db)
        guard case .brokenAt(let table, let rowid, _, _) = result else {
            Issue.record("expected .brokenAt, got \(result)")
            return
        }
        #expect(table == "policy_snapshots")
        #expect(rowid == rowids[0])
    }

    // MARK: - 6. Dedup-no-advance: ON CONFLICT does not poison the chain

    @Test("Dedup write does not advance the chain — next genuinely-new write still verifies")
    func dedupDoesNotAdvanceChain() {
        let (db, path) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let sid = db.createSession(projectRoot: "/tmp/proj", agentType: .claudeCode)
        let cfgA = Self.makeConfig(filter: true)
        let cfgB = Self.makeConfig(filter: false)

        // First insert lands.
        #expect(db.recordPolicySnapshot(sessionId: sid, config: cfgA) == true)
        // Same (session_id, policy_hash) — UNIQUE collision, no row inserted.
        // The chain cache MUST NOT advance off this no-op write.
        #expect(db.recordPolicySnapshot(sessionId: sid, config: cfgA) == false)
        // Genuinely new write — must chain off cfgA's entry_hash, not
        // some stale cache that bumped on the no-op step.
        #expect(db.recordPolicySnapshot(sessionId: sid, config: cfgB) == true)

        let result = ChainVerifier.verifyPolicySnapshots(db)
        guard case .ok = result else {
            Issue.record("expected .ok after dedup-no-advance, got \(result)")
            return
        }
    }
}
