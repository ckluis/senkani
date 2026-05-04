import Foundation
import Core

/// Artifact discovery + removal for `senkani uninstall`, factored out so the
/// discovery logic can be exercised against a fixture HOME + appSupport dir.
/// `UninstallCommand` constructs this with real paths (`NSHomeDirectory()` +
/// `~/Library/Application Support/Senkani`); tests seed a tmp dir and pass it
/// in. The nine categories mirror the `senkani uninstall` manual contract
/// originally documented in `cleanup.md` #15.
///
/// Category-8 (`webContentRuleLists`) was added 2026-05-02 after the
/// `release-v0-3-0-uninstall-pass` walk's broad orphan sweep
/// (`uninstall-scanner-audit-claude-global-paths` backlog item) surfaced
/// senkani-prefixed `WKContentRuleList` files surviving a full `--yes`
/// uninstall under `~/Library/WebKit/<bundle>/ContentRuleLists/`. The
/// rule list itself is Senkani-defined data (compiled from
/// `WebContentBlocklist.rulesJSON` via `WKContentRuleListStore`), even
/// though the parent directory is macOS-managed.
///
/// Category-9 (`modelMetadataCache`) was added 2026-05-03 after the
/// `release-v0-3-0-uninstall-pass-v2-plan-amendments` walk's Step 8 broad
/// orphan sweep (`uninstall-scanner-audit-claude-hook-and-library-caches`
/// backlog item) caught `~/Library/Caches/dev.senkani/` surviving a full
/// `--yes` uninstall. The directory is bundle-id-named so it looks
/// macOS-managed, but `Sources/Core/ModelManager.swift` actively writes
/// `models/models.json` (model registry metadata) into it from any
/// senkani-using process — making the dir Senkani-managed state, not an
/// OS cache. Removal strips the whole `dev.senkani/` subtree.
///
/// Out-of-scope (by design — verified 2026-05-03):
/// - `~/Library/Caches/SenkaniApp` — macOS-managed (auto-created per
///   bundle name; no Senkani write code path).
/// - `~/Library/Caches/senkani-mcp` — macOS-managed (auto-created per
///   binary name; no Senkani write code path).
/// - `~/Library/HTTPStorages/{SenkaniApp,senkani-mcp}` — macOS-managed.
/// - `~/Library/Preferences/SenkaniApp.plist` — NSUserDefaults.
/// - `~/Library/Application Support/CrashReporter/{senkani-mcp,SenkaniApp}_*.plist` — system-managed.
/// - `~/.claude/hooks/senkani-hook.sh`, `~/.claude/skills/senkani-autonomous` —
///   NOT senkani-written; sourced from operator tooling (e.g. gstack)
///   or Claude Code itself. Senkani's hook lives at
///   `~/.senkani/bin/senkani-hook` (category-3, `hookBinary`).
struct UninstallArtifactScanner {
    /// The nine artifact categories `senkani uninstall` can remove. The
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
        case webContentRuleLists
        case modelMetadataCache
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
    var webKitDir: String { homeDir + "/Library/WebKit" }
    var modelMetadataCacheDir: String { homeDir + "/Library/Caches/dev.senkani" }

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
        // Two locations are checked:
        //   (a) Modern (HookRegistration.registerForProject):
        //       <projectPath>/.claude/settings.json — discovered via
        //       workspace.json's project list.
        //   (b) Legacy: ~/.claude/projects/<encoded>/settings.json — earlier
        //       installer location, still scanned for back-compat with
        //       installs that pre-date the per-project move.
        // Both produce the same artifact category; the discovery is unified
        // so a single approval prompt removes them all.
        var hookSettingsFiles: [String] = []

        // (a) Modern — walk workspace.json
        if let data = fm.contents(atPath: workspacePath),
           let workspace = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let projectList = workspace["projects"] as? [[String: Any]] {
            for project in projectList {
                guard let path = project["path"] as? String else { continue }
                let settingsPath = path + "/.claude/settings.json"
                if Self.fileHasSenkaniHooks(settingsPath, fm: fm) {
                    hookSettingsFiles.append(settingsPath)
                }
            }
        }

        // (b) Legacy — walk ~/.claude/projects/*
        let projects = projectsDir
        if fm.fileExists(atPath: projects),
           let entries = try? fm.contentsOfDirectory(atPath: projects) {
            for entry in entries {
                let path = projects + "/" + entry + "/settings.json"
                if Self.fileHasSenkaniHooks(path, fm: fm) {
                    hookSettingsFiles.append(path)
                }
            }
        }

        if !hookSettingsFiles.isEmpty {
            let paths = hookSettingsFiles  // capture for the closure
            items.append(Artifact(
                category: .projectHooks,
                icon: "\u{1FA9D}",
                description: "Hook registrations in \(hookSettingsFiles.count) project settings file(s)",
                remove: { Self.removeProjectHooksFromFiles(paths) }
            ))
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

        // 8. WebKit content rule lists — `WebContentBlocklist.compile()` writes
        // `ContentRuleList-senkani.web.subresource-blocklist.v<N>` under
        // `~/Library/WebKit/<bundle>/ContentRuleLists/`. The compile call is
        // made by every senkani-using process that uses WebKit (the main
        // SenkaniApp bundle, plus `swiftpm-testing-helper` /
        // `com.apple.dt.xctest.tool` when integration tests run), so the
        // file lands under multiple bundle dirs. Walk every WebKit subdir's
        // ContentRuleLists folder and collect senkani-prefixed files.
        let webKit = webKitDir
        if fm.fileExists(atPath: webKit),
           let bundles = try? fm.contentsOfDirectory(atPath: webKit) {
            var ruleLists: [String] = []
            for bundle in bundles {
                let listsDir = webKit + "/" + bundle + "/ContentRuleLists"
                guard let files = try? fm.contentsOfDirectory(atPath: listsDir) else { continue }
                for file in files where file.hasPrefix("ContentRuleList-senkani") {
                    ruleLists.append(listsDir + "/" + file)
                }
            }
            if !ruleLists.isEmpty {
                let paths = ruleLists  // capture for the closure
                items.append(Artifact(
                    category: .webContentRuleLists,
                    icon: "\u{1F310}",
                    description: "\(ruleLists.count) WebKit content rule list(s) under ~/Library/WebKit/",
                    remove: {
                        for path in paths {
                            try? fm.removeItem(atPath: path)
                        }
                    }
                ))
            }
        }

        // 9. Model metadata cache at ~/Library/Caches/dev.senkani/.
        // `ModelManager.shared` (Sources/Core/ModelManager.swift) writes
        // `dev.senkani/models/models.json` — the model registry's
        // download/verification status. The directory is bundle-id-named
        // but Senkani-written from any senkani CLI / senkani-mcp /
        // SenkaniApp invocation. Strip the whole subtree because future
        // ModelManager extensions may drop sibling files (eval scratch,
        // weight checksums) into the same dir.
        let modelCache = modelMetadataCacheDir
        if fm.fileExists(atPath: modelCache) {
            items.append(Artifact(
                category: .modelMetadataCache,
                icon: "\u{1F4BE}",
                description: "Model metadata cache at ~/Library/Caches/dev.senkani/",
                remove: { try fm.removeItem(atPath: modelCache) }
            ))
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

    /// True when `settingsPath` is a Claude Code config file containing at
    /// least one hook entry whose `command` mentions "senkani". Returns
    /// false for missing files, non-JSON files, files without a `hooks`
    /// key, and files whose hooks are all from other tools.
    static func fileHasSenkaniHooks(_ settingsPath: String, fm: FileManager) -> Bool {
        guard let data = fm.contents(atPath: settingsPath),
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

    /// Strip senkani hook entries from each `settings.json` path. Preserves
    /// any non-senkani hooks in the same file. Drops the empty `hooks` key
    /// when no entries remain. Per-file errors (unreadable JSON, write
    /// failure) are suppressed — uninstall is best-effort and shouldn't
    /// abort because one project's settings are malformed.
    static func removeProjectHooksFromFiles(_ settingsPaths: [String]) {
        for settingsPath in settingsPaths {
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
