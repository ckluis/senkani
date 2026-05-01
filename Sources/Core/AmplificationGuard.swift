import Foundation

// MARK: - AmplificationGuard
//
// Phase U.8 — pre-save validator for prose / counter-cadence schedules.
// Catches the canonical Hermes amplification scenario before it hits
// launchd / HookRouter:
//
//   "every tool_call run senkani learn"   ← N=1 counter cadence
//   "every minute compact context"        ← cron */1 * * * *
//
// Both fire too fast under realistic workloads. The guard returns a
// structured verdict the Schedules pane can surface in the preview
// UI — letting the user accept the risk or rewrite the prose.

public enum AmplificationGuard {

    /// Outcome of a scheduling validation pass.
    public enum Verdict: Equatable, Sendable {
        /// Schedule is fine.
        case ok
        /// Schedule fires at or below `minIntervalSeconds`. Caller
        /// should refuse or warn.
        case amplification(reason: String, minIntervalSeconds: Int)
    }

    /// Default minimum allowed interval between fires. Matches the
    /// rate limiter's default so counter-cadence schedules can't be
    /// registered at a rate the limiter would refuse to honor anyway.
    public static let defaultMinIntervalSeconds = 60

    /// Validate a proposed schedule. Pass `cron` for cron-driven
    /// schedules, `counter` for counter-cadence schedules ("every N
    /// tool_calls"); pass at least one. Returns `.ok` or
    /// `.amplification(...)`.
    public static func validate(
        cron: String?,
        counter: CounterCadence?,
        minIntervalSeconds: Int = defaultMinIntervalSeconds
    ) -> Verdict {
        if let cron, !cron.isEmpty {
            if let v = checkCron(cron, minIntervalSeconds: minIntervalSeconds), v != .ok {
                return v
            }
        }
        if let counter {
            if counter.everyN < 1 {
                return .amplification(
                    reason: "counter cadence N=\(counter.everyN) must be ≥ 1",
                    minIntervalSeconds: minIntervalSeconds
                )
            }
            // Counter cadences fire whenever an event arrives. We can
            // not predict event rate, but the rate limiter will clamp
            // them to ≤ 1 / minIntervalSeconds. Surface the warning so
            // the user knows they are subject to that clamp.
            if counter.everyN <= 1 {
                return .amplification(
                    reason: "every event fires this schedule; the counter-cadence rate limiter will clamp to 1 fire / \(minIntervalSeconds)s",
                    minIntervalSeconds: minIntervalSeconds
                )
            }
        }
        return .ok
    }

    /// Check whether a cron's first two fires are too close together.
    /// Cheap approximation: compute the next 2 fires from `Date()` and
    /// reject if the gap is below `minIntervalSeconds`.
    private static func checkCron(_ cron: String, minIntervalSeconds: Int) -> Verdict? {
        let fires = CronPreview.nextFires(cron: cron, after: Date(), count: 2)
        guard fires.count == 2 else { return .ok }
        let gap = fires[1].timeIntervalSince(fires[0])
        if gap < TimeInterval(minIntervalSeconds) {
            return .amplification(
                reason: "cron fires every \(Int(gap))s, below the \(minIntervalSeconds)s amplification floor",
                minIntervalSeconds: minIntervalSeconds
            )
        }
        return .ok
    }
}

// MARK: - CounterCadence

/// Represents an "every Nth event" schedule expression. Stored as a
/// string on `ScheduledTask.eventCounterCadence`; parsed via
/// `CounterCadence.parse`.
public struct CounterCadence: Equatable, Sendable {
    /// e.g. "tool_call", "session_start", "post_tool".
    public let eventName: String
    /// N — fire every Nth event. Must be ≥ 1.
    public let everyN: Int

    public init(eventName: String, everyN: Int) {
        self.eventName = eventName
        self.everyN = everyN
    }

    /// Parse a `every <N> <event>` expression. Returns nil if the
    /// shape doesn't match. Tolerates "every Nth event" and "every N events".
    public static func parse(_ expression: String) -> CounterCadence? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let words = trimmed.split(separator: " ").map(String.init)
        guard words.count >= 3, words[0] == "every" else { return nil }

        // Form A: "every N event(s)" — words[1] is digit
        if let n = Int(words[1]) {
            let event = normalizeEventName(words.dropFirst(2).joined(separator: "_"))
            guard !event.isEmpty else { return nil }
            return CounterCadence(eventName: event, everyN: n)
        }

        // Form B: "every Nth event" — strip ordinal suffix
        let ordinal = words[1]
        if let suffixRange = ordinal.range(of: #"^(\d+)(st|nd|rd|th)$"#, options: .regularExpression) {
            let digits = ordinal[suffixRange]
                .replacingOccurrences(of: "st", with: "")
                .replacingOccurrences(of: "nd", with: "")
                .replacingOccurrences(of: "rd", with: "")
                .replacingOccurrences(of: "th", with: "")
            if let n = Int(digits) {
                let event = normalizeEventName(words.dropFirst(2).joined(separator: "_"))
                guard !event.isEmpty else { return nil }
                return CounterCadence(eventName: event, everyN: n)
            }
        }

        return nil
    }

    /// Strip a single trailing pluralizing 's' (and any trailing
    /// underscore left over from joining). Leading characters are
    /// preserved — "session" must not turn into "ession".
    private static func normalizeEventName(_ raw: String) -> String {
        var name = raw
        while name.hasSuffix("_") { name.removeLast() }
        if name.hasSuffix("s") && name.count > 1 { name.removeLast() }
        return name
    }
}
