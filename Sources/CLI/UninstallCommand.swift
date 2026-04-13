import ArgumentParser
import Foundation
import Core

struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove all Senkani configuration, hooks, and data."
    )

    @Flag(name: .long, help: "Skip confirmation prompt.")
    var yes = false

    @Flag(name: .long, help: "Keep session data (SQLite database and metrics). Only remove config and hooks.")
    var keepData = false

    func run() throws {
        let items = scanForArtifacts()

        if items.isEmpty {
            print("Nothing to uninstall — no Senkani artifacts found.")
            return
        }

        print("")
        print("Senkani Uninstall")
        print("=================")
        print("")
        print("The following will be removed:")
        print("")
        for item in items {
            print("  \(item.icon) \(item.description)")
        }

        if keepData {
            print("")
            print("  (--keep-data: session database and metrics will be preserved)")
        }

        print("")

        if !yes {
            print("Proceed? [y/N] ", terminator: "")
            guard let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" else {
                print("Cancelled.")
                return
            }
        }

        print("")

        var removed = 0
        var failed = 0

        for item in items {
            do {
                try item.remove()
                print("  \u{2713} \(item.description)")
                removed += 1
            } catch {
                print("  \u{2717} \(item.description) — \(error.localizedDescription)")
                failed += 1
            }
        }

        print("")
        if failed == 0 {
            print("Senkani uninstalled (\(removed) items removed).")
        } else {
            print("Partially uninstalled: \(removed) removed, \(failed) failed.")
        }
        print("Restart Claude Code to complete.")
        print("")
    }

    // MARK: - Artifact Scanning

    private struct Artifact {
        let icon: String
        let description: String
        let remove: () throws -> Void
    }

    private func scanForArtifacts() -> [Artifact] {
        var items: [Artifact] = []
        let fm = FileManager.default

        // 1. Global MCP registration in ~/.claude/settings.json
        let globalSettings = NSHomeDirectory() + "/.claude/settings.json"
        if fm.fileExists(atPath: globalSettings),
           let data = fm.contents(atPath: globalSettings),
           let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let servers = config["mcpServers"] as? [String: Any],
           servers["senkani"] != nil || servers["senkani-daemon"] != nil {
            items.append(Artifact(
                icon: "⚙",
                description: "MCP registration in ~/.claude/settings.json",
                remove: { try Self.removeGlobalMCPEntry() }
            ))
        }

        // 2. Project-level hook registrations in ~/.claude/projects/*/settings.json
        let projectsDir = NSHomeDirectory() + "/.claude/projects"
        if fm.fileExists(atPath: projectsDir),
           let entries = try? fm.contentsOfDirectory(atPath: projectsDir) {
            let hookProjects = entries.filter { entry in
                let path = projectsDir + "/" + entry + "/settings.json"
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
                    icon: "🪝",
                    description: "Hook registrations in \(hookProjects.count) project settings file(s)",
                    remove: { Self.removeAllProjectHooks(projectsDir: projectsDir, entries: hookProjects) }
                ))
            }
        }

        // 3. Hook binary at ~/.senkani/bin/senkani-hook
        if fm.fileExists(atPath: AutoRegistration.hookWrapperPath) {
            items.append(Artifact(
                icon: "🔨",
                description: "Hook binary at ~/.senkani/bin/senkani-hook",
                remove: { try fm.removeItem(atPath: AutoRegistration.hookWrapperPath) }
            ))
        }

        // 4. Senkani runtime directory ~/.senkani/
        let senkaniDir = NSHomeDirectory() + "/.senkani"
        if fm.fileExists(atPath: senkaniDir) {
            items.append(Artifact(
                icon: "📁",
                description: "Runtime directory ~/.senkani/ (workspace, metrics, sockets, panes)",
                remove: { try fm.removeItem(atPath: senkaniDir) }
            ))
        }

        // 5. Session database at ~/Library/Application Support/Senkani/
        if !keepData {
            let appSupport = fm.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!.appendingPathComponent("Senkani").path
            if fm.fileExists(atPath: appSupport) {
                items.append(Artifact(
                    icon: "🗄",
                    description: "Session database at ~/Library/Application Support/Senkani/",
                    remove: { try fm.removeItem(atPath: appSupport) }
                ))
            }
        }

        // 6. Launchd plists (from senkani schedule)
        let launchAgentsDir = NSHomeDirectory() + "/Library/LaunchAgents"
        if fm.fileExists(atPath: launchAgentsDir),
           let agents = try? fm.contentsOfDirectory(atPath: launchAgentsDir) {
            let senkaniPlists = agents.filter { $0.hasPrefix("com.senkani.") && $0.hasSuffix(".plist") }
            if !senkaniPlists.isEmpty {
                items.append(Artifact(
                    icon: "📋",
                    description: "\(senkaniPlists.count) launchd plist(s) in ~/Library/LaunchAgents/",
                    remove: {
                        for plist in senkaniPlists {
                            let path = launchAgentsDir + "/" + plist
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

        // 7. Per-project .senkani/ directories (symbol index, baselines)
        let workspacePath = NSHomeDirectory() + "/.senkani/workspace.json"
        if let data = fm.contents(atPath: workspacePath),
           let workspace = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let projects = workspace["projects"] as? [[String: Any]] {
            let senkaniDirs = projects.compactMap { project -> String? in
                guard let path = project["path"] as? String else { return nil }
                let dir = path + "/.senkani"
                return fm.fileExists(atPath: dir) ? dir : nil
            }
            if !senkaniDirs.isEmpty {
                items.append(Artifact(
                    icon: "📂",
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

    // MARK: - Removal Helpers

    private static func removeGlobalMCPEntry() throws {
        let settingsPath = NSHomeDirectory() + "/.claude/settings.json"
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

    private static func removeAllProjectHooks(projectsDir: String, entries: [String]) {
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
