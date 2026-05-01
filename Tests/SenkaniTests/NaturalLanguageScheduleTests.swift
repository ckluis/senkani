import Testing
import Foundation
@testable import Core

@Suite("NaturalLanguageSchedule (U.8)")
struct NaturalLanguageScheduleTests {

    // MARK: - ScheduledTask Codable

    @Test func scheduledTaskDecodesPreU8JSONWithoutFailing() throws {
        // Pre-U.8 task JSON has no proseCadence/compiledCadence/
        // eventCounterCadence/locale keys. New decoder must accept it.
        let json = """
        {
          "name": "legacy",
          "cronPattern": "0 9 * * *",
          "command": "senkani learn",
          "enabled": true,
          "createdAt": "2026-04-01T00:00:00Z",
          "worktree": false
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let task = try decoder.decode(ScheduledTask.self, from: json)
        #expect(task.name == "legacy")
        #expect(task.proseCadence == nil)
        #expect(task.compiledCadence == nil)
        #expect(task.eventCounterCadence == nil)
        #expect(task.locale == nil)
    }

    @Test func scheduledTaskRoundTripsProseFields() throws {
        let task = ScheduledTask(
            name: "prose-task",
            cronPattern: "0 9 * * 1,2,3,4,5",
            command: "senkani learn",
            proseCadence: "every weekday at 9am",
            compiledCadence: "0 9 * * 1,2,3,4,5",
            eventCounterCadence: nil,
            locale: "en-US"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(task)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ScheduledTask.self, from: data)

        #expect(decoded.proseCadence == "every weekday at 9am")
        #expect(decoded.compiledCadence == "0 9 * * 1,2,3,4,5")
        #expect(decoded.eventCounterCadence == nil)
        #expect(decoded.locale == "en-US")
    }

    // MARK: - ProseCadenceCompiler

    @Test func nullCompilerThrowsUnavailable() async {
        let compiler = NullProseCadenceCompiler()
        do {
            _ = try await compiler.compile(prose: "every weekday at 9am")
            Issue.record("expected NullProseCadenceCompiler to throw")
        } catch let error as ProseCadenceCompilerError {
            #expect(error == .unavailable)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func mockCompilerRoundTripsProseAndCron() async throws {
        let compiler = MockProseCadenceCompiler(constantCron: "0 9 * * 1,2,3,4,5")
        let result = try await compiler.compile(prose: "every weekday at 9am")
        #expect(result.prose == "every weekday at 9am")
        #expect(result.locale == "en-US")
        #expect(result.cron == "0 9 * * 1,2,3,4,5")
    }

    @Test func mockCompilerRejectsInvalidCron() async {
        let compiler = MockProseCadenceCompiler(constantCron: "not a cron")
        do {
            _ = try await compiler.compile(prose: "garbage")
            Issue.record("expected invalid cron rejection")
        } catch let error as ProseCadenceCompilerError {
            if case .invalidCron(let cron) = error {
                #expect(cron == "not a cron")
            } else {
                Issue.record("unexpected error: \(error)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: - CronPreview

    @Test func nextFiresDailyAt9am() {
        // 2026-04-29 08:00 UTC → next 5 fires of "0 9 * * *" should be
        // each subsequent calendar day at 09:00.
        let cal = Calendar.gregorianIn(TimeZone(identifier: "UTC")!)
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 29
        comps.hour = 8; comps.minute = 0; comps.second = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        let start = cal.date(from: comps)!

        let fires = CronPreview.nextFires(cron: "0 9 * * *", after: start, count: 5, calendar: cal)
        #expect(fires.count == 5)
        // First fire is same-day at 09:00 UTC
        let firstComps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fires[0])
        #expect(firstComps.year == 2026)
        #expect(firstComps.month == 4)
        #expect(firstComps.day == 29)
        #expect(firstComps.hour == 9)
        #expect(firstComps.minute == 0)
        // Each subsequent fire is exactly one day later
        for i in 1..<5 {
            let gap = fires[i].timeIntervalSince(fires[i - 1])
            #expect(gap == 86400)
        }
    }

    @Test func nextFiresWeeklyMonday9am() {
        // Cron weekday 1 = Monday. From a Wednesday, first Monday fire
        // should be 5 days later.
        let cal = Calendar.gregorianIn(TimeZone(identifier: "UTC")!)
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 29  // Wed Apr 29 2026
        comps.hour = 12; comps.minute = 0; comps.second = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        let start = cal.date(from: comps)!

        let fires = CronPreview.nextFires(cron: "0 9 * * 1", after: start, count: 3, calendar: cal)
        #expect(fires.count == 3)
        // First fire is the next Monday at 09:00 UTC: 2026-05-04
        let firstComps = cal.dateComponents([.year, .month, .day, .hour, .weekday], from: fires[0])
        #expect(firstComps.year == 2026)
        #expect(firstComps.month == 5)
        #expect(firstComps.day == 4)
        #expect(firstComps.hour == 9)
        #expect(firstComps.weekday == 2)  // Calendar.weekday: Mon=2
        // Subsequent fires exactly 7 days apart
        for i in 1..<3 {
            let gap = fires[i].timeIntervalSince(fires[i - 1])
            #expect(gap == 7 * 86400)
        }
    }

    @Test func nextFiresInvalidCronReturnsEmpty() {
        let fires = CronPreview.nextFires(cron: "garbage", after: Date(), count: 5)
        #expect(fires.isEmpty)
    }

    // MARK: - CounterCadenceRateLimiter

    @Test func rateLimiterBlocksWithinMinimum() {
        let limiter = CounterCadenceRateLimiter(minimum: 60)
        let now = Date()
        #expect(limiter.allow(scheduleName: "learn", now: now) == true)
        // 30s later — must block
        #expect(limiter.allow(scheduleName: "learn", now: now.addingTimeInterval(30)) == false)
        // 59s later — must still block
        #expect(limiter.allow(scheduleName: "learn", now: now.addingTimeInterval(59)) == false)
    }

    @Test func rateLimiterAllowsAfterMinimum() {
        let limiter = CounterCadenceRateLimiter(minimum: 60)
        let now = Date()
        #expect(limiter.allow(scheduleName: "learn", now: now) == true)
        // Exactly 60s later — passes (gap >= minimum)
        #expect(limiter.allow(scheduleName: "learn", now: now.addingTimeInterval(60)) == true)
        // Different schedule names get independent windows
        #expect(limiter.allow(scheduleName: "compact", now: now.addingTimeInterval(1)) == true)
    }

    // MARK: - AmplificationGuard

    @Test func amplificationGuardCatchesEveryToolCall() {
        // "every tool_call" → CounterCadence(everyN: 1) — must trip
        let counter = CounterCadence(eventName: "tool_call", everyN: 1)
        let verdict = AmplificationGuard.validate(cron: nil, counter: counter)
        if case .amplification(_, let floor) = verdict {
            #expect(floor == AmplificationGuard.defaultMinIntervalSeconds)
        } else {
            Issue.record("expected amplification verdict, got \(verdict)")
        }
    }

    @Test func amplificationGuardPassesDailyCron() {
        let verdict = AmplificationGuard.validate(cron: "0 9 * * *", counter: nil)
        #expect(verdict == .ok)
    }

    @Test func counterCadenceParsesEveryNthEvent() {
        let parsed = CounterCadence.parse("every 10th tool_call")
        #expect(parsed?.eventName == "tool_call")
        #expect(parsed?.everyN == 10)

        let parsed2 = CounterCadence.parse("every 5 sessions")
        #expect(parsed2?.eventName == "session")
        #expect(parsed2?.everyN == 5)

        // Locale flag default — ScheduledTask without explicit locale
        // should round-trip nil; AmplificationGuard validates regardless.
        let task = ScheduledTask(name: "t", cronPattern: "0 9 * * *", command: "x")
        #expect(task.locale == nil)
    }
}
