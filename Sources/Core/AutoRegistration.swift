import Foundation

/// Cleans up Senkani's footprint from global Claude settings on every launch.
///
/// Senkani does NOT register globally in ~/.claude/settings.json. MCP access
/// is provided per-pane via .mcp.json files written by PaneModel.writeMCPConfig().
///
/// This module runs defensive cleanup: removes any leftover global MCP entries,
/// hooks, and legacy artifacts from previous versions.
///
/// Every method is idempotent -- safe to call on every launch.
public enum AutoRegistration {

    // MARK: - Public API

    /// Clean up Senkani's footprint from global ~/.claude/settings.json.
    /// Removes: global MCP registration, hooks, legacy senkani-daemon entry.
    /// Does NOT register anything — MCP is provided per-pane via .mcp.json.
    public static func cleanupGlobalSettings() throws {
        let settingsPath = NSHomeDirectory() + "/.claude/settings.json"

        var config = try SettingsIO.readJSONOrEmpty(at: settingsPath)
        var needsWrite = false

        // STEP 1: Remove ALL hooks unconditionally. FIRST. Every launch. No exceptions.
        // Senkani must never pollute the global Claude Code hook chain.
        if config["hooks"] != nil {
            config.removeValue(forKey: "hooks")
            needsWrite = true
            logWarning("Removed hooks from global settings.json")
        }

        // Write immediately if hooks were found — don't risk them surviving a crash
        if needsWrite {
            try SettingsIO.writeJSONAtomically(config, to: settingsPath)
            needsWrite = false
        }

        // STEP 2: Clean project-level hooks in ~/.claude/projects/*/settings.json
        cleanAllProjectHooks()

        // STEP 3: Remove global MCP registration — Senkani should not be in global settings.
        // MCP access is provided per-pane via .mcp.json written by PaneModel.
        var mcpServers = config["mcpServers"] as? [String: Any] ?? [:]

        if mcpServers["senkani"] != nil {
            mcpServers.removeValue(forKey: "senkani")
            if mcpServers.isEmpty {
                config.removeValue(forKey: "mcpServers")
            } else {
                config["mcpServers"] = mcpServers
            }
            needsWrite = true
            logWarning("Removed global senkani MCP registration (now per-pane via .mcp.json)")
        }

        // Clean up legacy senkani-daemon entry
        if mcpServers["senkani-daemon"] != nil {
            mcpServers.removeValue(forKey: "senkani-daemon")
            if mcpServers.isEmpty {
                config.removeValue(forKey: "mcpServers")
            } else {
                config["mcpServers"] = mcpServers
            }
            needsWrite = true
        }

        if needsWrite {
            try SettingsIO.writeJSONAtomically(config, to: settingsPath)
        }
    }

    /// Clean up legacy senkani-intercept.sh hooks from project-level settings.
    /// Only removes hook entries whose path contains "senkani-intercept.sh".
    /// Preserves all other hooks (user hooks, other tools, senkani-hook binary).
    private static func cleanAllProjectHooks() {
        let projectsDir = NSHomeDirectory() + "/.claude/projects"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: projectsDir) else { return }

        for entry in entries {
            let settingsPath = projectsDir + "/" + entry + "/settings.json"
            guard fm.fileExists(atPath: settingsPath) else { continue }
            guard var config = try? SettingsIO.readJSONOrEmpty(at: settingsPath) else { continue }
            guard var hooks = config["hooks"] as? [String: Any] else { continue }

            var modified = false

            for event in hooks.keys {
                guard var eventEntries = hooks[event] as? [[String: Any]] else { continue }
                let before = eventEntries.count
                eventEntries.removeAll { entry in
                    guard let hookPaths = entry["hooks"] as? [String] else { return false }
                    return hookPaths.contains { $0.contains("senkani-intercept.sh") }
                }
                if eventEntries.count != before {
                    hooks[event] = eventEntries.isEmpty ? nil : eventEntries
                    modified = true
                }
            }

            if modified {
                // Remove empty hooks dict
                let remaining = hooks.compactMapValues { $0 }
                config["hooks"] = remaining.isEmpty ? nil : remaining
                try? SettingsIO.writeJSONAtomically(config, to: settingsPath)
                logWarning("Cleaned legacy senkani-intercept.sh hooks from: \(entry)/settings.json")
            }
        }
    }

    // MARK: - Hook Wrapper

    /// The stable path where the hook wrapper script lives.
    public static let hookWrapperPath = NSHomeDirectory() + "/.senkani/bin/senkani-hook"

    /// Install the hook binary at ~/.senkani/bin/senkani-hook.
    /// Prefers a compiled Mach-O binary (fast, <5ms). Falls back to a bash
    /// wrapper that invokes the app binary with --hook (~300ms).
    /// Idempotent — safe to call on every launch.
    public static func installHookWrapper() {
        let hookDir = NSHomeDirectory() + "/.senkani/bin"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: hookDir, withIntermediateDirectories: true)

        // If a compiled Mach-O binary is already deployed, don't overwrite
        if fm.isExecutableFile(atPath: hookWrapperPath), isMachOBinary(at: hookWrapperPath) {
            return
        }

        // Try to find the compiled senkani-hook binary
        if let compiledPath = findCompiledHookBinary() {
            try? fm.removeItem(atPath: hookWrapperPath)
            try? fm.copyItem(atPath: compiledPath, toPath: hookWrapperPath)
            chmod(hookWrapperPath, 0o755)
            return
        }

        // Fallback: bash wrapper that invokes the app binary with --hook
        let appBinary = resolveBinaryPath()
        let script = "#!/bin/bash\nexec \"\(appBinary)\" --hook"
        try? script.write(toFile: hookWrapperPath, atomically: true, encoding: .utf8)
        chmod(hookWrapperPath, 0o755)
    }

    // MARK: - Private: Binary Resolution

    /// Resolve the path to the Senkani binary.
    /// Prefers Bundle.main.executablePath for .app bundles, falls back to argv[0].
    public static func resolveBinaryPath() -> String {
        // In a .app bundle, Bundle.main.executablePath points inside Contents/MacOS/
        if let bundlePath = Bundle.main.executablePath,
           bundlePath.contains(".app/") {
            return bundlePath
        }

        // CLI / direct invocation
        let argv0 = ProcessInfo.processInfo.arguments[0]
        if argv0.hasPrefix("/") {
            return argv0
        }

        // Relative path -- resolve against cwd
        return FileManager.default.currentDirectoryPath + "/" + argv0
    }

    /// Check if a file is a compiled Mach-O binary (not a bash script).
    /// Checks for Mach-O magic bytes: MH_MAGIC_64, MH_CIGAM_64, or FAT_MAGIC.
    public static func isMachOBinary(at path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { handle.closeFile() }
        let magic = handle.readData(ofLength: 4)
        guard magic.count == 4 else { return false }
        return magic == Data([0xCF, 0xFA, 0xED, 0xFE]) ||
               magic == Data([0xFE, 0xED, 0xFA, 0xCF]) ||
               magic == Data([0xCA, 0xFE, 0xBA, 0xBE])
    }

    /// Search for a compiled senkani-hook binary in known locations.
    private static func findCompiledHookBinary() -> String? {
        let fm = FileManager.default

        // 1. Next to the running binary (works in DerivedData during development)
        let mainBinary = resolveBinaryPath()
        var dir = (mainBinary as NSString).deletingLastPathComponent
        // If inside .app bundle (Contents/MacOS/), go up to the Products directory
        if dir.hasSuffix("Contents/MacOS") {
            dir = ((dir as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        }
        let devCandidate = dir + "/senkani-hook"
        if fm.isExecutableFile(atPath: devCandidate), isMachOBinary(at: devCandidate) {
            return devCandidate
        }

        // 2. SPM .build/release/ — walk up from mainBinary
        var searchDir = (mainBinary as NSString).deletingLastPathComponent
        for _ in 0..<5 {
            let spmCandidate = searchDir + "/.build/release/senkani-hook"
            if fm.isExecutableFile(atPath: spmCandidate), isMachOBinary(at: spmCandidate) {
                return spmCandidate
            }
            searchDir = (searchDir as NSString).deletingLastPathComponent
        }

        // 3. Common install locations
        for path in [
            "/usr/local/bin/senkani-hook",
            NSHomeDirectory() + "/.local/bin/senkani-hook",
        ] {
            if fm.isExecutableFile(atPath: path), isMachOBinary(at: path) {
                return path
            }
        }

        return nil
    }

    private static func logWarning(_ message: String) {
        FileHandle.standardError.write(Data("[senkani] \(message)\n".utf8))
    }
}
