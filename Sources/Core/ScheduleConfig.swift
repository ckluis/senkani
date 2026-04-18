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

    public init(
        name: String,
        cronPattern: String,
        command: String,
        budgetLimitCents: Int? = nil,
        enabled: Bool = true,
        createdAt: Date = Date(),
        lastRunAt: Date? = nil,
        lastRunResult: String? = nil,
        worktree: Bool = false
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
    }

    // Explicit Codable so a missing `worktree` key (pre-field JSON files
    // already on disk) decodes as `false` instead of failing.
    private enum CodingKeys: String, CodingKey {
        case name, cronPattern, command, budgetLimitCents, enabled
        case createdAt, lastRunAt, lastRunResult, worktree
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
    }
}

/// File-based store for scheduled tasks under ~/.senkani/schedules/.
public enum ScheduleStore {
    // MARK: - Test-only overrides
    //
    // Mirrors the `LearnedRulesStore.withPath` pattern: production reads
    // `baseDir` / `launchAgentsDir` straight out of `$HOME`, tests wrap a
    // body in `withTestDirs` to redirect both to a temp dir. `withTestDirs`
    // holds `testLock` for its entire body so concurrent test cases
    // serialize on the shared override slots instead of racing.

    nonisolated(unsafe) private static var _baseDirOverride: String?
    nonisolated(unsafe) private static var _launchAgentsDirOverride: String?
    private static let testLock = NSLock()

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
    /// `launchAgents` for the duration of `body`, then restore. Holds
    /// `testLock` so concurrent callers serialize.
    public static func withTestDirs<T>(
        base: String,
        launchAgents: String,
        _ body: () throws -> T
    ) rethrows -> T {
        testLock.lock()
        let priorBase = _baseDirOverride
        let priorLaunch = _launchAgentsDirOverride
        _baseDirOverride = base
        _launchAgentsDirOverride = launchAgents
        defer {
            _baseDirOverride = priorBase
            _launchAgentsDirOverride = priorLaunch
            testLock.unlock()
        }
        return try body()
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
            .sorted { $0.createdAt < $1.createdAt }
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

    /// Remove a task's JSON file and unload+delete its launchd plist.
    public static func remove(_ name: String) throws {
        let fm = FileManager.default

        // Unload and remove launchd plist
        let plistPath = launchAgentsDir + "/com.senkani.schedule.\(name).plist"
        if fm.fileExists(atPath: plistPath) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["unload", plistPath]
            try? process.run()
            process.waitUntilExit()
            try? fm.removeItem(atPath: plistPath)
        }

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
