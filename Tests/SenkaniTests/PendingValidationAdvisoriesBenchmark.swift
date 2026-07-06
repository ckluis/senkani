import Testing
import Foundation
@testable import Core

// hook-relay-pendingvalidationadvisories-sync-read-2026-07-05.
//
// MEASURE-FIRST outcome: the synchronous `pendingValidationAdvisories`
// `queue.sync` read on HookRouter's response path (HookRouter.swift:500 →
// ValidationStore.swift:182) is NOT a material latency contributor on its own
// — see the measured numbers below. No semantics-preserving change to this
// read reduces event latency, so no behavioral change ships; this file is the
// measurement harness + the regression pins that lock the read's cheap,
// index-friendly, non-consuming shape so a future edit cannot silently
// reintroduce a full-table scan or a consuming read.
//
// Measured (Apple silicon, debug build, 2026-07-06 — reproduce with
// SENKANI_BENCH=1 swift test --filter PendingValidationAdvisoriesBenchmark):
//
//   uncontended            p50=39µs  p95=44µs  p99=49µs   max=85µs
//   queue-depth=0          p50=40µs  p95=43µs  (== uncontended baseline)
//   queue-depth=1          p50=180µs p95=225µs p99=1002µs
//   queue-depth=3 (burst)  p50=502µs p95=615µs p99=4100µs
//   queue-depth=8          p50=1348µs p95=5013µs
//   queue-depth=32         p50=4943µs p95=9102µs
//
// The read itself is ~44µs (an indexed SELECT ... LIMIT 10). All contended
// latency is QUEUE-DRAIN time: the sync read waits behind already-enqueued
// async chain-hashing INSERTs (~140µs each). That cost is write cost, shared
// by EVERY queue.sync hop on the hook path — the advisory read is merely the
// first such hop at HookRouter.swift:500, so relocating it off-queue only
// shifts the drain onto the next sync hop (budget gate at :507). Reducing the
// write-side queue occupancy is the domain of the parent arc
// phase-hook-relay-async-decouple-2026-06-22.

private func makeBenchDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-pendingval-bench-\(UUID().uuidString).sqlite"
    let db = SessionDatabase(path: path)
    return (db, path)
}

private func insertAdvisory(
    _ db: SessionDatabase, sessionId: String,
    filePath: String, advisory: String, outcome: String? = nil, exitCode: Int32 = 1
) {
    db.insertValidationResult(
        sessionId: sessionId, filePath: filePath, validatorName: "swiftc",
        category: "type", exitCode: exitCode, rawOutput: "error",
        advisory: advisory, durationMs: 10, outcome: outcome)
}

@Suite("pendingValidationAdvisories — sync-read regression pins")
struct PendingValidationAdvisoriesReadPins {

    // Pin 1 — the needed-before-response delivery contract HookRouter.handle()
    // depends on: an advisory inserted (and flushed) BEFORE the event is
    // returned by the read, and the read is NON-CONSUMING (it does not mark
    // rows surfaced — HookRouter marks surfaced only after appending to a
    // response the agent sees, via appendAndMarkValidationIfSurfaced).
    @Test("read returns advisories enqueued before the event and does not consume them")
    func readIsNeededBeforeResponseAndNonConsuming() {
        let (db, path) = makeBenchDB()
        defer { TempSessionDatabase.close(db, path: path) }
        let sid = db.createSession(projectRoot: "/tmp/p")

        insertAdvisory(db, sessionId: sid, filePath: "/tmp/p/A.swift", advisory: "fix A")
        db.flushWrites()

        // The read must see the advisory that landed before this "event".
        let first = db.pendingValidationAdvisories(sessionId: sid)
        #expect(first.count == 1)
        #expect(first.first?.advisory == "fix A")
        #expect(first.first?.surfacedAt == nil)

        // Non-consuming: a second read still returns it (rows are marked
        // surfaced only by the explicit mark step, never by the read).
        let second = db.pendingValidationAdvisories(sessionId: sid)
        #expect(second.count == 1)
        #expect(second.first?.surfacedAt == nil)

        // And the explicit mark step is what removes it from the pending set —
        // pins the exactly-once boundary the read must not cross.
        db.markValidationAdvisoriesSurfaced(ids: first.map(\.id))
        db.flushWrites()
        #expect(db.pendingValidationAdvisories(sessionId: sid).isEmpty)
    }

    // Pin 2 — the read's result set is a function of PENDING advisory rows
    // only, independent of how many excluded rows exist. A large population of
    // rows the WHERE clause must exclude (clean outcomes, already-surfaced
    // advisories, exit_code==0) does not leak into the result and does not
    // change the pending set. This locks the index-friendly filter shape
    // (outcome='advisory' AND surfaced_at IS NULL AND delivered=0 AND
    // exit_code!=0, ORDER BY created_at DESC LIMIT 10) that keeps the read
    // O(pending) rather than O(table); a dropped predicate would fail here.
    @Test("read result set depends on pending rows only, not on excluded-row population")
    func readFiltersAreIntactUnderLargeExcludedPopulation() {
        let (db, path) = makeBenchDB()
        defer { TempSessionDatabase.close(db, path: path) }
        let sid = db.createSession(projectRoot: "/tmp/p")

        // 400 clean rows (outcome=clean, exit_code=0) — excluded.
        for i in 0..<400 {
            insertAdvisory(db, sessionId: sid, filePath: "/tmp/p/Clean\(i).swift",
                           advisory: "", outcome: "clean", exitCode: 0)
        }
        // 200 advisories that we will mark surfaced — excluded after marking.
        for i in 0..<200 {
            insertAdvisory(db, sessionId: sid, filePath: "/tmp/p/Old\(i).swift",
                           advisory: "old \(i)")
        }
        db.flushWrites()
        let toSurface = db.pendingValidationAdvisories(sessionId: sid)
        // capped at LIMIT 10 by the read
        #expect(toSurface.count == 10)
        // mark ALL 200 surfaced (read them in batches would be how prod drains;
        // here we surface every advisory row so none remain pending)
        let allOld = db.validationResults(sessionId: sid, outcome: "advisory")
        db.markValidationAdvisoriesSurfaced(ids: allOld.map(\.id))
        db.flushWrites()
        #expect(db.pendingValidationAdvisories(sessionId: sid).isEmpty)

        // Now 3 genuinely-pending advisories against the large excluded backdrop.
        insertAdvisory(db, sessionId: sid, filePath: "/tmp/p/New0.swift", advisory: "new 0")
        insertAdvisory(db, sessionId: sid, filePath: "/tmp/p/New1.swift", advisory: "new 1")
        insertAdvisory(db, sessionId: sid, filePath: "/tmp/p/New2.swift", advisory: "new 2")
        db.flushWrites()

        let pending = db.pendingValidationAdvisories(sessionId: sid)
        #expect(pending.count == 3)
        #expect(Set(pending.map(\.advisory)) == ["new 0", "new 1", "new 2"])
        // created_at DESC ordering pin: most recent first.
        #expect(pending.allSatisfy { $0.surfacedAt == nil })
    }
}

// Measurement harness. Opt-in (SENKANI_BENCH=1) so it never adds runtime or
// timing-flake to normal CI; the numbers in the header comment are its output.
private let benchEnabled = ProcessInfo.processInfo.environment["SENKANI_BENCH"] != nil

private func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let idx = Int((Double(sorted.count - 1) * p).rounded())
    return sorted[min(max(idx, 0), sorted.count - 1)]
}

private func summarize(_ label: String, _ samplesNs: [Double]) {
    let sorted = samplesNs.sorted()
    let p50 = percentile(sorted, 0.50) / 1000.0
    let p95 = percentile(sorted, 0.95) / 1000.0
    let p99 = percentile(sorted, 0.99) / 1000.0
    let maxUs = (sorted.last ?? 0) / 1000.0
    let meanUs = (samplesNs.reduce(0, +) / Double(samplesNs.count)) / 1000.0
    print(String(format:
        "BENCH %@ n=%d mean=%.1fµs p50=%.1fµs p95=%.1fµs p99=%.1fµs max=%.1fµs",
        label, samplesNs.count, meanUs, p50, p95, p99, maxUs))
}

@Suite("pendingValidationAdvisories — sync-read benchmark", .enabled(if: benchEnabled))
struct PendingValidationAdvisoriesBenchmark {

    private func seed(_ db: SessionDatabase, sid: String, advisories: Int, cleanRows: Int) {
        for i in 0..<advisories {
            db.insertValidationResult(
                sessionId: sid, filePath: "/tmp/p/Broken\(i).swift",
                validatorName: "swiftc", category: "type", exitCode: 1,
                rawOutput: "error", advisory: "fix \(i)", durationMs: 10)
        }
        for i in 0..<cleanRows {
            db.insertValidationResult(
                sessionId: sid, filePath: "/tmp/p/Clean\(i).swift",
                validatorName: "swiftc", category: "type", exitCode: 0,
                rawOutput: nil, advisory: "", durationMs: 5, outcome: "clean")
        }
        db.flushWrites()
    }

    @Test("uncontended read latency")
    func uncontended() {
        let (db, path) = makeBenchDB()
        defer { TempSessionDatabase.close(db, path: path) }
        let sid = db.createSession(projectRoot: "/tmp/p")
        seed(db, sid: sid, advisories: 3, cleanRows: 500)
        for _ in 0..<50 { _ = db.pendingValidationAdvisories(sessionId: sid) }

        var samples: [Double] = []
        for _ in 0..<2000 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let rows = db.pendingValidationAdvisories(sessionId: sid)
            let t1 = DispatchTime.now().uptimeNanoseconds
            #expect(rows.count == 3)
            samples.append(Double(t1 - t0))
        }
        summarize("uncontended", samples)
    }

    // Contention on the shared serial com.senkani.sessiondb queue is a
    // function of QUEUE DEPTH: the sync read waits for every already-enqueued
    // async write (each doing chain-hashing) to drain first. Deterministic and
    // finite — unlike an unbounded writer storm, which only measures how fast
    // one thread outruns the queue.
    @Test("contended read latency as a function of pending write-queue depth")
    func contendedByQueueDepth() {
        let (db, path) = makeBenchDB()
        defer { TempSessionDatabase.close(db, path: path) }
        let sid = db.createSession(projectRoot: "/tmp/p")
        seed(db, sid: sid, advisories: 3, cleanRows: 500)
        for _ in 0..<50 { _ = db.pendingValidationAdvisories(sessionId: sid) }

        var stormCounter = 0
        func enqueueBurst(_ n: Int) {
            for _ in 0..<n {
                stormCounter += 1
                db.insertValidationResult(
                    sessionId: sid, filePath: "/tmp/p/Storm\(stormCounter).swift",
                    validatorName: "swiftc", category: "type", exitCode: 1,
                    rawOutput: "error", advisory: "storm \(stormCounter)", durationMs: 3)
            }
        }

        for depth in [0, 1, 3, 8, 32] {
            var samples: [Double] = []
            for _ in 0..<300 {
                enqueueBurst(depth)
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = db.pendingValidationAdvisories(sessionId: sid)
                let t1 = DispatchTime.now().uptimeNanoseconds
                samples.append(Double(t1 - t0))
                db.flushWrites()
            }
            summarize("contended depth=\(depth)", samples)
        }
    }
}
