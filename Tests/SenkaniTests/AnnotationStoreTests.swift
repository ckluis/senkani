import Testing
import Foundation
import SQLite3
@testable import Core

// MARK: - Test helpers

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-annotation-test-\(UUID().uuidString).sqlite"
    let db = SessionDatabase(path: path)
    return (db, path)
}

private func cleanupTempDB(_ path: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: path)
    try? fm.removeItem(atPath: path + "-wal")
    try? fm.removeItem(atPath: path + "-shm")
}

private func makeAnnotation(
    targetKind: AnnotationTargetKind = .skill,
    targetId: String = "skill-fixture-1",
    rangeStart: Int = 0,
    rangeEnd: Int = 40,
    verdict: AnnotationVerdict = .works,
    notes: String? = nil,
    authoredBy: String = "operator",
    authorship: AuthorshipTag = .humanAuthored,
    createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> Annotation {
    Annotation(
        targetKind: targetKind,
        targetId: targetId,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
        verdict: verdict,
        notes: notes,
        authoredBy: authoredBy,
        authorship: authorship,
        createdAt: createdAt
    )
}

@Suite("AnnotationStore — V.6 round 1 backend")
struct AnnotationStoreTests {

    // MARK: - Schema

    @Test("Migration v9 creates annotations table with all expected columns")
    func schemaShape() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        #expect(db.currentSchemaVersion() >= 9)

        let cols = db.queue.sync { () -> Set<String> in
            guard let h = db.db else { return [] }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(h, "PRAGMA table_info(annotations);", -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var set: Set<String> = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                set.insert(String(cString: sqlite3_column_text(stmt, 1)))
            }
            return set
        }
        let expected: Set<String> = [
            "id", "target_kind", "target_id", "range_start", "range_end",
            "verdict", "notes", "authored_by", "authorship", "created_at",
            "prev_hash", "entry_hash", "chain_anchor_id",
        ]
        #expect(cols == expected, "table_info columns: \(cols.sorted())")
    }

    // MARK: - Insert + read

    @Test("record() returns a positive rowid and count() bumps")
    func recordReturnsRowid() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        #expect(db.annotationCount() == 0)
        let rowid = db.recordAnnotation(makeAnnotation())
        #expect(rowid > 0)
        #expect(db.annotationCount() == 1)
    }

    @Test("Roundtrip preserves verdict, range, notes, authorship, authoredBy")
    func roundtrip() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        db.recordAnnotation(makeAnnotation(
            targetKind: .kbEntity,
            targetId: "entity-foo",
            rangeStart: 12,
            rangeEnd: 84,
            verdict: .fails,
            notes: "broken on multi-line input",
            authoredBy: "ckluis",
            authorship: .mixed,
            createdAt: Date(timeIntervalSince1970: 1_700_000_500)
        ))
        let rows = db.annotations(kind: .kbEntity, id: "entity-foo")
        #expect(rows.count == 1)
        guard let r = rows.first else { return }
        #expect(r.targetKind == .kbEntity)
        #expect(r.targetId == "entity-foo")
        #expect(r.rangeStart == 12)
        #expect(r.rangeEnd == 84)
        #expect(r.verdict == .fails)
        #expect(r.notes == "broken on multi-line input")
        #expect(r.authoredBy == "ckluis")
        #expect(r.authorship == .mixed)
        #expect(r.createdAt.timeIntervalSince1970 == 1_700_000_500)
    }

    @Test("byTarget filters to the requested target only")
    func byTargetFilters() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        db.recordAnnotation(makeAnnotation(targetId: "a"))
        db.recordAnnotation(makeAnnotation(targetId: "a", verdict: .fails))
        db.recordAnnotation(makeAnnotation(targetId: "b"))
        db.recordAnnotation(makeAnnotation(targetKind: .kbEntity, targetId: "a"))

        let aRows = db.annotations(kind: .skill, id: "a")
        #expect(aRows.count == 2)
        #expect(aRows.allSatisfy { $0.targetKind == .skill && $0.targetId == "a" })

        let unknown = db.annotations(kind: .skill, id: "does-not-exist")
        #expect(unknown.isEmpty)
    }

    @Test("recent() orders newest-first and respects limit")
    func recentOrderAndLimit() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        for i in 0..<10 {
            db.recordAnnotation(makeAnnotation(
                targetId: "skill-\(i)",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
            ))
        }

        let top3 = db.recentAnnotations(limit: 3)
        #expect(top3.count == 3)
        #expect(top3.map { $0.targetId } == ["skill-9", "skill-8", "skill-7"])
    }

    // MARK: - Rename survival (Torres acceptance)

    @Test("renameAnnotationTarget rewrites target_id and preserves all rows")
    func renameSurvival() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        for v in [AnnotationVerdict.works, .fails, .note] {
            db.recordAnnotation(makeAnnotation(targetId: "old-skill", verdict: v))
        }
        // A different skill — must not move.
        db.recordAnnotation(makeAnnotation(targetId: "other-skill"))

        let moved = db.renameAnnotationTarget(kind: .skill, from: "old-skill", to: "new-skill")
        #expect(moved == 3)

        // Old id is empty, new id has all three rows, count unchanged.
        #expect(db.annotations(kind: .skill, id: "old-skill").isEmpty)
        #expect(db.annotations(kind: .skill, id: "new-skill").count == 3)
        #expect(db.annotations(kind: .skill, id: "other-skill").count == 1)
        #expect(db.annotationCount() == 4)
    }

    @Test("renameAnnotationTarget does not cross target_kind boundaries")
    func renameRespectsKind() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        db.recordAnnotation(makeAnnotation(targetKind: .skill, targetId: "shared-id"))
        db.recordAnnotation(makeAnnotation(targetKind: .kbEntity, targetId: "shared-id"))

        let moved = db.renameAnnotationTarget(kind: .skill, from: "shared-id", to: "renamed")
        #expect(moved == 1)
        #expect(db.annotations(kind: .skill, id: "renamed").count == 1)
        #expect(db.annotations(kind: .kbEntity, id: "shared-id").count == 1)
    }

    // MARK: - Verdict rollup

    @Test("verdictRollup buckets works/fails/note per (kind, id)")
    func verdictRollupBuckets() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        for _ in 0..<3 { db.recordAnnotation(makeAnnotation(targetId: "a", verdict: .works)) }
        for _ in 0..<5 { db.recordAnnotation(makeAnnotation(targetId: "a", verdict: .fails)) }
        for _ in 0..<2 { db.recordAnnotation(makeAnnotation(targetId: "a", verdict: .note)) }
        for _ in 0..<4 { db.recordAnnotation(makeAnnotation(targetId: "b", verdict: .works)) }

        let rollup = db.annotationVerdictRollup()
        let a = rollup.first { $0.targetId == "a" }
        let b = rollup.first { $0.targetId == "b" }
        #expect(a?.worksCount == 3)
        #expect(a?.failsCount == 5)
        #expect(a?.noteCount == 2)
        #expect(a?.totalCount == 10)
        #expect(b?.worksCount == 4)
        #expect(b?.failsCount == 0)
    }

    @Test("verdictRollup filters by targetKind when provided")
    func verdictRollupFiltersByKind() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        db.recordAnnotation(makeAnnotation(targetKind: .skill, targetId: "s"))
        db.recordAnnotation(makeAnnotation(targetKind: .kbEntity, targetId: "k"))
        db.recordAnnotation(makeAnnotation(targetKind: .kbEntity, targetId: "k", verdict: .fails))

        let kbOnly = db.annotationVerdictRollup(targetKind: .kbEntity)
        #expect(kbOnly.count == 1)
        #expect(kbOnly.first?.targetId == "k")
        #expect(kbOnly.first?.totalCount == 2)
    }

    // MARK: - Authorship invariant (V.5 contract)

    @Test("Authorship .unset round-trips — never silently rewritten")
    func authorshipUnsetRoundtrips() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        db.recordAnnotation(makeAnnotation(authorship: .unset))
        let rows = db.recentAnnotations(limit: 1)
        #expect(rows.first?.authorship == .unset)
    }

    // MARK: - Acceptance: 100 annotations flow into Analyze

    @Test("100 fixture annotations roll up into AnnotationSignalGenerator.analyze evidence")
    func hundredAnnotationsFlowIntoAnalyze() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        // 100 annotations spread across 5 targets:
        //   skill-A: 30 fails  → failing
        //   skill-B: 25 works  → working
        //   skill-C: 10 works + 10 fails → mixed
        //   kb-D:    15 notes  → mixed
        //   kb-E:    10 works  → working
        var t = 1_700_000_000.0
        func addBatch(_ count: Int, kind: AnnotationTargetKind, id: String, verdict: AnnotationVerdict) {
            for _ in 0..<count {
                db.recordAnnotation(makeAnnotation(
                    targetKind: kind, targetId: id, verdict: verdict,
                    createdAt: Date(timeIntervalSince1970: t)
                ))
                t += 1
            }
        }
        addBatch(30, kind: .skill,    id: "A", verdict: .fails)
        addBatch(25, kind: .skill,    id: "B", verdict: .works)
        addBatch(10, kind: .skill,    id: "C", verdict: .works)
        addBatch(10, kind: .skill,    id: "C", verdict: .fails)
        addBatch(15, kind: .kbEntity, id: "D", verdict: .note)
        addBatch(10, kind: .kbEntity, id: "E", verdict: .works)

        #expect(db.annotationCount() == 100)

        let evidence = AnnotationSignalGenerator.analyze(db: db)
        #expect(evidence.count == 5)

        let total = evidence.reduce(0) { $0 + $1.totalCount }
        #expect(total == 100, "every fixture annotation accounted for in evidence rollup")

        let a = evidence.first { $0.targetId == "A" }
        let b = evidence.first { $0.targetId == "B" }
        let c = evidence.first { $0.targetId == "C" }
        let d = evidence.first { $0.targetId == "D" }
        let e = evidence.first { $0.targetId == "E" }
        #expect(a?.signalKind == .failing)
        #expect(b?.signalKind == .working)
        #expect(c?.signalKind == .mixed)
        #expect(d?.signalKind == .mixed)
        #expect(e?.signalKind == .working)
    }

    @Test("runAnnotationSignalDetection bumps observed + signalKind counters")
    func runAnnotationSignalDetectionBumpsCounters() {
        let (db, path) = makeTempDB()
        defer { cleanupTempDB(path) }

        db.recordAnnotation(makeAnnotation(targetId: "fail-skill", verdict: .fails))
        db.recordAnnotation(makeAnnotation(targetId: "fail-skill", verdict: .fails))
        db.recordAnnotation(makeAnnotation(targetId: "ok-skill",   verdict: .works))

        let evidence = CompoundLearning.runAnnotationSignalDetection(
            projectRoot: "/tmp/v6-fixture",
            db: db
        )
        #expect(evidence.count == 2)

        // recordEvent enqueues onto the SessionDatabase serial queue; any
        // subsequent eventCounts(...).sync drains everything queued before it.
        let observed = db.eventCounts(
            projectRoot: "/tmp/v6-fixture",
            prefix: "compound_learning.annotation.observed"
        ).reduce(0) { $0 + $1.count }
        let failing = db.eventCounts(
            projectRoot: "/tmp/v6-fixture",
            prefix: "compound_learning.annotation.failing"
        ).reduce(0) { $0 + $1.count }
        let working = db.eventCounts(
            projectRoot: "/tmp/v6-fixture",
            prefix: "compound_learning.annotation.working"
        ).reduce(0) { $0 + $1.count }

        #expect(observed == 2)
        #expect(failing == 1)
        #expect(working == 1)
    }
}
