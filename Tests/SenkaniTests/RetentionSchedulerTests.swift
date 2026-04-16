import Testing
import Foundation
@testable import Core

/// P1-6: retention scheduler. These tests exercise the configuration surface
/// directly. Tick-behavior is covered by an explicit `tickNow(...)` call that
/// does NOT require waiting for DispatchSourceTimer to fire, so tests stay fast.
@Suite("RetentionScheduler")
struct RetentionSchedulerTests {

    @Test func defaultsMatchPlan() {
        let c = RetentionConfig()
        #expect(c.tokenEventsDays == 90)
        #expect(c.sandboxResultsHours == 24)
        #expect(c.validationResultsHours == 24)
        #expect(c.tickIntervalSeconds == 3600)
    }

    @Test func loadFromProjectConfig() throws {
        let tmp = NSTemporaryDirectory() + "senkani-retention-test-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let senkaniDir = tmp + ".senkani/"
        try FileManager.default.createDirectory(atPath: senkaniDir, withIntermediateDirectories: true)

        let configJSON = """
        {
          "retention": {
            "token_events_days": 7,
            "sandbox_results_hours": 12,
            "validation_results_hours": 1,
            "tick_interval_seconds": 300
          }
        }
        """
        try configJSON.write(toFile: senkaniDir + "config.json", atomically: true, encoding: .utf8)

        let c = RetentionConfig.load(projectRoot: String(tmp.dropLast()))
        #expect(c.tokenEventsDays == 7)
        #expect(c.sandboxResultsHours == 12)
        #expect(c.validationResultsHours == 1)
        #expect(c.tickIntervalSeconds == 300)
    }

    @Test func missingConfigFallsBackToDefaults() {
        let c = RetentionConfig.load(projectRoot: "/tmp/nonexistent-\(UUID().uuidString)")
        #expect(c.tokenEventsDays == 90)
    }

    @Test func partialConfigMergesWithDefaults() throws {
        let tmp = NSTemporaryDirectory() + "senkani-retention-test-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmp + ".senkani/", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // Only override one field.
        let configJSON = #"{ "retention": { "token_events_days": 30 } }"#
        try configJSON.write(toFile: tmp + ".senkani/config.json", atomically: true, encoding: .utf8)

        let c = RetentionConfig.load(projectRoot: String(tmp.dropLast()))
        #expect(c.tokenEventsDays == 30)
        #expect(c.sandboxResultsHours == 24, "unspecified field must keep default")
    }

    @Test func startStopIsIdempotent() {
        let scheduler = RetentionScheduler()
        // Use a fast tick so we don't block the test, and immediately stop.
        scheduler.start(config: RetentionConfig(tickIntervalSeconds: 3600))
        scheduler.start(config: RetentionConfig(tickIntervalSeconds: 3600)) // second start is no-op
        scheduler.stop()
        scheduler.stop() // second stop is no-op
    }

    /// Thread-safe capture box so the @Sendable callback can append from any queue.
    final class ReportBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [RetentionScheduler.TickReport] = []
        func append(_ r: RetentionScheduler.TickReport) {
            lock.lock(); items.append(r); lock.unlock()
        }
        func snapshot() -> [RetentionScheduler.TickReport] {
            lock.lock(); defer { lock.unlock() }
            return items
        }
    }

    @Test func tickNowInvokesOnTickCallback() {
        let scheduler = RetentionScheduler()
        let box = ReportBox()
        scheduler.onTick = { report in box.append(report) }
        scheduler.tickNow(config: RetentionConfig(
            tokenEventsDays: 30,
            sandboxResultsHours: 6,
            validationResultsHours: 3,
            tickIntervalSeconds: 3600
        ))
        let reports = box.snapshot()
        #expect(reports.count == 1)
        #expect(reports.first?.tokenEventsDays == 30)
        #expect(reports.first?.sandboxResultsHours == 6)
        #expect(reports.first?.validationResultsHours == 3)
    }
}
