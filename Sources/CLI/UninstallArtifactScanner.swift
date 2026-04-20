import Foundation
import Core

/// Artifact discovery + removal for `senkani uninstall`, factored out so the
/// discovery logic can be exercised against a fixture HOME + appSupport dir.
/// `UninstallCommand` constructs this with real paths (`NSHomeDirectory()` +
/// `~/Library/Application Support/Senkani`); tests seed a tmp dir and pass it
/// in. The seven categories mirror the `senkani uninstall` manual contract
/// documented in `cleanup.md` #15.
struct UninstallArtifactScanner {
    /// The seven artifact categories `senkani uninstall` can remove. The
    /// string value is a stable identifier for assertions; user-facing text
    /// lives in `Artifact.description`.
    enum Category: String, CaseIterable, Sendable {
        case globalMCPRegistration
        case projectHooks
        case hookBinary
        case runtimeDirectory
        case sessionDatabase
        case launchdPlists
        case perProjectSenkaniDirs
    }

    struct Artifact {
        let category: Category
        let icon: String
        let description: String
        let remove: () throws -> Void
    }

    let homeDir: String
    let appSupportDir: String
    let keepData: Bool
    private let fm: FileManager

    init(homeDir: String, appSupportDir: String, keepData: Bool, fm: FileManager = .default) {
        self.homeDir = homeDir
        self.appSupportDir = appSupportDir
        self.keepData = keepData
        self.fm = fm
    }

    var globalSettingsPath: String { homeDir + "/.claude/settings.json" }
    var projectsDir: String { homeDir + "/.claude/projects" }
    var hookBinaryPath: String { homeDir + "/.senkani/bin/senkani-hook" }
    var runtimeDir: String { homeDir + "/.senkani" }
    var launchAgentsDir: String { homeDir + "/Library/LaunchAgents" }
    var workspacePath: String { homeDir + "/.senkani/workspace.json" }

    func scan() -> [Artifact] {
        var items: [Artifact] = []
        let fm = self.fm

        // 1. Global MCP registration in <home>/.claude/settings.json
        let globalSettings = globalSettingsPath
        if fm.fileExists(atPath: globalSettings),
           let data = fm.contents(atPath: globalSettings),
           let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let servers = config["mcpServers"] as? [String: Any],
           servers["senkani"] != nil || servers["senkani-daemon"] != nil {
            items.append(Artifact(
                category: .globalMCPRegistration,
                icon: "\u{2699}",
                description: "MCP registration in ~/.claude/settings.json",
                remove: { try Self.removeGlobalMCPEntry(at: globalSettings) }
            ))
        }

        // 2. Project-level hook registrations — senkani-only entries.
        let projects = projectsDir
        if fm.fileExists(atPath: projects),
           let entries = try? fm.contentsOfDirectory(atPath: projects) {
            let hookProjects = entries.filter { entry in
                let path = projects + "/" + entry + "/settings.json"
                guard let data = fm.contents(atPath: path),
                      let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let hooks = config["hooks"] as? [String: Any] else { return false }
                for (_, value) in hooks {
                    guard let eventEntries = value as? [[String: Any]] else { continue }
                    for entry in eventEntries {
                        guard let hookList = entry["hooks"] as? [[String: Any]] else { continue }
                        if hookList.contains(where: { ($0["command"] as? String)?.contains("senkani") ?? false }) {
                            return true
                        }
                    }
                }
                return false
            }
            if !hookProjects.isEmpty {
                items.append(Artifact(
                    category: .projectHooks,
                    icon: "\u{1FA9D}",
                    description: "Hook registrations in \(hookProjects.count) project settings file(s)",
                    remove: { Self.removeAllProjectHooks(projectsDir: projects, entries: hookProjects) }
                ))
            }
        }

        // 3. Hook binary at <home>/.senkani/bin/senkani-hook
        let hookBin = hookBinaryPath
        if fm.fileExists(atPath: hookBin) {
            items.append(Artifact(
                category: .hookBinary,
                icon: "\u{1F528}",
                description: "Hook binary at ~/.senkani/bin/senkani-hook",
                remove: { try fm.removeItem(atPath: hookBin) }
            ))
        }

        // 4. Senkani runtime directory <home>/.senkani/
        let senkaniDir = runtimeDir
        if fm.fileExists(atPath: senkaniDir) {
            items.append(Artifact(
                category: .runtimeDirectory,
                icon: "\u{1F4C1}",
                description: "Runtime directory ~/.senkani/ (workspace, metrics, sockets, panes)",
                remove: { try fm.removeItem(atPath: senkaniDir) }
            ))
        }

        // 5. Session database at <appSupport>/ (skipped when keepData).
        if !keepData {
            let appSupport = appSupportDir
            if fm.fileExists(atPath: appSupport) {
                items.append(Artifact(
                    category: .sessionDatabase,
                    icon: "\u{1F5C4}",
                    description: "Session database at ~/Library/Application Support/Senkani/",
                    remove: { try fm.removeItem(atPath: appSupport) }
                ))
            }
        }

        // 6. Launchd plists — only com.senkani.*.plist under ~/Library/LaunchAgents.
        let launchDir = launchAgentsDir
        if fm.fileExists(atPath: launchDir),
           let agents = try? fm.contentsOfDirectory(atPath: launchDir) {
            let senkaniPlists = agents.filter { $0.hasPrefix("com.senkani.") && $0.hasSuffix(".plist") }
            if !senkaniPlists.isEmpty {
                items.append(Artifact(
                    category: .launchdPlists,
                    icon: "\u{1F4CB}",
                    description: "\(senkaniPlists.count) launchd plist(s) in ~/Library/LaunchAgents/",
                    remove: {
                        for plist in senkaniPlists {
                            let path = launchDir + "/" + plist
                            let proc = Process()
                            proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                            proc.arguments = ["unload", path]
                            proc.standardOutput = FileHandle.nullDevice
                            proc.standardError = FileHandle.nullDevice
                            try? proc.run()
                            proc.waitUntilExit()
                            try fm.removeItem(atPath: path)
                        }
                    }
                ))
            }
        }

        // 7. Per-project .senkani/ directories — discovered via workspace.json.
        if let data = fm.contents(atPath: workspacePath),
           let workspace = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let projectList = workspace["projects"] as? [[String: Any]] {
            let senkaniDirs = projectList.compactMap { project -> String? in
                guard let path = project["path"] as? String else { return nil }
                let dir = path + "/.senkani"
                return fm.fileExists(atPath: dir) ? dir : nil
            }
            if !senkaniDirs.isEmpty {
                items.append(Artifact(
                    category: .perProjectSenkaniDirs,
                    icon: "\u{1F4C2}",
                    description: ".senkani/ directories in \(senkaniDirs.count) project(s) (symbol indexes)",
                    remove: {
                        for dir in senkaniDirs {
                            try? fm.removeItem(atPath: dir)
                        }
                    }
                ))
            }
        }

        return items
    }

    // MARK: - Removal helpers

    static func removeGlobalMCPEntry(at settingsPath: String) throws {
        var config = try SettingsIO.readJSONOrEmpty(at: settingsPath)
        guard var mcpServers = config["mcpServers"] as? [String: Any] else { return }

        mcpServers.removeValue(forKey: "senkani")
        mcpServers.removeValue(forKey: "senkani-daemon")

        if mcpServers.isEmpty {
            config.removeValue(forKey: "mcpServers")
        } else {
            config["mcpServers"] = mcpServers
        }

        try SettingsIO.writeJSONAtomically(config, to: settingsPath)
    }

    static func removeAllProjectHooks(projectsDir: String, entries: [String]) {
        for entry in entries {
            let settingsPath = projectsDir + "/" + entry + "/settings.json"
            guard var config = try? SettingsIO.readJSONOrEmpty(at: settingsPath) else { continue }
            guard var hooks = config["hooks"] as? [String: Any] else { continue }

            var modified = false
            for event in ["PreToolUse", "PostToolUse"] {
                guard var eventEntries = hooks[event] as? [[String: Any]] else { continue }
                let before = eventEntries.count
                eventEntries.removeAll { entry in
                    guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                    return hookList.contains { ($0["command"] as? String)?.contains("senkani") ?? false }
                }
                if eventEntries.count != before {
                    hooks[event] = eventEntries.isEmpty ? nil : eventEntries
                    modified = true
                }
            }

            if modified {
                let remaining = hooks.compactMapValues { $0 }
                config["hooks"] = remaining.isEmpty ? nil : remaining
                try? SettingsIO.writeJSONAtomically(config, to: settingsPath)
            }
        }
    }
}
