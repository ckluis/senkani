import Testing
import Foundation
@testable import CLI

/// Bach G6 / cleanup.md #15: automated smoke for `senkani uninstall`.
///
/// Real-machine validation (running uninstall against a live dev install)
/// stays on `tools/soak/manual-log.md` — it's the only way to catch a new
/// artifact path the discovery code forgot. This suite fences the
/// discovery + filter + removal logic against regressions by seeding a
/// fixture HOME under a tmp dir and running the scanner against it.
///
/// Every test isolates itself under a unique tmp dir and never reads or
/// writes `NSHomeDirectory()`.
@Suite("senkani uninstall — scanner smoke")
struct UninstallSmokeTests {

    // MARK: - Fixture helpers

    private final class Fixture {
        let root: URL
        let home: String
        let appSupport: String

        init() throws {
            let base = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("senkani-uninstall-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.root = base
            self.home = base.appendingPathComponent("home").path
            self.appSupport = base.appendingPathComponent("appSupport/Senkani").path
            try FileManager.default.createDirectory(
                atPath: home, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        /// Seed every one of the 9 categories that the scanner knows about.
        func seedAll() throws {
            try seedGlobalMCPRegistration()
            try seedProjectHooks()
            try seedHookBinary()
            try seedRuntimeDirectory()     // also creates workspace.json
            try seedSessionDatabase()
            try seedLaunchdPlist()
            try seedPerProjectSenkaniDirs()
            try seedWebContentRuleLists()
            try seedModelMetadataCache()
        }

        func seedGlobalMCPRegistration() throws {
            let claudeDir = home + "/.claude"
            try FileManager.default.createDirectory(
                atPath: claudeDir, withIntermediateDirectories: true)
            let settings: [String: Any] = [
                "mcpServers": [
                    "senkani": ["command": "/usr/local/bin/senkani-mcp"],
                    "unrelated": ["command": "/opt/other"]
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: settings)
            try data.write(to: URL(fileURLWithPath: claudeDir + "/settings.json"))
        }

        /// Seed senkani-hooked + unrelated-hooked projects in BOTH locations
        /// the scanner checks:
        ///   (a) Modern: <projectPath>/.claude/settings.json — registered
        ///       in workspace.json's project list. This is where
        ///       HookRegistration.registerForProject writes hooks today.
        ///   (b) Legacy: ~/.claude/projects/<encoded>/settings.json — older
        ///       installer location, still scanned for back-compat.
        /// The scanner must pick up only the senkani-hooked entries from
        /// each location and ignore the unrelated ones.
        func seedProjectHooks() throws {
            let fm = FileManager.default

            let senkaniHookEntry: [String: Any] = [
                "hooks": [
                    "PreToolUse": [[
                        "matcher": "*",
                        "hooks": [[
                            "type": "command",
                            "command": home + "/.senkani/bin/senkani-hook"
                        ]]
                    ]]
                ]
            ]
            let unrelatedHookEntry: [String: Any] = [
                "hooks": [
                    "PreToolUse": [[
                        "matcher": "*",
                        "hooks": [[
                            "type": "command",
                            "command": "/opt/other/hook"
                        ]]
                    ]]
                ]
            ]

            // (a) Modern — workspace project dir with .claude/settings.json.
            // Append to workspace.json so seedPerProjectSenkaniDirs can extend
            // it later without clobbering our entries.
            let modernSenkaniProj = root.appendingPathComponent("projModernSenkani").path
            let modernUnrelatedProj = root.appendingPathComponent("projModernUnrelated").path
            try fm.createDirectory(atPath: modernSenkaniProj + "/.claude",
                                   withIntermediateDirectories: true)
            try fm.createDirectory(atPath: modernUnrelatedProj + "/.claude",
                                   withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: senkaniHookEntry)
                .write(to: URL(fileURLWithPath: modernSenkaniProj + "/.claude/settings.json"))
            try JSONSerialization.data(withJSONObject: unrelatedHookEntry)
                .write(to: URL(fileURLWithPath: modernUnrelatedProj + "/.claude/settings.json"))
            try mergeWorkspaceProjects([modernSenkaniProj, modernUnrelatedProj])

            // (b) Legacy — encoded-path dir in ~/.claude/projects/.
            let legacySenkaniProj = home + "/.claude/projects/proj-senkani"
            let legacyUnrelatedProj = home + "/.claude/projects/proj-other"
            try fm.createDirectory(atPath: legacySenkaniProj, withIntermediateDirectories: true)
            try fm.createDirectory(atPath: legacyUnrelatedProj, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: senkaniHookEntry)
                .write(to: URL(fileURLWithPath: legacySenkaniProj + "/settings.json"))
            try JSONSerialization.data(withJSONObject: unrelatedHookEntry)
                .write(to: URL(fileURLWithPath: legacyUnrelatedProj + "/settings.json"))
        }

        /// Append project paths to workspace.json's `projects` list,
        /// creating the file if it doesn't exist. Idempotent. Preserves
        /// any other keys already in the workspace doc.
        private func mergeWorkspaceProjects(_ paths: [String]) throws {
            let fm = FileManager.default
            let senkaniDir = home + "/.senkani"
            try fm.createDirectory(atPath: senkaniDir, withIntermediateDirectories: true)
            let workspacePath = senkaniDir + "/workspace.json"

            var workspace: [String: Any] = [:]
            if let data = fm.contents(atPath: workspacePath),
               let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                workspace = existing
            }
            var projects = workspace["projects"] as? [[String: Any]] ?? []
            for path in paths {
                projects.append(["path": path])
            }
            workspace["projects"] = projects
            try JSONSerialization.data(withJSONObject: workspace)
                .write(to: URL(fileURLWithPath: workspacePath))
        }

        func seedHookBinary() throws {
            let binDir = home + "/.senkani/bin"
            try FileManager.default.createDirectory(
                atPath: binDir, withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8)
                .write(to: URL(fileURLWithPath: binDir + "/senkani-hook"))
        }

        /// Runtime dir also includes workspace.json, which the scanner
        /// reads to discover per-project .senkani dirs.
        func seedRuntimeDirectory() throws {
            let senkaniDir = home + "/.senkani"
            try FileManager.default.createDirectory(
                atPath: senkaniDir, withIntermediateDirectories: true)
            try Data("{}".utf8)
                .write(to: URL(fileURLWithPath: senkaniDir + "/marker"))
        }

        func seedSessionDatabase() throws {
            try FileManager.default.createDirectory(
                atPath: appSupport, withIntermediateDirectories: true)
            try Data().write(to: URL(fileURLWithPath: appSupport + "/senkani.db"))
        }

        /// Two senkani plists + one unrelated one to verify the prefix filter.
        func seedLaunchdPlist() throws {
            let dir = home + "/Library/LaunchAgents"
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
            try Data().write(to: URL(fileURLWithPath: dir + "/com.senkani.schedule.daily.plist"))
            try Data().write(to: URL(fileURLWithPath: dir + "/com.senkani.schedule.hourly.plist"))
            try Data().write(to: URL(fileURLWithPath: dir + "/com.other.service.plist"))
        }

        /// Seed workspace.json listing two real project dirs (inside the
        /// fixture root) each with a `.senkani/` indicator. Additively
        /// extends the workspace.json's projects list — does not clobber
        /// any entries seedProjectHooks may have added earlier.
        func seedPerProjectSenkaniDirs() throws {
            let fm = FileManager.default
            let projA = root.appendingPathComponent("projA").path
            let projB = root.appendingPathComponent("projB").path
            try fm.createDirectory(atPath: projA + "/.senkani", withIntermediateDirectories: true)
            try fm.createDirectory(atPath: projB + "/.senkani", withIntermediateDirectories: true)
            try mergeWorkspaceProjects([projA, projB])
        }

        /// Seed senkani-prefixed `WKContentRuleList` files under three
        /// `~/Library/WebKit/<bundle>/ContentRuleLists/` directories — the
        /// main app bundle plus two swiftpm test-runner bundles, mirroring
        /// the layout the 2026-05-02 walk found on the operator's machine.
        /// Also seeds one unrelated rule list to verify the prefix filter.
        func seedWebContentRuleLists() throws {
            let fm = FileManager.default
            let webKit = home + "/Library/WebKit"
            let bundles = ["SenkaniApp", "swiftpm-testing-helper", "com.apple.dt.xctest.tool"]
            for bundle in bundles {
                let dir = webKit + "/" + bundle + "/ContentRuleLists"
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try Data().write(to: URL(fileURLWithPath:
                    dir + "/ContentRuleList-senkani.web.subresource-blocklist.v1"))
            }
            // Unrelated rule list — must be ignored by the scanner.
            let otherDir = webKit + "/com.cmuxterm.app/ContentRuleLists"
            try fm.createDirectory(atPath: otherDir, withIntermediateDirectories: true)
            try Data().write(to: URL(fileURLWithPath:
                otherDir + "/ContentRuleList-com.apple.WebPrivacy.ResourceMonitorURLsRuleList"))
        }

        /// Seed `~/Library/Caches/dev.senkani/models/models.json` mirroring
        /// `ModelManager.shared`'s metadata-persistence path. Also seeds
        /// the OS-managed sibling caches `~/Library/Caches/SenkaniApp` and
        /// `~/Library/Caches/senkani-mcp` so the scanner's category-9
        /// behavior is exercised against the v2-walk's actual broad-sweep
        /// shape (the scanner must pick up `dev.senkani` and ignore the
        /// other two).
        func seedModelMetadataCache() throws {
            let fm = FileManager.default
            let cacheRoot = home + "/Library/Caches"
            let senkaniCache = cacheRoot + "/dev.senkani/models"
            try fm.createDirectory(atPath: senkaniCache, withIntermediateDirectories: true)
            try Data("{}".utf8)
                .write(to: URL(fileURLWithPath: senkaniCache + "/models.json"))

            // OS-managed siblings — must NOT be flagged.
            try fm.createDirectory(atPath: cacheRoot + "/SenkaniApp",
                                   withIntermediateDirectories: true)
            try fm.createDirectory(atPath: cacheRoot + "/senkani-mcp",
                                   withIntermediateDirectories: true)
        }

        func scanner(keepData: Bool = false) -> UninstallArtifactScanner {
            UninstallArtifactScanner(
                homeDir: home, appSupportDir: appSupport, keepData: keepData)
        }
    }

    // MARK: - Tests

    @Test func discoveryFindsAllNineCategoriesWhenFullySeeded() throws {
        let f = try Fixture()
        try f.seedAll()

        let artifacts = f.scanner().scan()
        let categories = Set(artifacts.map(\.category))

        #expect(categories == Set(UninstallArtifactScanner.Category.allCases),
                "expected all 9 categories, got \(categories.map(\.rawValue).sorted())")
        #expect(artifacts.count == UninstallArtifactScanner.Category.allCases.count,
                "one artifact per category when fully seeded")
    }

    @Test func keepDataOmitsSessionDatabase() throws {
        let f = try Fixture()
        try f.seedAll()

        let categories = Set(f.scanner(keepData: true).scan().map(\.category))

        #expect(!categories.contains(.sessionDatabase),
                "--keep-data must suppress the sessionDatabase artifact")
        #expect(categories.count == UninstallArtifactScanner.Category.allCases.count - 1,
                "all categories minus sessionDatabase are still discovered")
    }

    @Test func keepDataFalseIncludesSessionDatabase() throws {
        let f = try Fixture()
        try f.seedSessionDatabase()

        let categories = Set(f.scanner(keepData: false).scan().map(\.category))

        #expect(categories == [.sessionDatabase],
                "default (keepData=false) on a session-db-only fixture must find exactly sessionDatabase")
    }

    @Test func emptyInstallYieldsNothingToUninstall() throws {
        let f = try Fixture()
        // no seeding

        let artifacts = f.scanner().scan()

        #expect(artifacts.isEmpty,
                "pristine HOME must produce an empty artifact list (idempotent)")
    }

    @Test func removalClearsEverythingAndSecondScanIsIdempotent() throws {
        let f = try Fixture()
        try f.seedAll()

        // First scan should find everything, then removal clears them all.
        let first = f.scanner().scan()
        #expect(first.count == UninstallArtifactScanner.Category.allCases.count)
        for item in first {
            try item.remove()
        }

        // Re-scan after removal: empty (idempotent uninstall).
        let second = f.scanner().scan()
        #expect(second.isEmpty,
                "after remove() on every artifact, scanner must find nothing — got \(second.map(\.category.rawValue))")
    }

    @Test func discoveryFindsModernHookLocationViaWorkspaceJson() throws {
        let f = try Fixture()
        let fm = FileManager.default

        // Modern install: hook lives at <projectPath>/.claude/settings.json,
        // and the project is listed in workspace.json. No legacy hook in
        // ~/.claude/projects/. Pre-fix the scanner missed this entirely.
        let proj = f.root.appendingPathComponent("projModern").path
        try fm.createDirectory(atPath: proj + "/.claude", withIntermediateDirectories: true)
        let settings: [String: Any] = [
            "hooks": [
                "PreToolUse": [[
                    "matcher": "*",
                    "hooks": [[
                        "type": "command",
                        "command": f.home + "/.senkani/bin/senkani-hook"
                    ]]
                ]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: settings)
            .write(to: URL(fileURLWithPath: proj + "/.claude/settings.json"))

        try fm.createDirectory(atPath: f.home + "/.senkani", withIntermediateDirectories: true)
        let workspace: [String: Any] = ["projects": [["path": proj]]]
        try JSONSerialization.data(withJSONObject: workspace)
            .write(to: URL(fileURLWithPath: f.home + "/.senkani/workspace.json"))

        let categories = Set(f.scanner().scan().map(\.category))

        #expect(categories.contains(.projectHooks),
                "modern hook location (<projectPath>/.claude/settings.json) must be discovered via workspace.json")

        // Removal must clear the hook from the modern location.
        for item in f.scanner().scan() where item.category == .projectHooks {
            try item.remove()
        }
        let stripped = try Data(contentsOf: URL(fileURLWithPath: proj + "/.claude/settings.json"))
        let strippedConfig = try JSONSerialization.jsonObject(with: stripped) as? [String: Any]
        #expect((strippedConfig?["hooks"] as? [String: Any]) == nil,
                "after removal, the modern settings.json must have no hooks key (was the only senkani entry)")
    }

    @Test func discoveryFindsWebContentRuleListsAcrossAllBundles() throws {
        let f = try Fixture()
        try f.seedWebContentRuleLists()

        let artifacts = f.scanner().scan()
        let categories = Set(artifacts.map(\.category))

        #expect(categories.contains(.webContentRuleLists),
                "senkani-prefixed WKContentRuleList files must be discovered")
        #expect(artifacts.count == 1, "no other categories were seeded")

        // Description should reflect the count from all three seeded bundles
        // (not the unrelated rule list under com.cmuxterm.app).
        if let item = artifacts.first(where: { $0.category == .webContentRuleLists }) {
            #expect(item.description.contains("3 WebKit content rule list"),
                    "expected count==3 in description, got: \(item.description)")
        }

        // Removal clears all three senkani-prefixed files but leaves the
        // unrelated rule list and the parent ContentRuleLists directories
        // alone (they are macOS-managed; only the senkani-defined data goes).
        for item in artifacts where item.category == .webContentRuleLists {
            try item.remove()
        }

        let fm = FileManager.default
        let webKit = f.home + "/Library/WebKit"
        for bundle in ["SenkaniApp", "swiftpm-testing-helper", "com.apple.dt.xctest.tool"] {
            let path = webKit + "/" + bundle + "/ContentRuleLists/ContentRuleList-senkani.web.subresource-blocklist.v1"
            #expect(!fm.fileExists(atPath: path),
                    "senkani rule list should be gone at \(path)")
        }
        let unrelated = webKit + "/com.cmuxterm.app/ContentRuleLists/ContentRuleList-com.apple.WebPrivacy.ResourceMonitorURLsRuleList"
        #expect(fm.fileExists(atPath: unrelated),
                "unrelated rule list must NOT be removed")

        // Re-scan must be empty (idempotent).
        #expect(f.scanner().scan().isEmpty,
                "after removal, scanner finds nothing")
    }

    @Test func scannerIgnoresNonSenkaniContentRuleLists() throws {
        let f = try Fixture()
        let fm = FileManager.default

        // Only seed an unrelated rule list — no senkani prefix.
        let dir = f.home + "/Library/WebKit/com.cmuxterm.app/ContentRuleLists"
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath:
            dir + "/ContentRuleList-com.apple.WebPrivacy.ResourceMonitorURLsRuleList"))

        let categories = Set(f.scanner().scan().map(\.category))
        #expect(!categories.contains(.webContentRuleLists),
                "non-senkani-prefixed rule lists must not be flagged for removal")
    }

    @Test func scannerIgnoresNonSenkaniHooksAndPlists() throws {
        let f = try Fixture()
        // Seed ONLY the unrelated surfaces — no senkani artifacts.
        let fm = FileManager.default
        let unrelatedProj = f.home + "/.claude/projects/proj-other"
        try fm.createDirectory(atPath: unrelatedProj, withIntermediateDirectories: true)
        let unrelatedSettings: [String: Any] = [
            "hooks": [
                "PreToolUse": [[
                    "matcher": "*",
                    "hooks": [["type": "command", "command": "/opt/other/hook"]]
                ]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: unrelatedSettings)
            .write(to: URL(fileURLWithPath: unrelatedProj + "/settings.json"))

        let launchDir = f.home + "/Library/LaunchAgents"
        try fm.createDirectory(atPath: launchDir, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: launchDir + "/com.other.service.plist"))

        let categories = Set(f.scanner().scan().map(\.category))

        #expect(!categories.contains(.projectHooks),
                "non-senkani hooks must not be flagged for removal")
        #expect(!categories.contains(.launchdPlists),
                "non-senkani plists must not be flagged for removal")
    }

    @Test func discoveryFindsModelMetadataCacheAndIdempotentRemoval() throws {
        let f = try Fixture()
        try f.seedModelMetadataCache()

        // Scan should pick up dev.senkani only (the SenkaniApp + senkani-mcp
        // siblings are seeded by seedModelMetadataCache as OS-managed
        // controls; they must NOT be flagged).
        let artifacts = f.scanner().scan()
        let categories = Set(artifacts.map(\.category))
        #expect(categories == [.modelMetadataCache],
                "only modelMetadataCache should be discovered, got \(categories.map(\.rawValue).sorted())")

        if let item = artifacts.first(where: { $0.category == .modelMetadataCache }) {
            #expect(item.description.contains("dev.senkani"),
                    "expected description to mention dev.senkani path, got: \(item.description)")
        }

        // Removal strips the whole dev.senkani/ subtree — including models/models.json.
        for item in artifacts where item.category == .modelMetadataCache {
            try item.remove()
        }

        let fm = FileManager.default
        let cacheRoot = f.home + "/Library/Caches"
        #expect(!fm.fileExists(atPath: cacheRoot + "/dev.senkani"),
                "dev.senkani cache dir should be gone after removal")
        #expect(!fm.fileExists(atPath: cacheRoot + "/dev.senkani/models/models.json"),
                "models.json should be gone after removal")

        // OS-managed siblings must remain untouched.
        #expect(fm.fileExists(atPath: cacheRoot + "/SenkaniApp"),
                "SenkaniApp cache (OS-managed) must NOT be removed")
        #expect(fm.fileExists(atPath: cacheRoot + "/senkani-mcp"),
                "senkani-mcp cache (OS-managed) must NOT be removed")

        // Re-scan must be empty (idempotent).
        #expect(f.scanner().scan().isEmpty,
                "after removal, scanner finds nothing")
    }

    @Test func scannerIgnoresOSManagedSenkaniCachesWithoutDevSenkani() throws {
        let f = try Fixture()
        let fm = FileManager.default

        // Seed ONLY the OS-managed Library/Caches siblings — no dev.senkani.
        // These are auto-created by macOS for SenkaniApp + senkani-mcp
        // processes regardless of whether senkani actively writes to them.
        // Scanner must produce zero artifacts.
        let cacheRoot = f.home + "/Library/Caches"
        try fm.createDirectory(atPath: cacheRoot + "/SenkaniApp",
                               withIntermediateDirectories: true)
        try fm.createDirectory(atPath: cacheRoot + "/senkani-mcp",
                               withIntermediateDirectories: true)

        let artifacts = f.scanner().scan()
        #expect(artifacts.isEmpty,
                "OS-managed sibling caches must not produce artifacts — got \(artifacts.map(\.category.rawValue))")
    }
}
