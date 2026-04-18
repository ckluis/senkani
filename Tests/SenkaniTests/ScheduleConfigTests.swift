import Testing
import Foundation
@testable import Core

@Suite("ScheduleConfig") struct ScheduleConfigTests {

    // MARK: - CronToLaunchd.convert

    @Test func convertRejectsWrongFieldCount() {
        #expect(CronToLaunchd.convert("* * * *") == nil)
        #expect(CronToLaunchd.convert("* * * * * *") == nil)
        #expect(CronToLaunchd.convert("") == nil)
    }

    @Test func convertAllAsterisksReturnsBlankDict() {
        let result = CronToLaunchd.convert("* * * * *")
        #expect(result?.count == 1)
        #expect(result?.first?.isEmpty == true)
    }

    @Test func convertSingleValue() {
        let result = CronToLaunchd.convert("0 9 * * *")
        #expect(result?.count == 1)
        #expect(result?[0]["Minute"] == 0)
        #expect(result?[0]["Hour"] == 9)
        // Asterisk fields must not appear as keys
        #expect(result?[0]["Day"] == nil)
        #expect(result?[0]["Month"] == nil)
        #expect(result?[0]["Weekday"] == nil)
    }

    @Test func convertEveryNSyntax() {
        let result = CronToLaunchd.convert("*/15 * * * *")
        // 0, 15, 30, 45 — four launchd intervals
        #expect(result?.count == 4)
        let minutes = Set(result?.compactMap { $0["Minute"] } ?? [])
        #expect(minutes == [0, 15, 30, 45])
    }

    @Test func convertCommaList() {
        let result = CronToLaunchd.convert("0 9,17 * * *")
        #expect(result?.count == 2)
        let hours = Set(result?.compactMap { $0["Hour"] } ?? [])
        #expect(hours == [9, 17])
        // Minute pinned on both
        #expect(result?.allSatisfy { $0["Minute"] == 0 } == true)
    }

    @Test func convertRejectsOutOfRange() {
        #expect(CronToLaunchd.convert("60 * * * *") == nil)     // minute ≤ 59
        #expect(CronToLaunchd.convert("* 24 * * *") == nil)     // hour ≤ 23
        #expect(CronToLaunchd.convert("* * 32 * *") == nil)     // day ≤ 31
        #expect(CronToLaunchd.convert("* * * 13 *") == nil)     // month ≤ 12
        #expect(CronToLaunchd.convert("* * * * 7") == nil)      // weekday ≤ 6
        #expect(CronToLaunchd.convert("* * 0 * *") == nil)      // day ≥ 1
    }

    @Test func convertRejectsNonIntegerField() {
        #expect(CronToLaunchd.convert("abc * * * *") == nil)
        #expect(CronToLaunchd.convert("*/abc * * * *") == nil)
        #expect(CronToLaunchd.convert("*/0 * * * *") == nil)    // divisor must be > 0
    }

    @Test func convertCartesianProduct() {
        let result = CronToLaunchd.convert("0 9,12 * * 1,3")
        // 1 minute × 2 hours × 2 weekdays = 4 combinations
        #expect(result?.count == 4)
        let pairs = Set((result ?? []).compactMap { dict -> String? in
            guard let h = dict["Hour"], let w = dict["Weekday"] else { return nil }
            return "\(h)-\(w)"
        })
        #expect(pairs == ["9-1", "9-3", "12-1", "12-3"])
    }

    // MARK: - CronToLaunchd.humanReadable

    @Test func humanReadableEveryMinute() {
        #expect(CronToLaunchd.humanReadable("* * * * *") == "Every minute")
    }

    @Test func humanReadableEveryNMinutes() {
        #expect(CronToLaunchd.humanReadable("*/5 * * * *") == "Every 5 minutes")
        #expect(CronToLaunchd.humanReadable("*/30 * * * *") == "Every 30 minutes")
    }

    @Test func humanReadableDailyAt() {
        #expect(CronToLaunchd.humanReadable("0 9 * * *") == "Daily at 9:00 AM")
        #expect(CronToLaunchd.humanReadable("30 14 * * *") == "Daily at 2:30 PM")
        #expect(CronToLaunchd.humanReadable("0 0 * * *") == "Daily at 12:00 AM")
        #expect(CronToLaunchd.humanReadable("0 12 * * *") == "Daily at 12:00 PM")
    }

    @Test func humanReadableWeekly() {
        #expect(CronToLaunchd.humanReadable("0 9 * * 1") == "Every Mon at 9:00 AM")
        #expect(CronToLaunchd.humanReadable("0 17 * * 5") == "Every Fri at 5:00 PM")
    }

    @Test func humanReadableFallbackToRawCron() {
        // Day-of-month specific cron has no canned phrasing — returns raw.
        let raw = "0 0 15 * *"
        #expect(CronToLaunchd.humanReadable(raw) == raw)
        // Wrong field count also falls through
        #expect(CronToLaunchd.humanReadable("only four fields *") == "only four fields *")
    }

    // MARK: - ScheduleStore CRUD (hermetic via withTestDirs)

    @Test func scheduleStoreSaveLoadRoundtrip() throws {
        let tmp = NSTemporaryDirectory() + "senkani-sched-\(UUID().uuidString)"
        let launch = NSTemporaryDirectory() + "senkani-launch-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: tmp)
            try? FileManager.default.removeItem(atPath: launch)
        }

        try ScheduleStore.withTestDirs(base: tmp, launchAgents: launch) {
            let task = ScheduledTask(
                name: "nightly-index",
                cronPattern: "0 2 * * *",
                command: "senkani index",
                budgetLimitCents: 500,
                enabled: true,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                lastRunAt: nil,
                lastRunResult: nil
            )
            try ScheduleStore.save(task)

            let loaded = try #require(ScheduleStore.load("nightly-index"))
            #expect(loaded.name == "nightly-index")
            #expect(loaded.cronPattern == "0 2 * * *")
            #expect(loaded.command == "senkani index")
            #expect(loaded.budgetLimitCents == 500)
            #expect(loaded.enabled == true)
            #expect(loaded.createdAt.timeIntervalSince1970 == 1_700_000_000)
            #expect(loaded.lastRunAt == nil)
            #expect(loaded.lastRunResult == nil)
        }
    }

    @Test func scheduleStoreListSortsByCreatedAt() throws {
        let tmp = NSTemporaryDirectory() + "senkani-sched-\(UUID().uuidString)"
        let launch = NSTemporaryDirectory() + "senkani-launch-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: tmp)
            try? FileManager.default.removeItem(atPath: launch)
        }

        try ScheduleStore.withTestDirs(base: tmp, launchAgents: launch) {
            // Save in reverse creation order — list must sort ascending.
            let third = ScheduledTask(name: "c-third", cronPattern: "0 3 * * *", command: "c",
                                      createdAt: Date(timeIntervalSince1970: 3_000))
            let first = ScheduledTask(name: "a-first", cronPattern: "0 1 * * *", command: "a",
                                      createdAt: Date(timeIntervalSince1970: 1_000))
            let second = ScheduledTask(name: "b-second", cronPattern: "0 2 * * *", command: "b",
                                       createdAt: Date(timeIntervalSince1970: 2_000))
            try ScheduleStore.save(third)
            try ScheduleStore.save(first)
            try ScheduleStore.save(second)

            let listed = ScheduleStore.list()
            #expect(listed.map(\.name) == ["a-first", "b-second", "c-third"])
        }
    }

    @Test func scheduleStoreLoadMissingReturnsNil() throws {
        let tmp = NSTemporaryDirectory() + "senkani-sched-\(UUID().uuidString)"
        let launch = NSTemporaryDirectory() + "senkani-launch-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: tmp)
            try? FileManager.default.removeItem(atPath: launch)
        }

        ScheduleStore.withTestDirs(base: tmp, launchAgents: launch) {
            #expect(ScheduleStore.load("never-existed") == nil)
            // List over a non-existent dir should be an empty array, not throw.
            #expect(ScheduleStore.list().isEmpty)
        }
    }

    @Test func scheduleStoreRemoveDeletesJSONAndPlist() throws {
        let tmp = NSTemporaryDirectory() + "senkani-sched-\(UUID().uuidString)"
        let launch = NSTemporaryDirectory() + "senkani-launch-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: tmp)
            try? FileManager.default.removeItem(atPath: launch)
        }

        try ScheduleStore.withTestDirs(base: tmp, launchAgents: launch) {
            let task = ScheduledTask(name: "to-remove", cronPattern: "0 0 * * *", command: "x")
            try ScheduleStore.save(task)

            // Drop a sham plist that remove() should clean up.
            let fm = FileManager.default
            try fm.createDirectory(atPath: launch, withIntermediateDirectories: true)
            let plistPath = launch + "/com.senkani.schedule.to-remove.plist"
            try "<plist/>".write(toFile: plistPath, atomically: true, encoding: .utf8)
            #expect(fm.fileExists(atPath: plistPath))

            try ScheduleStore.remove("to-remove")

            #expect(!fm.fileExists(atPath: tmp + "/to-remove.json"))
            #expect(!fm.fileExists(atPath: plistPath))
            // load after remove returns nil
            #expect(ScheduleStore.load("to-remove") == nil)
        }
    }

    @Test func scheduleStoreRemoveSucceedsWhenPlistAbsent() throws {
        let tmp = NSTemporaryDirectory() + "senkani-sched-\(UUID().uuidString)"
        let launch = NSTemporaryDirectory() + "senkani-launch-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: tmp)
            try? FileManager.default.removeItem(atPath: launch)
        }

        try ScheduleStore.withTestDirs(base: tmp, launchAgents: launch) {
            let task = ScheduledTask(name: "plist-absent", cronPattern: "0 0 * * *", command: "x")
            try ScheduleStore.save(task)

            // No plist at all — remove() must still delete the JSON without throwing.
            try ScheduleStore.remove("plist-absent")
            #expect(!FileManager.default.fileExists(atPath: tmp + "/plist-absent.json"))
        }
    }

    @Test func plistLabelFormat() {
        #expect(ScheduleStore.plistLabel(for: "foo") == "com.senkani.schedule.foo")
        #expect(ScheduleStore.plistLabel(for: "nightly-index") == "com.senkani.schedule.nightly-index")
    }
}
