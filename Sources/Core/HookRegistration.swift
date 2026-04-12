import Foundation

/// Registers senkani-hook in a project's .claude/settings.json.
/// Handles both PreToolUse and PostToolUse events.
///
/// IMPORTANT: This registers hooks at the PROJECT level only, never globally.
/// AutoRegistration.swift actively strips hooks from ~/.claude/settings.json
/// on every launch. Project-level hooks are safe because they only affect
/// Claude Code sessions running inside that project directory.
public enum HookRegistration {

    /// Register senkani-hook for a project directory.
    /// Creates .claude/settings.json inside the project if needed.
    /// Idempotent — safe to call multiple times.
    public static func registerForProject(at projectPath: String, hookBinaryPath: String) throws {
        let settingsPath = projectPath + "/.claude/settings.json"
        let settingsDir = projectPath + "/.claude"
        let fm = FileManager.default

        // Ensure .claude directory exists
        if !fm.fileExists(atPath: settingsDir) {
            try fm.createDirectory(atPath: settingsDir, withIntermediateDirectories: true)
        }

        var config = try SettingsIO.readJSONOrEmpty(at: settingsPath)

        var hooks = config["hooks"] as? [String: Any] ?? [:]
        var needsWrite = false

        // Clean up legacy string-format hooks (pre-fix: hooks was ["path"] instead of [{"type":"command","command":"path"}])
        for event in hooks.keys {
            if var eventEntries = hooks[event] as? [[String: Any]] {
                let before = eventEntries.count
                eventEntries.removeAll { entry in
                    guard let hooksList = entry["hooks"] as? [Any] else { return false }
                    return hooksList.first is String
                }
                if eventEntries.count != before {
                    hooks[event] = eventEntries.isEmpty ? nil : eventEntries
                    needsWrite = true
                }
            }
        }

        // Register PreToolUse hook
        needsWrite = ensureHookEntry(
            in: &hooks,
            event: "PreToolUse",
            hookPath: hookBinaryPath
        ) || needsWrite

        // Register PostToolUse hook
        needsWrite = ensureHookEntry(
            in: &hooks,
            event: "PostToolUse",
            hookPath: hookBinaryPath
        ) || needsWrite

        if needsWrite {
            config["hooks"] = hooks
            try SettingsIO.writeJSONAtomically(config, to: settingsPath)
        }
    }

    /// Remove senkani-hook entries from a project's .claude/settings.json.
    public static func unregisterForProject(at projectPath: String, hookBinaryPath: String) throws {
        let settingsPath = projectPath + "/.claude/settings.json"
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsPath) else { return }

        var config = try SettingsIO.readJSONOrEmpty(at: settingsPath)
        guard var hooks = config["hooks"] as? [String: Any] else { return }

        var needsWrite = false

        for event in ["PreToolUse", "PostToolUse"] {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            let before = entries.count
            entries.removeAll { entry in
                guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
                return entryHooks.contains { ($0["command"] as? String) == hookBinaryPath }
            }
            if entries.count != before {
                hooks[event] = entries.isEmpty ? nil : entries
                needsWrite = true
            }
        }

        if needsWrite {
            config["hooks"] = hooks.isEmpty ? nil : hooks
            try SettingsIO.writeJSONAtomically(config, to: settingsPath)
        }
    }

    /// Find the senkani-hook binary. Checks next to the senkani binary first,
    /// then falls back to common install locations.
    public static func findHookBinary() -> String? {
        let fm = FileManager.default

        // Check next to the main binary
        let mainBinary = AutoRegistration.resolveBinaryPath()
        let dir = (mainBinary as NSString).deletingLastPathComponent
        let candidate = dir + "/senkani-hook"
        if fm.isExecutableFile(atPath: candidate) {
            return candidate
        }

        // Check common locations
        for path in [
            "/usr/local/bin/senkani-hook",
            NSHomeDirectory() + "/.local/bin/senkani-hook",
            NSHomeDirectory() + "/.senkani/bin/senkani-hook",
        ] {
            if fm.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    // MARK: - Private

    /// Ensure a hook entry exists for a given event type.
    /// Returns true if the hooks dict was modified.
    @discardableResult
    private static func ensureHookEntry(
        in hooks: inout [String: Any],
        event: String,
        hookPath: String
    ) -> Bool {
        var entries = hooks[event] as? [[String: Any]] ?? []

        // Check if already registered (correct format: [{"type":"command","command":"..."}])
        let alreadyRegistered = entries.contains { entry in
            guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
            return entryHooks.contains { ($0["command"] as? String) == hookPath }
        }

        guard !alreadyRegistered else {
            // Migrate empty matchers to specific matchers (Lesson #5 fix)
            var migrated = false
            for i in entries.indices {
                if let entryHooks = entries[i]["hooks"] as? [[String: Any]],
                   entryHooks.contains(where: { ($0["command"] as? String) == hookPath }),
                   (entries[i]["matcher"] as? String) == "" {
                    entries[i]["matcher"] = "Read|Bash|Grep|Write|Edit"
                    migrated = true
                }
            }
            if migrated {
                hooks[event] = entries
                return true
            }
            return false
        }

        // Match specific built-in tools only — never empty (Lesson #5).
        // Claude Code matchers use regex: "Read|Bash|Grep|Write|Edit"
        entries.append([
            "matcher": "Read|Bash|Grep|Write|Edit",
            "hooks": [["type": "command", "command": hookPath]],
        ] as [String: Any])

        hooks[event] = entries
        return true
    }

}
