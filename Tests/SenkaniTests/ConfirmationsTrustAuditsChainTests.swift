import Testing
import Foundation
import SQLite3
@testable import Core

/// `confirmations` (T.6a) and `trust_audits` (U.4a) write through the
/// T.5 audit chain at insert time, but until this round neither table
/// was walked by `ChainVerifier.verifyAll`. A motivated bad actor with
/// DB write access could rewrite a confirmation row to make a denied
/// tool call look like an auto-approve, or flip a trust_audits label
/// from FP to TP, and `senkani doctor --verify-chain` would silently
/// pass despite the schema carrying tamper-evidence columns the
/// operator was promised would catch them. These tests close the gap.
@Suite("ConfirmationsTrustAuditsChain — T.5 verifier coverage")
struct ConfirmationsTrustAuditsChainTests {

    // MARK: - Helpers

    private static func makeDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-conf-trust-chain-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        return (db, path)
    }

    private static func makeConfirmation(_ tag: String, decision: ConfirmationDecision = .approve) -> ConfirmationRow {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return ConfirmationRow(
            toolName: "tool-\(tag)",
            requestedAt: now,
            decidedAt: now.addingTimeInterval(0.5),
            decision: decision,
            decidedBy: .operator,
            reason: "round-test-\(tag)"
        )
    }

    private static func makeFlag(_ tag: String, sessionId: String = "s-conf") -> FragmentationDetector.Flag {
        FragmentationDetector.Flag(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sessionId: sessionId,
            paneId: "p-\(tag)",
            toolName: "Bash",
            reason: .toolBurst,
            correlationCount: 3
        )
    }

    /// Single-column tamper via raw sqlite — leaves chain columns intact.
    /// Mirrors `ChainVerifierTests.tamper` / `PolicySnapshotsChainTests.tamper`.
    private static func tamper(
        _ path: String,
        table: String,
        rowid: Int64,
        column: String,
        value: String
    ) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw NSError(domain: "tamper", code: 1)
        }
        defer { sqlite3_close(db) }
        let sql = "UPDATE \(table) SET \(column) = ? WHERE id = ?;"
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

    private static func selectRowids(path: String, table: String) throws -> [Int64] {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw NSError(domain: "select", code: 1)
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM \(table) ORDER BY id;", -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "select", code: 2)
        }
        defer { sqlite3_finalize(stmt) }
        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(sqlite3_column_int64(stmt, 0))
        }
        return ids
    }

    // MARK: - confirmations

    @Test("Confirmations: chain of three verifies OK")
    func confirmationsChainVerifies() {
        let (db, path) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: path) }

        for i in 0..<3 {
            #expect(db.recordConfirmation(Self.makeConfirmation("\(i)")) > 0)
        }

        let result = ChainVerifier.verifyConfirmations(db)
        guard case .ok = result else {
            Issue.record("expected .ok, got \(result)")
            return
        }
    }

    @Test("Confirmations: tamper on row K is caught at row K")
    func confirmationsTamperCaught() throws {
        let (db, path) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: path) }

        for i in 0..<3 {
            #expect(db.recordConfirmation(Self.makeConfirmation("\(i)", decision: .approve)) > 0)
        }

        let rowids = try Self.selectRowids(path: path, table: "confirmations")
        #expect(rowids.count == 3)
        let target = rowids[1]

        // Flip a denied call to look auto-approved.
        try Self.tamper(path, table: "confirmations", rowid: target, column: "decision", value: "auto")

        let result = ChainVerifier.verifyConfirmations(db)
        guard case .brokenAt(let table, let brokenRowid, let expected, let actual) = result else {
            Issue.record("expected .brokenAt, got \(result)")
            return
        }
        #expect(table == "confirmations")
        #expect(brokenRowid == target)
        #expect(expected != actual)
    }

    @Test("Confirmations: verifyAll surfaces confirmations result")
    func verifyAllIncludesConfirmations() {
        let (db, path) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: path) }

        #expect(db.recordConfirmation(Self.makeConfirmation("only")) > 0)

        let perTable = ChainVerifier.verifyAll(db)
        #expect(perTable["confirmations"] != nil, "verifyAll must include confirmations")
        if case .ok = perTable["confirmations"]! {
            // pass
        } else {
            Issue.record("expected confirmations .ok in verifyAll, got \(String(describing: perTable["confirmations"]))")
        }
    }

    // MARK: - trust_audits

    @Test("TrustAudits: flag + label chain verifies OK")
    func trustAuditsChainVerifies() {
        let (db, path) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let flagId = db.recordTrustFlag(Self.makeFlag("a"), score: 5)
        #expect(flagId > 0)
        _ = db.recordTrustFlag(Self.makeFlag("b"), score: 7)
        _ = db.recordTrustLabel(flagId: flagId, label: .fp, labeledBy: "operator")
        _ = db.recordTrustLabel(flagId: flagId, label: .tp, labeledBy: "operator")

        let result = ChainVerifier.verifyTrustAudits(db)
        guard case .ok = result else {
            Issue.record("expected .ok, got \(result)")
            return
        }
    }

    @Test("TrustAudits: tamper label fp→tp on row K is caught at row K")
    func trustAuditsLabelTamperCaught() throws {
        let (db, path) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let flagId = db.recordTrustFlag(Self.makeFlag("flag-1"), score: 5)
        #expect(flagId > 0)
        _ = db.recordTrustLabel(flagId: flagId, label: .fp, labeledBy: "operator")
        _ = db.recordTrustLabel(flagId: flagId, label: .fp, labeledBy: "operator")

        let rowids = try Self.selectRowids(path: path, table: "trust_audits")
        #expect(rowids.count == 3)

        // Tamper the LATEST label row from "fp" → "tp" — exactly the
        // attack the round closes (rewrite the operator's audit verdict).
        let target = rowids[2]
        try Self.tamper(path, table: "trust_audits", rowid: target, column: "label", value: "tp")

        let result = ChainVerifier.verifyTrustAudits(db)
        guard case .brokenAt(let table, let brokenRowid, let expected, let actual) = result else {
            Issue.record("expected .brokenAt, got \(result)")
            return
        }
        #expect(table == "trust_audits")
        #expect(brokenRowid == target)
        #expect(expected != actual)
    }

    @Test("TrustAudits: tamper flag reason on row K is caught at row K")
    func trustAuditsFlagTamperCaught() throws {
        let (db, path) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: path) }

        _ = db.recordTrustFlag(Self.makeFlag("a"), score: 5)
        _ = db.recordTrustFlag(Self.makeFlag("b"), score: 7)
        _ = db.recordTrustFlag(Self.makeFlag("c"), score: 9)

        let rowids = try Self.selectRowids(path: path, table: "trust_audits")
        #expect(rowids.count == 3)
        let target = rowids[1]

        // Flip a tool_burst flag to fragment_stitch — both are valid
        // enum strings so the row is still parseable, but the chain
        // hash no longer matches.
        try Self.tamper(path, table: "trust_audits", rowid: target, column: "reason", value: "fragment_stitch")

        let result = ChainVerifier.verifyTrustAudits(db)
        guard case .brokenAt(let table, let brokenRowid, _, _) = result else {
            Issue.record("expected .brokenAt, got \(result)")
            return
        }
        #expect(table == "trust_audits")
        #expect(brokenRowid == target)
    }

    @Test("TrustAudits: verifyAll surfaces trust_audits result")
    func verifyAllIncludesTrustAudits() {
        let (db, path) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: path) }

        _ = db.recordTrustFlag(Self.makeFlag("only"), score: 5)

        let perTable = ChainVerifier.verifyAll(db)
        #expect(perTable["trust_audits"] != nil, "verifyAll must include trust_audits")
        if case .ok = perTable["trust_audits"]! {
            // pass
        } else {
            Issue.record("expected trust_audits .ok in verifyAll, got \(String(describing: perTable["trust_audits"]))")
        }
    }
}
