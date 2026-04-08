import Foundation

/// Budget enforcement configuration for Senkani.
///
/// Loads limits from `~/.senkani/budget.json`, env vars, or defaults (no limits).
/// Resolution: JSON file > env vars > default (nil = unlimited).
///
/// Security:
/// - JSON is validated before parsing (rejects non-object root, oversized files).
/// - Warns to stderr if the budget file is world-readable (chmod o+r).
/// - Config is cached for 30 seconds to avoid filesystem I/O on every tool call.
public struct BudgetConfig: Codable, Sendable {
    public var perSessionLimitCents: Int?
    public var dailyLimitCents: Int?
    public var weeklyLimitCents: Int?
    public var softLimitPercent: Double = 0.8  // warn at 80%

    public enum Decision: Sendable, Equatable {
        case allow
        case warn(String)   // soft limit reached — execute but include warning
        case block(String)  // hard limit reached — reject the tool call
    }

    public init(
        perSessionLimitCents: Int? = nil,
        dailyLimitCents: Int? = nil,
        weeklyLimitCents: Int? = nil,
        softLimitPercent: Double = 0.8
    ) {
        self.perSessionLimitCents = perSessionLimitCents
        self.dailyLimitCents = dailyLimitCents
        self.weeklyLimitCents = weeklyLimitCents
        self.softLimitPercent = softLimitPercent
    }

    // MARK: - Cached Loading

    /// Actor-isolated cache so concurrent callers share the same config without races.
    private static let cache = BudgetConfigCache()

    /// Load budget config, using a 30-second cache to avoid repeated disk reads.
    public static func load() -> BudgetConfig {
        return cache.load()
    }

    /// Force-reload from disk, bypassing the cache. Used in tests.
    public static func forceReload() -> BudgetConfig {
        return cache.forceReload()
    }

    // MARK: - Decision Logic

    /// Check current spend against configured limits.
    /// Returns the most restrictive decision (block > warn > allow).
    /// Checks weekly first (broadest scope), then daily, then session.
    public func check(sessionCents: Int, todayCents: Int, weekCents: Int) -> Decision {
        // Check weekly limit
        if let weeklyLimit = weeklyLimitCents {
            if weekCents >= weeklyLimit {
                return .block("Weekly budget exceeded: $\(formatCents(weekCents)) / $\(formatCents(weeklyLimit))")
            }
            if Double(weekCents) >= Double(weeklyLimit) * softLimitPercent {
                let warning = "Approaching weekly budget: $\(formatCents(weekCents)) / $\(formatCents(weeklyLimit))"
                // Continue checking — a harder limit may apply
                return checkDaily(sessionCents: sessionCents, todayCents: todayCents, fallback: .warn(warning))
            }
        }

        // Check daily limit
        return checkDaily(sessionCents: sessionCents, todayCents: todayCents, fallback: .allow)
    }

    private func checkDaily(sessionCents: Int, todayCents: Int, fallback: Decision) -> Decision {
        if let dailyLimit = dailyLimitCents {
            if todayCents >= dailyLimit {
                return .block("Daily budget exceeded: $\(formatCents(todayCents)) / $\(formatCents(dailyLimit))")
            }
            if Double(todayCents) >= Double(dailyLimit) * softLimitPercent {
                let warning = "Approaching daily budget: $\(formatCents(todayCents)) / $\(formatCents(dailyLimit))"
                return checkSession(sessionCents: sessionCents, fallback: .warn(warning))
            }
        }
        return checkSession(sessionCents: sessionCents, fallback: fallback)
    }

    private func checkSession(sessionCents: Int, fallback: Decision) -> Decision {
        if let sessionLimit = perSessionLimitCents {
            if sessionCents >= sessionLimit {
                return .block("Session budget exceeded: $\(formatCents(sessionCents)) / $\(formatCents(sessionLimit))")
            }
            if Double(sessionCents) >= Double(sessionLimit) * softLimitPercent {
                let warning = "Approaching session budget: $\(formatCents(sessionCents)) / $\(formatCents(sessionLimit))"
                // A warn is weaker than a block, so pick the more restrictive fallback
                return moreRestrictive(fallback, .warn(warning))
            }
        }
        return fallback
    }

    /// Return the more restrictive of two decisions: block > warn > allow.
    private func moreRestrictive(_ a: Decision, _ b: Decision) -> Decision {
        func severity(_ d: Decision) -> Int {
            switch d {
            case .allow: return 0
            case .warn: return 1
            case .block: return 2
            }
        }
        return severity(a) >= severity(b) ? a : b
    }

    private func formatCents(_ cents: Int) -> String {
        String(format: "%.2f", Double(cents) / 100.0)
    }
}

// MARK: - Cache

/// Thread-safe cache for BudgetConfig with 30-second TTL.
/// Uses NSLock (not actor) so callers don't need async context.
private final class BudgetConfigCache: @unchecked Sendable {
    private var cached: BudgetConfig?
    private var cachedAt: Date?
    private let lock = NSLock()
    private static let ttl: TimeInterval = 30

    func load() -> BudgetConfig {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cached, let cachedAt = cachedAt,
           Date().timeIntervalSince(cachedAt) < Self.ttl {
            return cached
        }

        let config = BudgetConfig.loadFromDisk()
        self.cached = config
        self.cachedAt = Date()
        return config
    }

    func forceReload() -> BudgetConfig {
        lock.lock()
        defer { lock.unlock() }

        let config = BudgetConfig.loadFromDisk()
        self.cached = config
        self.cachedAt = Date()
        return config
    }
}

// MARK: - Disk Loading

extension BudgetConfig {
    /// Budget file path: ~/.senkani/budget.json
    static var budgetFilePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/.senkani/budget.json"
    }

    /// Load config from disk. JSON file takes priority, then env vars, then defaults.
    fileprivate static func loadFromDisk() -> BudgetConfig {
        let fm = FileManager.default
        let path = budgetFilePath

        // Try JSON file first
        if fm.fileExists(atPath: path) {
            // SECURITY: Check file permissions — warn if world-readable
            checkPermissions(path: path)

            guard let data = fm.contents(atPath: path) else {
                logWarning("Budget file exists but could not be read: \(path)")
                return loadFromEnv()
            }

            // SECURITY: Reject oversized files (limit to 4KB for a config file)
            guard data.count <= 4096 else {
                logWarning("Budget file too large (\(data.count) bytes), ignoring: \(path)")
                return loadFromEnv()
            }

            // SECURITY: Validate JSON structure before decoding
            guard (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) != nil else {
                logWarning("Budget file is not valid JSON object, ignoring: \(path)")
                return loadFromEnv()
            }

            // Decode with validation
            do {
                var config = try JSONDecoder().decode(BudgetConfig.self, from: data)

                // Validate values — reject negative limits
                if let v = config.perSessionLimitCents, v < 0 {
                    logWarning("perSessionLimitCents is negative, ignoring")
                    config.perSessionLimitCents = nil
                }
                if let v = config.dailyLimitCents, v < 0 {
                    logWarning("dailyLimitCents is negative, ignoring")
                    config.dailyLimitCents = nil
                }
                if let v = config.weeklyLimitCents, v < 0 {
                    logWarning("weeklyLimitCents is negative, ignoring")
                    config.weeklyLimitCents = nil
                }
                if config.softLimitPercent < 0 || config.softLimitPercent > 1.0 {
                    logWarning("softLimitPercent out of range [0,1], resetting to 0.8")
                    config.softLimitPercent = 0.8
                }

                return config
            } catch {
                logWarning("Failed to decode budget.json: \(error.localizedDescription)")
                return loadFromEnv()
            }
        }

        return loadFromEnv()
    }

    /// Fallback: load from environment variables.
    private static func loadFromEnv() -> BudgetConfig {
        let env = ProcessInfo.processInfo.environment

        let session = env["SENKANI_BUDGET_SESSION"].flatMap { Int($0) }
        let daily = env["SENKANI_BUDGET_DAILY"].flatMap { Int($0) }
        let weekly = env["SENKANI_BUDGET_WEEKLY"].flatMap { Int($0) }

        return BudgetConfig(
            perSessionLimitCents: session,
            dailyLimitCents: daily,
            weeklyLimitCents: weekly
        )
    }

    /// SECURITY: Check that budget file is not world-readable.
    private static func checkPermissions(path: String) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let posix = attrs[.posixPermissions] as? Int else {
            return
        }
        // Check if "others" have read permission (octal 004)
        if posix & 0o004 != 0 {
            logWarning("SECURITY: Budget file is world-readable (\(String(posix, radix: 8))). Run: chmod 600 \(path)")
        }
    }

    private static func logWarning(_ message: String) {
        FileHandle.standardError.write(Data("[senkani-budget] \(message)\n".utf8))
    }
}
