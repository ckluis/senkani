import Foundation

/// A single scheduled task persisted to ~/.senkani/schedules/{name}.json.
public struct ScheduledTask: Codable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let cronPattern: String
    public let command: String
    public var budgetLimitCents: Int?
    public var enabled: Bool
    public var createdAt: Date
    public var lastRunAt: Date?
    public var lastRunResult: String?  // "success", "failed: ...", "budget_exceeded"
    public var worktree: Bool

    // Phase U.8 — NaturalLanguageSchedule fields. All optional so existing
    // task JSON on disk decodes unchanged (anchor-from-now: pre-U.8 rows
    // simply have nil prose/counter cadence).
    //
    // Wiring:
    //   - `proseCadence`         the original prose ("every weekday at 9am").
    //   - `compiledCadence`      cron compiled from prose at registration.
    //                            When non-nil, equals `cronPattern` — kept as
    //                            a separate field so callers can tell prose-
    //                            driven schedules apart from cron-direct
    //                            without re-parsing.
    //   - `eventCounterCadence`  counter expression ("every 10 tool_calls").
    //                            Counter cadences fire from HookRouter post-
    //                            tool reactions, NOT from launchd; cronPattern
    //                            on those rows is a sentinel.
    //   - `locale`               BCP-47 tag for prose parsing (default en-US).
    public var proseCadence: String?
    public var compiledCadence: String?
    public var eventCounterCadence: String?
    public var locale: String?

    // Drag-reorder order key. Optional so pre-field JSON on disk decodes
    // unchanged (migrate-on-read: a nil `sortIndex` falls back to
    // `createdAt` in `ScheduleStore.list()`). The Schedules pane writes a
    // dense 0-based `sortIndex` on drag-reorder instead of overloading
    // `createdAt`, so the genuine creation timestamp is preserved.
    public var sortIndex: Int?

    public init(
        name: String,
        cronPattern: String,
        command: String,
        budgetLimitCents: Int? = nil,
        enabled: Bool = true,
        createdAt: Date = Date(),
        lastRunAt: Date? = nil,
        lastRunResult: String? = nil,
        worktree: Bool = false,
        proseCadence: String? = nil,
        compiledCadence: String? = nil,
        eventCounterCadence: String? = nil,
        locale: String? = nil,
        sortIndex: Int? = nil
    ) {
        self.name = name
        self.cronPattern = cronPattern
        self.command = command
        self.budgetLimitCents = budgetLimitCents
        self.enabled = enabled
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
        self.lastRunResult = lastRunResult
        self.worktree = worktree
        self.proseCadence = proseCadence
        self.compiledCadence = compiledCadence
        self.eventCounterCadence = eventCounterCadence
        self.locale = locale
        self.sortIndex = sortIndex
    }

    // Explicit Codable so a missing key (pre-field JSON files already on
    // disk) decodes as default instead of failing.
    private enum CodingKeys: String, CodingKey {
        case name, cronPattern, command, budgetLimitCents, enabled
        case createdAt, lastRunAt, lastRunResult, worktree
        case proseCadence, compiledCadence, eventCounterCadence, locale
        case sortIndex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.cronPattern = try c.decode(String.self, forKey: .cronPattern)
        self.command = try c.decode(String.self, forKey: .command)
        self.budgetLimitCents = try c.decodeIfPresent(Int.self, forKey: .budgetLimitCents)
        self.enabled = try c.decode(Bool.self, forKey: .enabled)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.lastRunAt = try c.decodeIfPresent(Date.self, forKey: .lastRunAt)
        self.lastRunResult = try c.decodeIfPresent(String.self, forKey: .lastRunResult)
        self.worktree = try c.decodeIfPresent(Bool.self, forKey: .worktree) ?? false
        self.proseCadence = try c.decodeIfPresent(String.self, forKey: .proseCadence)
        self.compiledCadence = try c.decodeIfPresent(String.self, forKey: .compiledCadence)
        self.eventCounterCadence = try c.decodeIfPresent(String.self, forKey: .eventCounterCadence)
        self.locale = try c.decodeIfPresent(String.self, forKey: .locale)
        self.sortIndex = try c.decodeIfPresent(Int.self, forKey: .sortIndex)
    }
}

/// File-based store for scheduled tasks under ~/.senkani/schedules/.
public enum ScheduleStore {
    // MARK: - Test-only overrides
    //
    // Mirrors the `LearnedRulesStore.withPath` pattern: production reads
    // `baseDir` / `launchAgentsDir` straight out of `$HOME`, tests wrap a
    // body in `withTestDirs` to redirect both to a temp dir.
    //
    // The overrides are `@TaskLocal`, NOT a global mutable slot guarded by a
    // lock. Each test (and each `await` chain within it) sees its own
    // override value, so parallel test cases — including `async` CLI run
    // paths under `AsyncParsableCommand` — never clobber each other's temp
    // dirs. This replaced an `NSLock`-serialized global pair on
    // 2026-05-26 when `Schedule.Create` became `AsyncParsableCommand`: an
    // async `withTestDirs` could not hold `NSLock` across an `await`
    // (forbidden in Swift 6), and a non-locking variant let a parallel
    // suite swap the global out from under a running test.

    @TaskLocal static var _baseDirOverride: String?
    @TaskLocal static var _launchAgentsDirOverride: String?

    // MARK: - launchctl seam
    //
    // `remove` / `removePlist` and `PresetInstaller.install` / `reload`
    // all run `launchctl load|unload <plist>` to (de)activate the live
    // launchd job. In production this spawns `/bin/launchctl`; tests inject
    // a recorder via `withLaunchctlRecorder` so they can assert the
    // unload-then-load (re-arm) and unload-on-mode-switch invocations
    // WITHOUT touching the real launchd (and without depending on a real
    // machine). `@TaskLocal` so concurrent test cases stay isolated,
    // matching the `_baseDirOverride` pattern.

    /// A single `launchctl` verb + plist path the seam was asked to run.
    public struct LaunchctlInvocation: Sendable, Equatable {
        public let verb: String        // "load" or "unload"
        public let plistPath: String
        public init(verb: String, plistPath: String) {
            self.verb = verb
            self.plistPath = plistPath
        }
    }

    /// Thread-safe recorder of `launchctl` invocations for tests.
    public final class LaunchctlRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _invocations: [LaunchctlInvocation] = []
        public init() {}
        func record(_ inv: LaunchctlInvocation) {
            lock.lock(); defer { lock.unlock() }
            _invocations.append(inv)
        }
        public var invocations: [LaunchctlInvocation] {
            lock.lock(); defer { lock.unlock() }
            return _invocations
        }
        public var verbs: [String] { invocations.map(\.verb) }
    }

    @TaskLocal static var _launchctlRecorder: LaunchctlRecorder?

    /// TEST ONLY: route every `launchctl load|unload` through `recorder`
    /// instead of spawning `/bin/launchctl`, for the duration of `body`.
    public static func withLaunchctlRecorder<T>(
        _ recorder: LaunchctlRecorder,
        _ body: () throws -> T
    ) rethrows -> T {
        try $_launchctlRecorder.withValue(recorder) { try body() }
    }

    /// Run `launchctl <verb> <plistPath>`. When a recorder is installed
    /// (tests) the invocation is captured and `/bin/launchctl` is NOT
    /// spawned; otherwise it runs the real process. Returns `true` on a
    /// zero exit status (recorder always "succeeds").
    @discardableResult
    static func runLaunchctl(verb: String, plistPath: String) -> Bool {
        if let recorder = _launchctlRecorder {
            recorder.record(LaunchctlInvocation(verb: verb, plistPath: plistPath))
            return true
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = [verb, plistPath]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    public static var baseDir: String {
        _baseDirOverride ?? FileManager.default.homeDirectoryForCurrentUser.path + "/.senkani/schedules"
    }

    public static var logsDir: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.senkani/logs"
    }

    public static var launchAgentsDir: String {
        _launchAgentsDirOverride ?? FileManager.default.homeDirectoryForCurrentUser.path + "/Library/LaunchAgents"
    }

    /// TEST ONLY: redirect `baseDir` + `launchAgentsDir` to `base` /
    /// `launchAgents` for the duration of `body`. Per-task (`@TaskLocal`),
    /// so concurrent test cases are isolated without a lock.
    public static func withTestDirs<T>(
        base: String,
        launchAgents: String,
        _ body: () throws -> T
    ) rethrows -> T {
        try $_baseDirOverride.withValue(base) {
            try $_launchAgentsDirOverride.withValue(launchAgents) {
                try body()
            }
        }
    }

    /// TEST ONLY (async): same contract as the sync `withTestDirs`, for
    /// `AsyncParsableCommand` run paths. The `@TaskLocal` binding propagates
    /// across `await` to child tasks in the structured tree, so the override
    /// is visible to async `ScheduleStore` work without any lock.
    public static func withTestDirs<T>(
        base: String,
        launchAgents: String,
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await $_baseDirOverride.withValue(base) {
            try await $_launchAgentsDirOverride.withValue(launchAgents) {
                try await body()
            }
        }
    }

    /// Read all .json files from the schedules directory.
    public static func list() -> [ScheduledTask] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: baseDir) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return entries
            .filter { $0.hasSuffix(".json") }
            .compactMap { filename -> ScheduledTask? in
                let path = baseDir + "/" + filename
                guard let data = fm.contents(atPath: path) else { return nil }
                return try? decoder.decode(ScheduledTask.self, from: data)
            }
            .sorted(by: orderBefore)
    }

    /// Stable list ordering: rows carrying an explicit drag-reorder
    /// `sortIndex` come first in `sortIndex` order; rows without one (pre-
    /// `sortIndex` JSON, or never-reordered) fall back to `createdAt`, and
    /// sort AFTER any explicitly-ordered row. `name` is the final tiebreak
    /// so the order is deterministic. This migrates legacy schedules
    /// gracefully — a store with no `sortIndex` anywhere reproduces the old
    /// pure-`createdAt` order.
    static func orderBefore(_ a: ScheduledTask, _ b: ScheduledTask) -> Bool {
        switch (a.sortIndex, b.sortIndex) {
        case let (ai?, bi?):
            if ai != bi { return ai < bi }
            return a.createdAt < b.createdAt
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.name < b.name
        }
    }

    /// Save a task to {name}.json.
    public static func save(_ task: ScheduledTask) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: baseDir) {
            try fm.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(task)
        let path = baseDir + "/\(task.name).json"
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Load a single task by name.
    public static func load(_ name: String) -> ScheduledTask? {
        let path = baseDir + "/\(name).json"
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ScheduledTask.self, from: data)
    }

    /// Unload (if loaded) and delete the launchd plist for `name`, leaving
    /// the JSON config in place. Used by the edit lifecycle when a schedule
    /// is edited from a cron/prose cadence down to a counter cadence — the
    /// counter row stays (with its sentinel cron) but its prior launchd job
    /// must be torn down so it can't keep firing the old cadence (ghost
    /// double-fire). Idempotent: a no-op when no plist exists.
    @discardableResult
    public static func removePlist(_ name: String) -> Bool {
        let fm = FileManager.default
        let plistPath = launchAgentsDir + "/com.senkani.schedule.\(name).plist"
        guard fm.fileExists(atPath: plistPath) else { return false }
        runLaunchctl(verb: "unload", plistPath: plistPath)
        try? fm.removeItem(atPath: plistPath)
        return true
    }

    /// Remove a task's JSON file and unload+delete its launchd plist.
    public static func remove(_ name: String) throws {
        let fm = FileManager.default

        // Unload and remove launchd plist
        _ = removePlist(name)

        // Remove JSON config
        let jsonPath = baseDir + "/\(name).json"
        if fm.fileExists(atPath: jsonPath) {
            try fm.removeItem(atPath: jsonPath)
        }
    }

    /// Label used for the launchd plist.
    public static func plistLabel(for name: String) -> String {
        "com.senkani.schedule.\(name)"
    }
}

// MARK: - Cron to launchd Conversion

/// Converts a 5-field cron expression to launchd StartCalendarInterval dictionaries.
///
/// Field order: minute hour day-of-month month day-of-week
/// Supports: `*` (any), `N` (specific value), `*/N` (every N — generates list),
///           `N,M` (comma-separated list).
public enum CronToLaunchd {

    /// Launchd calendar interval key names for each cron field position.
    private static let fieldKeys = ["Minute", "Hour", "Day", "Month", "Weekday"]

    /// Parse a 5-field cron string into an array of StartCalendarInterval dictionaries.
    /// Each dict maps launchd key names (Minute, Hour, Day, Month, Weekday) to Int values.
    /// Returns nil if the cron expression is invalid.
    public static func convert(_ cron: String) -> [[String: Int]]? {
        let fields = cron.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        guard fields.count == 5 else { return nil }

        // Ranges for each field: minute(0-59), hour(0-23), day(1-31), month(1-12), weekday(0-6)
        let ranges: [ClosedRange<Int>] = [0...59, 0...23, 1...31, 1...12, 0...6]

        // Parse each field into its possible values (nil means "any")
        var fieldValues: [[Int]?] = []
        for (i, field) in fields.enumerated() {
            if field == "*" {
                fieldValues.append(nil) // any
            } else if field.hasPrefix("*/") {
                // Every N
                guard let n = Int(field.dropFirst(2)), n > 0 else { return nil }
                let range = ranges[i]
                let values = stride(from: range.lowerBound, through: range.upperBound, by: n).map { $0 }
                fieldValues.append(values)
            } else if field.contains(",") {
                // List
                let parts = field.split(separator: ",").compactMap { Int($0) }
                guard !parts.isEmpty else { return nil }
                for v in parts {
                    guard ranges[i].contains(v) else { return nil }
                }
                fieldValues.append(parts)
            } else {
                // Single value
                guard let v = Int(field), ranges[i].contains(v) else { return nil }
                fieldValues.append([v])
            }
        }

        // Generate the cartesian product of all non-nil fields.
        // Start with one empty dict and expand for each field that has specific values.
        var results: [[String: Int]] = [[:]]

        for (i, values) in fieldValues.enumerated() {
            guard let vals = values else { continue }
            let key = fieldKeys[i]
            var expanded: [[String: Int]] = []
            for dict in results {
                for v in vals {
                    var d = dict
                    d[key] = v
                    expanded.append(d)
                }
            }
            results = expanded
        }

        return results.isEmpty ? [[:]] : results
    }

    /// Convert a cron expression to a human-readable description.
    public static func humanReadable(_ cron: String) -> String {
        let fields = cron.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        guard fields.count == 5 else { return cron }

        let minute = fields[0]
        let hour = fields[1]
        let dayOfMonth = fields[2]
        let month = fields[3]
        let dayOfWeek = fields[4]

        // Common patterns
        if minute == "*" && hour == "*" && dayOfMonth == "*" && month == "*" && dayOfWeek == "*" {
            return "Every minute"
        }

        if hour == "*" && dayOfMonth == "*" && month == "*" && dayOfWeek == "*" {
            if minute.hasPrefix("*/") {
                let n = String(minute.dropFirst(2))
                return "Every \(n) minutes"
            }
        }

        if dayOfMonth == "*" && month == "*" && dayOfWeek == "*" {
            if minute.hasPrefix("*/") || minute != "*" {
                if hour.hasPrefix("*/") {
                    let n = String(hour.dropFirst(2))
                    return "Every \(n) hours"
                }
                if hour == "*" {
                    return "Every hour at :\(minute.count == 1 ? "0\(minute)" : minute)"
                }
            }
            if let h = Int(hour), let m = Int(minute) {
                let period = h >= 12 ? "PM" : "AM"
                let displayH = h == 0 ? 12 : (h > 12 ? h - 12 : h)
                return "Daily at \(displayH):\(String(format: "%02d", m)) \(period)"
            }
        }

        if dayOfMonth == "*" && month == "*" && dayOfWeek != "*" {
            let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            if let dow = Int(dayOfWeek), dow >= 0 && dow <= 6 {
                if let h = Int(hour), let m = Int(minute) {
                    let period = h >= 12 ? "PM" : "AM"
                    let displayH = h == 0 ? 12 : (h > 12 ? h - 12 : h)
                    return "Every \(weekdays[dow]) at \(displayH):\(String(format: "%02d", m)) \(period)"
                }
            }
        }

        return cron
    }
}
