import Foundation

// MARK: - CronPreview
//
// Phase U.8 — pure helper that, given a 5-field cron expression and a
// reference date, returns the next N fire times. Powers the Schedules
// pane "show next 5 fire times" preview button so users can sanity-
// check a compiled cron before saving the schedule.
//
// Implementation strategy: brute-force minute-by-minute walk against
// `CronToLaunchd.convert` constraints. Cheap because we cap at N=5
// and bound the search horizon at one year — even degenerate crons
// terminate fast.

public enum CronPreview {

    /// Default search horizon when computing the next N fires.
    public static let defaultHorizon: TimeInterval = 365 * 24 * 60 * 60

    /// Compute the next `count` fire times for `cron` after `start`.
    ///
    /// Returns an empty array if `cron` is invalid or no fires occur
    /// within `horizon`. Times are returned in ascending order and do
    /// NOT include `start` itself (strictly after).
    public static func nextFires(
        cron: String,
        after start: Date,
        count: Int = 5,
        calendar: Calendar = .gregorianIn(.current),
        horizon: TimeInterval = defaultHorizon
    ) -> [Date] {
        guard count > 0 else { return [] }
        guard let intervals = CronToLaunchd.convert(cron), !intervals.isEmpty else {
            return []
        }

        // Walk forward minute by minute. The cron grammar's coarsest
        // resolution is one minute, so this is the natural step.
        var fires: [Date] = []
        let limit = start.addingTimeInterval(horizon)
        // Round up to the next whole minute so we don't include `start`.
        let firstCandidate = nextWholeMinute(after: start, calendar: calendar)
        var candidate = firstCandidate

        while candidate <= limit && fires.count < count {
            if matches(date: candidate, intervals: intervals, calendar: calendar) {
                fires.append(candidate)
            }
            // Step one minute. Use Calendar to keep DST behavior sane.
            guard let next = calendar.date(byAdding: .minute, value: 1, to: candidate) else {
                break
            }
            candidate = next
        }
        return fires
    }

    // MARK: - Internals

    /// Round `date` UP to the next whole minute boundary (zero seconds).
    /// Cron fires happen at exact minute boundaries, so candidate dates
    /// must be aligned.
    private static func nextWholeMinute(after date: Date, calendar: Calendar) -> Date {
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        var aligned = comps
        aligned.second = 0
        guard let alignedDate = calendar.date(from: aligned) else { return date }
        // If we already aligned exactly on a minute and the input had
        // zero seconds, advance by one minute so we exclude `date`.
        if alignedDate == date {
            return calendar.date(byAdding: .minute, value: 1, to: alignedDate) ?? alignedDate
        }
        // Otherwise advance to the NEXT minute boundary.
        return calendar.date(byAdding: .minute, value: 1, to: alignedDate) ?? alignedDate
    }

    /// True iff `date` matches at least one of the launchd interval
    /// dictionaries (each dict is one OR-branch per CronToLaunchd's
    /// cartesian expansion).
    private static func matches(
        date: Date,
        intervals: [[String: Int]],
        calendar: Calendar
    ) -> Bool {
        let comps = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        // Calendar.weekday: Sunday=1 ... Saturday=7. Cron weekday: Sunday=0 ... Saturday=6.
        let cronWeekday = (comps.weekday ?? 1) - 1
        for dict in intervals {
            if intervalMatches(
                dict,
                minute: comps.minute,
                hour: comps.hour,
                day: comps.day,
                month: comps.month,
                weekday: cronWeekday
            ) {
                return true
            }
        }
        return false
    }

    private static func intervalMatches(
        _ dict: [String: Int],
        minute: Int?,
        hour: Int?,
        day: Int?,
        month: Int?,
        weekday: Int
    ) -> Bool {
        // A missing key in the launchd dict means "any" for that field.
        if let m = dict["Minute"], m != minute { return false }
        if let h = dict["Hour"], h != hour { return false }
        if let d = dict["Day"], d != day { return false }
        if let mo = dict["Month"], mo != month { return false }
        if let w = dict["Weekday"], w != weekday { return false }
        return true
    }
}

// MARK: - Calendar timezone helper

extension Calendar {
    /// Return a Gregorian calendar pinned to `tz`. Used by CronPreview
    /// so tests can pin a deterministic timezone (UTC) without leaking
    /// into the global default calendar.
    public static func gregorianIn(_ tz: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal
    }
}
