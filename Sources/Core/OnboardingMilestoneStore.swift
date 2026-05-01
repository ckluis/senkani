import Foundation

/// Local-only, file-backed log of when each ``OnboardingMilestone``
/// first fired for this user.
///
/// Privacy posture (Cavoukian audit, 2026-05-01):
///   - Storage is `~/.senkani/onboarding/milestones.json` at mode 0600.
///   - The file holds *only* a `{milestone: ISO8601 timestamp}`
///     dictionary. No project paths, no session IDs, no agent text.
///   - Senkani never reads this file off the local machine. There is
///     no upload path — manual research uses it as an in-place
///     observation marker, not an analytics feed.
///   - Setting `SENKANI_ONBOARDING_MILESTONES=off` (case-insensitive)
///     turns every read and write into a no-op. The env gate exists
///     so a privacy-strict user can opt out without recompiling.
///
/// Test contract:
///   - Every entry point accepts an injectable `home:` so tests run
///     under a temp directory.
///   - ``reset(home:)`` deletes the file outright — the round's
///     acceptance criterion that milestones be "reversible/resettable
///     for tests".
///   - ``record`` is idempotent: re-recording an already-completed
///     milestone leaves the original timestamp unchanged. The first
///     observation is the one we keep.
public enum OnboardingMilestoneStore {

    /// Env var consulted by ``isEnabled``. Default ON. Setting the
    /// var to `"off"` (case-insensitive) makes every API call a
    /// no-op, including reads.
    public static let envVarName = "SENKANI_ONBOARDING_MILESTONES"

    /// File path the store reads and writes — relative to `home`.
    public static let relativePath = ".senkani/onboarding/milestones.json"

    /// Returns false when the env gate is set to `"off"`. An unset
    /// var keeps the store enabled.
    public static func isEnabled(env: [String: String]? = nil) -> Bool {
        let value: String?
        if let env {
            value = env[envVarName]
        } else {
            value = ProcessInfo.processInfo.environment[envVarName]
        }
        guard let v = value?.lowercased() else { return true }
        return v != "off"
    }

    /// Absolute path to the milestone file under `home` (defaults to
    /// `NSHomeDirectory()`).
    public static func filePath(home: String? = nil) -> String {
        let base = home ?? NSHomeDirectory()
        return (base as NSString).appendingPathComponent(relativePath)
    }

    /// All recorded milestones with their first-observed timestamps.
    /// Returns an empty dictionary when the file is missing, the env
    /// gate is off, or the file is unreadable / malformed.
    public static func completed(
        home: String? = nil,
        env: [String: String]? = nil
    ) -> [OnboardingMilestone: Date] {
        guard isEnabled(env: env) else { return [:] }
        let path = filePath(home: home)
        guard let data = FileManager.default.contents(atPath: path) else {
            return [:]
        }
        guard let raw = try? JSONDecoder.iso8601.decode([String: String].self, from: data) else {
            return [:]
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var result: [OnboardingMilestone: Date] = [:]
        for (key, value) in raw {
            guard let milestone = OnboardingMilestone(rawValue: key) else { continue }
            if let date = formatter.date(from: value) {
                result[milestone] = date
            } else if let fallback = ISO8601DateFormatter().date(from: value) {
                result[milestone] = fallback
            }
        }
        return result
    }

    /// Timestamp the milestone was first observed at, or nil if it
    /// hasn't fired yet (or the env gate is off).
    public static func completedAt(
        _ milestone: OnboardingMilestone,
        home: String? = nil,
        env: [String: String]? = nil
    ) -> Date? {
        completed(home: home, env: env)[milestone]
    }

    /// True when the milestone has been observed at least once.
    public static func isCompleted(
        _ milestone: OnboardingMilestone,
        home: String? = nil,
        env: [String: String]? = nil
    ) -> Bool {
        completedAt(milestone, home: home, env: env) != nil
    }

    /// Record `milestone` as observed at `at` (defaults to now).
    /// Idempotent: a second record for the same milestone is a no-op
    /// — the first observation wins. Returns true if this call wrote
    /// a new entry, false if the entry already existed or the env
    /// gate is off.
    @discardableResult
    public static func record(
        _ milestone: OnboardingMilestone,
        at: Date = Date(),
        home: String? = nil,
        env: [String: String]? = nil
    ) -> Bool {
        guard isEnabled(env: env) else { return false }
        var current = completed(home: home, env: env)
        if current[milestone] != nil { return false }
        current[milestone] = at
        write(current, home: home)
        return true
    }

    /// Delete the milestone file outright. Useful for tests and for
    /// the rare "reset onboarding" debug affordance.
    public static func reset(
        home: String? = nil,
        env: [String: String]? = nil
    ) {
        guard isEnabled(env: env) else { return }
        let path = filePath(home: home)
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Private

    private static func write(
        _ entries: [OnboardingMilestone: Date],
        home: String?
    ) {
        let path = filePath(home: home)
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var raw: [String: String] = [:]
        for (milestone, date) in entries {
            raw[milestone.rawValue] = formatter.string(from: date)
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: raw,
            options: [.sortedKeys, .prettyPrinted]
        ) else { return }

        // Temp-file → rename so a partial write can never corrupt the
        // existing file. Mode 0600 on the final file matches the
        // PaneDiaryStore convention for user-local data.
        let tempPath = path + ".tmp"
        FileManager.default.createFile(
            atPath: tempPath,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        )
        do {
            if FileManager.default.fileExists(atPath: path) {
                _ = try? FileManager.default.replaceItemAt(
                    URL(fileURLWithPath: path),
                    withItemAt: URL(fileURLWithPath: tempPath)
                )
            } else {
                try FileManager.default.moveItem(atPath: tempPath, toPath: path)
            }
        } catch {
            try? FileManager.default.removeItem(atPath: tempPath)
        }
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
