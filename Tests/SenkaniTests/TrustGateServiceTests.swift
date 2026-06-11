import Testing
import Foundation
@testable import Core

/// U.4b-2a — headless `TrustGateService` behind the U.4b-2 GUI
/// surfaces. 4 tests via `SessionDatabase(path:)` + temp settings
/// paths: gated promotion accept (+ idempotent noop), gate rejection
/// leaves state untouched, demotion always allowed, override
/// idempotency. Chain integrity asserted after every write path.
@Suite("U.4b-2a — TrustGateService headless flip + override")
struct TrustGateServiceTests {

    private func tempSettingsPath() -> String {
        return "/tmp/senkani-trustgate-\(UUID().uuidString).json"
    }

    private func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-trustgate-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    /// Seed `count` flags each carrying one latest label so the 30-day
    /// stats window observes a labeled sample. Returns the last rowid.
    @discardableResult
    private func seedLabeledFlags(_ db: SessionDatabase, count: Int, label: TrustLabel) -> Int64 {
        var last: Int64 = -1
        for i in 0..<count {
            let flag = FragmentationDetector.Flag(
                createdAt: Date(),
                sessionId: "sid-u4b2a-\(i)",
                paneId: nil,
                toolName: "Edit",
                reason: .toolBurst,
                correlationCount: 3
            )
            let flagId = db.recordTrustFlag(flag, score: 5)
            #expect(flagId > 0)
            last = db.recordTrustLabel(flagId: flagId, label: label, labeledBy: "operator")
            #expect(last > flagId)
        }
        return last
    }

    private func expectChainOK(_ db: SessionDatabase, _ context: String) {
        let result = ChainVerifier.verifyTrustAudits(db)
        if case .brokenAt(let table, let rowid, let expected, let actual) = result {
            Issue.record("\(context): chain broken at \(table):\(rowid) expected=\(expected) actual=\(actual)")
        }
    }

    // MARK: - 1. Promotion accepted + idempotent noop

    @Test("flip(.blocking) passes the gate, records a chained promotion row, persists settings; second flip is a row-free noop")
    func promotionAcceptedThenIdempotentNoop() throws {
        let (db, dbPath) = makeTempDB()
        let settingsPath = tempSettingsPath()
        defer {
            TempSessionDatabase.cleanup(path: dbPath)
            try? FileManager.default.removeItem(atPath: settingsPath)
        }

        // 2 TP labels → observed rate 0.0, sample 2. Thresholds met.
        let lastSeedRow = seedLabeledFlags(db, count: 2, label: .tp)
        try TrustSettingsStore.save(
            TrustSettings(mode: .softFlag, fpRateMax: 0.5, minLabeledSample: 2),
            path: settingsPath
        )
        let service = TrustGateService(database: db, settingsPath: settingsPath)
        #expect(try service.currentMode() == .softFlag)

        let result = try service.flip(to: .blocking, by: "operator")
        guard case .flipped(let from, let to, let rowid, let observedRate, let observedSample) = result else {
            Issue.record("expected .flipped, got \(result)")
            return
        }
        #expect(from == .softFlag)
        #expect(to == .blocking)
        #expect(rowid == lastSeedRow + 1, "promotion row should be the next trust_audits rowid")
        #expect(observedRate == 0.0)
        #expect(observedSample == 2)

        // Settings persisted through the gate, not around it.
        #expect(try TrustSettingsStore.load(path: settingsPath).mode == .blocking)
        #expect(try service.currentMode() == .blocking)

        // Idempotent: flipping to the current mode writes nothing.
        let again = try service.flip(to: .blocking, by: "operator")
        #expect(again == .noop(mode: .blocking))
        // Next write lands at rowid+1 — proves the noop wrote no row.
        let probe = service.recordOverride(callId: "probe-noop", by: "operator")
        #expect(probe == .recorded(rowid: rowid + 1))

        db.flushWrites()
        expectChainOK(db, "after accepted promotion + override probe")
    }

    // MARK: - 2. Promotion rejected leaves state untouched

    @Test("flip(.blocking) with unset thresholds is rejected; settings unchanged and no audit row written")
    func promotionRejectedLeavesStateUntouched() throws {
        let (db, dbPath) = makeTempDB()
        let settingsPath = tempSettingsPath()
        defer {
            TempSessionDatabase.cleanup(path: dbPath)
            try? FileManager.default.removeItem(atPath: settingsPath)
        }

        // No thresholds configured (no-defaults invariant, Q4 verdict).
        let service = TrustGateService(database: db, settingsPath: settingsPath)
        let result = try service.flip(to: .blocking, by: "operator")
        guard case .rejected(let reason) = result else {
            Issue.record("expected .rejected, got \(result)")
            return
        }
        #expect(reason.contains("configure threshold first"))

        // Mode stays .softFlag; missing settings file untouched.
        #expect(try service.currentMode() == .softFlag)
        #expect(!FileManager.default.fileExists(atPath: settingsPath),
                "rejected flip must not create/write the settings file")

        // No promotion row: the first real write lands at rowid 1.
        let probe = service.recordOverride(callId: "probe-rejected", by: "operator")
        #expect(probe == .recorded(rowid: 1))

        db.flushWrites()
        expectChainOK(db, "after rejected promotion + override probe")
    }

    // MARK: - 3. Demotion always allowed

    @Test("flip(.softFlag) from .blocking always succeeds without thresholds and records the witness row")
    func demotionAlwaysAllowed() throws {
        let (db, dbPath) = makeTempDB()
        let settingsPath = tempSettingsPath()
        defer {
            TempSessionDatabase.cleanup(path: dbPath)
            try? FileManager.default.removeItem(atPath: settingsPath)
        }

        // Start in .blocking with NO thresholds — demotion needs none.
        try TrustSettingsStore.save(TrustSettings(mode: .blocking), path: settingsPath)
        let service = TrustGateService(database: db, settingsPath: settingsPath)

        let result = try service.flip(to: .softFlag, by: "operator")
        guard case .flipped(let from, let to, let rowid, let observedRate, let observedSample) = result else {
            Issue.record("expected .flipped, got \(result)")
            return
        }
        #expect(from == .blocking)
        #expect(to == .softFlag)
        #expect(rowid == 1, "demotion witness row is the first trust_audits row")
        #expect(observedRate == nil)
        #expect(observedSample == 0)
        #expect(try service.currentMode() == .softFlag)

        db.flushWrites()
        expectChainOK(db, "after demotion")
    }

    // MARK: - 4. Override idempotency

    @Test("recordOverride writes one chained row per callId; repeat callId returns .alreadyRecorded without a duplicate")
    func overrideIdempotency() throws {
        let (db, dbPath) = makeTempDB()
        let settingsPath = tempSettingsPath()
        defer {
            TempSessionDatabase.cleanup(path: dbPath)
            try? FileManager.default.removeItem(atPath: settingsPath)
        }

        let service = TrustGateService(database: db, settingsPath: settingsPath)
        let callId = "session-1:Edit:1234567890"

        let first = service.recordOverride(callId: callId, by: "operator", justification: "false alarm")
        guard case .recorded(let rowid) = first else {
            Issue.record("expected .recorded, got \(first)")
            return
        }
        #expect(rowid > 0)
        #expect(db.trustOverrideExists(callId: callId))

        // Idempotent repeat: no duplicate row.
        let repeated = service.recordOverride(callId: callId, by: "operator", justification: "duplicate click")
        #expect(repeated == .alreadyRecorded)

        // A different callId lands at exactly rowid+1 — proves the
        // repeat wrote nothing in between.
        let second = service.recordOverride(callId: "session-2:Edit:1234567999", by: "operator")
        #expect(second == .recorded(rowid: rowid + 1))

        db.flushWrites()
        expectChainOK(db, "after override sequence")
    }
}
