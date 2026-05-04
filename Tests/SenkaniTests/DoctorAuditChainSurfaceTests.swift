import Testing
import Foundation
import SQLite3
@testable import CLI
@testable import Core

/// `doctor-checkauditchain-display-pane-refresh-state` (2026-05-04).
///
/// `ChainVerifier.verifyAll` covers `pane_refresh_state`, but
/// `DoctorCommand.checkAuditChain`'s display order array and summary
/// line silently dropped it before this round. A tampered row would
/// not produce a per-table BROKEN line on the operator-facing surface.
/// These tests assert on the doctor surface directly via the pure
/// `formatChainAuditLines` helper.
@Suite("DoctorAuditChainSurface — pane_refresh_state coverage")
struct DoctorAuditChainSurfaceTests {

    private static func makeDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-doctorchain-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        return (db, path)
    }

    @Test("chainAuditOrder includes pane_refresh_state")
    func orderIncludesPaneRefreshState() {
        #expect(Doctor.chainAuditOrder.contains("pane_refresh_state"),
                "doctor display order must walk pane_refresh_state — verifyAll covers it")
    }

    @Test("chainAuditOrder matches ChainVerifier.verifyAll's table set")
    func orderMatchesVerifyAll() {
        let (db, path) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: path) }
        let perTable = ChainVerifier.verifyAll(db)
        let displayed = Set(Doctor.chainAuditOrder)
        let verified = Set(perTable.keys)
        let missing = verified.subtracting(displayed)
        let stale = displayed.subtracting(verified)
        #expect(displayed == verified,
                "doctor order array must match verifyAll's table set exactly — missing: \(missing); stale: \(stale)")
    }

    @Test("OK summary line names pane_refresh_state")
    func summaryLineNamesPaneRefreshState() {
        let (db, path) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: path) }
        // Write at least one row so earliestStart is non-nil and the
        // formatter takes the OK summary branch (rather than the
        // "fresh DB" skip branch).
        db.recordPaneRefreshState(
            projectRoot: "/tmp/proj-summary", tileId: "budget_burn",
            state: PaneRefreshState(cacheType: .duration, cacheDuration: 30,
                                    retryCount: 0, contentAvailable: true)
        )
        db.flushWrites()
        let perTable = ChainVerifier.verifyAll(db)
        let (lines, anyBroken) = Doctor.formatChainAuditLines(
            perTable: perTable, totalRepairs: 0
        )
        #expect(!anyBroken)
        let summary = lines.last { line in
            if case .pass = line.0 { return true }
            return false
        }
        guard let summary else {
            Issue.record("expected an OK summary line, got: \(lines.map(\.1))")
            return
        }
        #expect(summary.1.contains("pane_refresh_state"),
                "summary line must name pane_refresh_state, got: \(summary.1)")
    }

    @Test("Tampered pane_refresh_state row surfaces a per-table BROKEN line")
    func tamperedPaneRefreshSurfacesBrokenLine() throws {
        let (db, path) = Self.makeDB()
        let projectRoot = "/tmp/proj-doctor-tamper"
        for i in 0..<3 {
            db.recordPaneRefreshState(
                projectRoot: projectRoot, tileId: "budget_burn",
                state: PaneRefreshState(cacheType: .duration, cacheDuration: 30,
                                        retryCount: i, contentAvailable: true)
            )
        }
        db.flushWrites()
        db.close()

        // Tamper with a separate raw connection so the next SessionDatabase
        // open sees the divergence (mirrors PaneRefreshStateStoreTests'
        // tamperFailsVerification fixture).
        var rawDB: OpaquePointer?
        guard sqlite3_open(path, &rawDB) == SQLITE_OK else {
            Issue.record("could not open db for tamper")
            return
        }
        let sql = "UPDATE pane_refresh_state SET notice = 'tampered' WHERE id = 2;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(rawDB, sql, -1, &stmt, nil) == SQLITE_OK else {
            Issue.record("prepare failed")
            sqlite3_close(rawDB)
            return
        }
        #expect(sqlite3_step(stmt) == SQLITE_DONE)
        sqlite3_finalize(stmt)
        sqlite3_close(rawDB)

        let verify = SessionDatabase(path: path)
        defer { TempSessionDatabase.close(verify, path: path) }
        let perTable = ChainVerifier.verifyAll(verify)
        let (lines, anyBroken) = Doctor.formatChainAuditLines(
            perTable: perTable, totalRepairs: 0
        )
        #expect(anyBroken, "tamper should flip anyBroken")

        let brokenLine = lines.first { line in
            if case .fail = line.0,
               line.1.contains("chain integrity (pane_refresh_state): BROKEN") {
                return true
            }
            return false
        }
        guard let brokenLine else {
            Issue.record("expected a `chain integrity (pane_refresh_state): BROKEN at row …` line, got: \(lines.map(\.1))")
            return
        }
        // The walker may surface tamper at the tampered row OR the next
        // row whose prev_hash references the now-divergent entry hash —
        // either is a correct positive detection. (Same convention as
        // PaneRefreshStateStoreTests.tamperFailsVerification.)
        #expect(brokenLine.1.contains("at row 2") || brokenLine.1.contains("at row 3"),
                "expected tamper to surface at row 2 or 3, got: \(brokenLine.1)")
    }
}
