import Testing
import Foundation
@testable import Core

// MARK: - Helpers

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-schedule-telemetry-\(UUID().uuidString)/senkani.db"
    let db = SessionDatabase(path: path)
    return (db, path)
}

private func cleanupDB(path: String) {
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.removeItem(atPath: dir)
}

/// recordTokenEvent writes asynchronously on the SessionDatabase queue.
/// Give it a beat before reading back.
private let writeFlushDelay: TimeInterval = 0.05

@Suite("ScheduleTelemetry — event shape")
struct ScheduleTelemetryShapeTests {

    @Test func recordStartEmitsStartEvent() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path: path) }

        let root = "/tmp/proj-\(UUID().uuidString)"
        ScheduleTelemetry.withTestDatabase(db) {
            ScheduleTelemetry.recordStart(
                projectRoot: root,
                taskName: "nightly",
                command: "echo hi",
                runId: "20260418120000-abcdef"
            )
        }
        Thread.sleep(forTimeInterval: writeFlushDelay)

        let events = db.recentTokenEvents(projectRoot: root, limit: 10)
        #expect(events.count == 1)
        let e = events[0]
        #expect(e.source == ScheduleTelemetry.source)
        #expect(e.source == "schedule")
        #expect(e.feature == ScheduleTelemetry.featureStart)
        #expect(e.toolName == nil)
        #expect(e.command == "nightly: echo hi")
        #expect(e.inputTokens == 0)
        #expect(e.outputTokens == 0)
        #expect(e.savedTokens == 0)
        #expect(e.costCents == 0)
    }

    @Test func recordEndSuccessEncodesResult() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path: path) }

        let root = "/tmp/proj-\(UUID().uuidString)"
        ScheduleTelemetry.withTestDatabase(db) {
            ScheduleTelemetry.recordEnd(
                projectRoot: root,
                taskName: "nightly",
                runId: "20260418120000-abcdef",
                exitCode: 0
            )
        }
        Thread.sleep(forTimeInterval: writeFlushDelay)

        let events = db.recentTokenEvents(projectRoot: root, limit: 10)
        #expect(events.count == 1)
        let e = events[0]
        #expect(e.feature == "schedule_end")
        #expect(e.command == "nightly: success")
    }

    @Test func recordEndFailedEncodesExitCode() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path: path) }

        let root = "/tmp/proj-\(UUID().uuidString)"
        ScheduleTelemetry.withTestDatabase(db) {
            ScheduleTelemetry.recordEnd(
                projectRoot: root,
                taskName: "backup",
                runId: "20260418120000-abcdef",
                exitCode: 7
            )
        }
        Thread.sleep(forTimeInterval: writeFlushDelay)

        let events = db.recentTokenEvents(projectRoot: root, limit: 10)
        #expect(events.count == 1)
        let e = events[0]
        #expect(e.feature == "schedule_end")
        #expect(e.command == "backup: failed: exit 7")
        #expect(e.command?.contains("exit 7") == true)
    }

    @Test func recordBlockedEncodesReasonVerbatim() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path: path) }

        let root = "/tmp/proj-\(UUID().uuidString)"
        let reason = "Daily budget exceeded: $10.00 / $10.00"
        ScheduleTelemetry.withTestDatabase(db) {
            ScheduleTelemetry.recordBlocked(
                projectRoot: root,
                taskName: "eval",
                runId: "20260418120000-abcdef",
                reason: reason
            )
        }
        Thread.sleep(forTimeInterval: writeFlushDelay)

        let events = db.recentTokenEvents(projectRoot: root, limit: 10)
        #expect(events.count == 1)
        let e = events[0]
        #expect(e.feature == "schedule_blocked")
        #expect(e.command == "eval: budget_exceeded (\(reason))")
    }

    @Test func startEndPairShareSessionId() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path: path) }

        let root = "/tmp/proj-\(UUID().uuidString)"
        let runId = "20260418120000-paired"
        ScheduleTelemetry.withTestDatabase(db) {
            ScheduleTelemetry.recordStart(
                projectRoot: root,
                taskName: "nightly",
                command: "echo hi",
                runId: runId
            )
            ScheduleTelemetry.recordEnd(
                projectRoot: root,
                taskName: "nightly",
                runId: runId,
                exitCode: 0
            )
        }
        Thread.sleep(forTimeInterval: writeFlushDelay)

        let events = db.recentTokenEvents(projectRoot: root, limit: 10)
        #expect(events.count == 2)
        // Pair verification: look up sessions directly in token_events via
        // a raw read. TimelineEvent doesn't expose session_id, so assert
        // the helper produces a stable id.
        let expectedId = "schedule:nightly:\(runId)"
        #expect(ScheduleTelemetry.sessionId(taskName: "nightly", runId: runId) == expectedId)

        // Order assertion: newest-first, so end comes before start.
        #expect(events[0].feature == "schedule_end")
        #expect(events[1].feature == "schedule_start")
        #expect(events[0].timestamp >= events[1].timestamp)
    }

    @Test func eventsFilterByProjectRoot() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path: path) }

        let rootA = "/tmp/proj-A-\(UUID().uuidString)"
        let rootB = "/tmp/proj-B-\(UUID().uuidString)"
        ScheduleTelemetry.withTestDatabase(db) {
            ScheduleTelemetry.recordStart(
                projectRoot: rootA, taskName: "a", command: "x", runId: "r1"
            )
            ScheduleTelemetry.recordStart(
                projectRoot: rootB, taskName: "b", command: "y", runId: "r2"
            )
        }
        Thread.sleep(forTimeInterval: writeFlushDelay)

        let eventsA = db.recentTokenEvents(projectRoot: rootA, limit: 10)
        let eventsB = db.recentTokenEvents(projectRoot: rootB, limit: 10)
        #expect(eventsA.count == 1)
        #expect(eventsA[0].command == "a: x")
        #expect(eventsB.count == 1)
        #expect(eventsB[0].command == "b: y")
    }

    @Test func makeRunIdMatchesExpectedShape() {
        let id = ScheduleTelemetry.makeRunId()
        // Format: yyyyMMddHHmmss-<6 lowercase-alnum>
        #expect(id.count == 21, "got \(id.count): \(id)")
        let parts = id.split(separator: "-", maxSplits: 1).map(String.init)
        #expect(parts.count == 2)
        #expect(parts[0].count == 14)
        #expect(parts[0].allSatisfy { $0.isNumber })
        #expect(parts[1].count == 6)
        let alpha = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        #expect(parts[1].allSatisfy { alpha.contains($0) })
    }

    @Test func blockedEventEmittedWithoutStartOrEndPair() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path: path) }

        let root = "/tmp/proj-\(UUID().uuidString)"
        ScheduleTelemetry.withTestDatabase(db) {
            ScheduleTelemetry.recordBlocked(
                projectRoot: root,
                taskName: "eval",
                runId: "r-blocked",
                reason: "Daily budget exceeded"
            )
        }
        Thread.sleep(forTimeInterval: writeFlushDelay)

        let events = db.recentTokenEvents(projectRoot: root, limit: 10)
        #expect(events.count == 1)
        #expect(events[0].feature == "schedule_blocked")
        // Blocked runs should not emit a schedule_start or schedule_end
        // alongside — the blocked event is the only record.
        #expect(!events.contains { $0.feature == "schedule_start" })
        #expect(!events.contains { $0.feature == "schedule_end" })
    }
}
