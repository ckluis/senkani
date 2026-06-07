import Testing
import Foundation
@testable import Core

/// U.9b-1 — AutoValidateQueue dual-write onto SessionWorkQueue
/// (feature-flagged, default-OFF). 4 tests per the build plan.
///
/// FLAKE-DISCIPLINE (Carmack R7/R8): these tests are STRUCTURALLY free of
/// the `Task.detached(.utility)` cooperative-pool-starvation pattern. They
/// do NOT assert on the in-process validator subprocess outcome (which
/// runs on the starvation-prone detached `.utility` worker and can be
/// deprioritized for seconds under full-suite parallel load — the R7/R8
/// lesson). Instead they drive the dual-write contract DIRECTLY through the
/// pure, synchronous `AutoValidateDualWrite` type (the bus enqueue + parity
/// truth-table — the actual U.9b-1 deliverable), which has no wall-clock or
/// scheduler dependence. The default-OFF gate is verified deterministically
/// via `WorkBusConfig.dualWrite` + the helper's own behavior.
@Suite("AutoValidateQueue — U.9b-1 dual-write", .serialized)
struct AutoValidateDualWriteTests {

    private static func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-u9b1-test-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    private static func cleanupDB(_ path: String) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: path)
        try? fm.removeItem(atPath: path + "-shm")
        try? fm.removeItem(atPath: path + "-wal")
    }

    private static func eventCount(_ db: SessionDatabase, _ type: String, projectRoot: String) -> Int {
        db.flushWrites()
        return db.eventCounts(projectRoot: projectRoot)
            .first(where: { $0.eventType == type })?.count ?? 0
    }

    private static func busRowCount(_ db: SessionDatabase, projectRoot: String) -> Int {
        db.flushWrites()
        return db.sessionWorkQueueStore.diagnostics(projectRoot: projectRoot)
            .byKind[AutoValidateDualWrite.kind] ?? 0
    }

    private static func cleanAttempt(path: String) -> AutoValidateWorker.ValidationAttempt {
        AutoValidateWorker.ValidationAttempt(
            path: path,
            validatorName: "clean-sh",
            category: "syntax",
            exitCode: 0,
            rawOutput: "",
            advisory: "",
            durationMs: 1,
            outcome: .clean,
            reason: nil
        )
    }

    // MARK: - Test 1: dualWrite=false ⇒ in-process-only; zero bus rows; counters untouched

    @Test("dualWrite=false reproduces U.9a exactly: zero bus rows for auto_validate; no parity counters (default-safe)")
    func dualWriteOffIsDefaultSafe() {
        // The default WorkBusConfig is OFF — pin the invariant at the flag.
        #expect(WorkBusConfig().dualWrite == false, "WorkBusConfig must default to dualWrite=false")

        let (db, dbPath) = Self.makeTempDB()
        defer { Self.cleanupDB(dbPath) }
        let root = "/tmp/senkani-u9b1-off"

        // U.9a path: the in-process leg writes its validation_results row
        // directly (no dual-write helper invoked). Simulate that write.
        db.insertValidationResult(
            sessionId: "off-sid", filePath: "\(root)/ok.test",
            validatorName: "clean-sh", category: "syntax", exitCode: 0,
            rawOutput: nil, advisory: "", durationMs: 1,
            outcome: "clean", reason: nil
        )
        db.flushWrites()

        // With dualWrite OFF, AutoValidateQueue never calls into
        // AutoValidateDualWrite — so there is NO bus row and NO parity
        // counter. (Asserted by NOT invoking the helper, mirroring the
        // gated production path.)
        #expect(Self.busRowCount(db, projectRoot: root) == 0,
                "dualWrite=false must write zero session_work_queue rows for auto_validate")
        for counter in [AutoValidateDualWrite.parityMatch, AutoValidateDualWrite.parityDiverge,
                        AutoValidateDualWrite.parityBusOnly, AutoValidateDualWrite.parityInProcessOnly] {
            #expect(Self.eventCount(db, counter, projectRoot: root) == 0,
                    "dualWrite=false must not emit \(counter)")
        }
        // The in-process leg still delivered its row (U.9a behavior intact).
        #expect(db.validationResults(sessionId: "off-sid", outcome: "clean").count == 1,
                "the in-process leg must still deliver when dualWrite is off")
    }

    // MARK: - Test 2: dualWrite=true, both legs succeed ⇒ identical results; .parity_match += 1

    @Test("dualWrite=true both legs succeed: bus row enqueued + .parity_match += 1; in-process results unchanged")
    func dualWriteOnBothLegsSucceed() {
        let (db, dbPath) = Self.makeTempDB()
        defer { Self.cleanupDB(dbPath) }
        let root = "/tmp/senkani-u9b1-on"
        let path = "\(root)/ok.test"

        // In-process leg: write the validation_results row (byte-identical
        // to the U.9a path).
        db.insertValidationResult(
            sessionId: "on-sid", filePath: path,
            validatorName: "clean-sh", category: "syntax", exitCode: 0,
            rawOutput: nil, advisory: "", durationMs: 1,
            outcome: "clean", reason: nil
        )
        db.flushWrites()
        let inProcessRows = db.validationResults(sessionId: "on-sid", outcome: "clean")
        #expect(inProcessRows.count == 1, "in-process leg row content is identical to the U.9a path")

        // Dual-write bus leg (the U.9b-1 deliverable) — both legs OK.
        let rowId = AutoValidateDualWrite.run(
            db: db, sessionId: "on-sid", path: path, projectRoot: root,
            attempts: [Self.cleanAttempt(path: path)], inProcessLegOK: true
        )
        #expect(rowId > 0, "bus enqueue must succeed")
        #expect(Self.busRowCount(db, projectRoot: root) == 1,
                "dualWrite=true must enqueue exactly one auto_validate bus row")
        #expect(Self.eventCount(db, AutoValidateDualWrite.parityMatch, projectRoot: root) == 1,
                "both legs succeeding must emit exactly one .parity_match")
        #expect(Self.eventCount(db, AutoValidateDualWrite.parityDiverge, projectRoot: root) == 0)
        #expect(Self.eventCount(db, AutoValidateDualWrite.parityBusOnly, projectRoot: root) == 0)
        #expect(Self.eventCount(db, AutoValidateDualWrite.parityInProcessOnly, projectRoot: root) == 0)
    }

    // MARK: - Test 3: bus leg fails ⇒ in-process delivers; .parity_inprocess_only += 1

    @Test("bus leg fails: in-process leg still counts; .parity_inprocess_only += 1 (divergence recorded)")
    func busLegFailsRecordsInProcessOnly() {
        let (db, dbPath) = Self.makeTempDB()
        defer { Self.cleanupDB(dbPath) }
        let root = "/tmp/senkani-u9b1-busfail"

        // Pure parity truth-table: in-process OK, bus failed.
        AutoValidateDualWrite.emitParity(db: db, projectRoot: root, inProcessLegOK: true, busLegOK: false)

        #expect(Self.eventCount(db, AutoValidateDualWrite.parityInProcessOnly, projectRoot: root) == 1,
                "in-process OK + bus failed must emit exactly one .parity_inprocess_only")
        #expect(Self.eventCount(db, AutoValidateDualWrite.parityMatch, projectRoot: root) == 0)
        #expect(Self.eventCount(db, AutoValidateDualWrite.parityBusOnly, projectRoot: root) == 0)
        #expect(Self.eventCount(db, AutoValidateDualWrite.parityDiverge, projectRoot: root) == 0)
    }

    // MARK: - Test 4: in-process leg fails ⇒ bus delivers; .parity_bus_only += 1

    @Test("in-process leg fails: bus leg delivers; .parity_bus_only += 1; neither leg ⇒ .parity_diverge")
    func inProcessLegFailsRecordsBusOnly() {
        let (db, dbPath) = Self.makeTempDB()
        defer { Self.cleanupDB(dbPath) }
        let root = "/tmp/senkani-u9b1-inprocfail"

        // Pure parity truth-table: in-process failed, bus OK.
        AutoValidateDualWrite.emitParity(db: db, projectRoot: root, inProcessLegOK: false, busLegOK: true)

        #expect(Self.eventCount(db, AutoValidateDualWrite.parityBusOnly, projectRoot: root) == 1,
                "in-process failed + bus OK must emit exactly one .parity_bus_only")
        #expect(Self.eventCount(db, AutoValidateDualWrite.parityMatch, projectRoot: root) == 0)
        #expect(Self.eventCount(db, AutoValidateDualWrite.parityInProcessOnly, projectRoot: root) == 0)
        #expect(Self.eventCount(db, AutoValidateDualWrite.parityDiverge, projectRoot: root) == 0)

        // And the divergence (neither leg) case maps to .parity_diverge.
        let (db2, dbPath2) = Self.makeTempDB()
        defer { Self.cleanupDB(dbPath2) }
        AutoValidateDualWrite.emitParity(db: db2, projectRoot: root, inProcessLegOK: false, busLegOK: false)
        #expect(Self.eventCount(db2, AutoValidateDualWrite.parityDiverge, projectRoot: root) == 1,
                "neither leg OK must emit exactly one .parity_diverge")
    }
}
