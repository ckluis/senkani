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

        /// Seed every one of the 7 categories that the scanner knows about.
        func seedAll() throws {
            try seedGlobalMCPRegistration()
            try seedProjectHooks()
            try seedHookBinary()
            try seedRuntimeDirectory()     // also creates workspace.json
            try seedSessionDatabase()
            try seedLaunchdPlist()
            try seedPerProjectSenkaniDirs()
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

        /// Seed one senkani-hooked project + one unrelated-hooked project.
        /// The scanner must pick up only the senkani one.
        func seedProjectHooks() throws {
            let fm = FileManager.default
            let senkaniProj = home + "/.claude/projects/proj-senkani"
            let unrelatedProj = home + "/.claude/projects/proj-other"
            try fm.createDirectory(atPath: senkaniProj, withIntermediateDirectories: true)
            try fm.createDirectory(atPath: unrelatedProj, withIntermediateDirectories: true)

            let senkaniSettings: [String: Any] = [
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
            let unrelatedSettings: [String: Any] = [
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
            try JSONSerialization.data(withJSONObject: senkaniSettings)
                .write(to: URL(fileURLWithPath: senkaniProj + "/settings.json"))
            try JSONSerialization.data(withJSONObject: unrelatedSettings)
                .write(to: URL(fileURLWithPath: unrelatedProj + "/settings.json"))
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
        /// fixture root) each with a `.senkani/` indicator.
        func seedPerProjectSenkaniDirs() throws {
            let fm = FileManager.default
            let projA = root.appendingPathComponent("projA").path
            let projB = root.appendingPathComponent("projB").path
            try fm.createDirectory(atPath: projA + "/.senkani", withIntermediateDirectories: true)
            try fm.createDirectory(atPath: projB + "/.senkani", withIntermediateDirectories: true)

            let workspace: [String: Any] = [
                "projects": [
                    ["path": projA],
                    ["path": projB]
                ]
            ]
            try JSONSerialization.data(withJSONObject: workspace)
                .write(to: URL(fileURLWithPath: home + "/.senkani/workspace.json"))
        }

        func scanner(keepData: Bool = false) -> UninstallArtifactScanner {
            UninstallArtifactScanner(
                homeDir: home, appSupportDir: appSupport, keepData: keepData)
        }
    }

    // MARK: - Tests

    @Test func discoveryFindsAllSevenCategoriesWhenFullySeeded() throws {
        let f = try Fixture()
        try f.seedAll()

        let artifacts = f.scanner().scan()
        let categories = Set(artifacts.map(\.category))

        #expect(categories == Set(UninstallArtifactScanner.Category.allCases),
                "expected all 7 categories, got \(categories.map(\.rawValue).sorted())")
        #expect(artifacts.count == 7, "one artifact per category when fully seeded")
    }

    @Test func keepDataOmitsSessionDatabase() throws {
        let f = try Fixture()
        try f.seedAll()

        let categories = Set(f.scanner(keepData: true).scan().map(\.category))

        #expect(!categories.contains(.sessionDatabase),
                "--keep-data must suppress the sessionDatabase artifact")
        #expect(categories.count == 6, "other 6 categories still discovered")
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
        #expect(first.count == 7)
        for item in first {
            try item.remove()
        }

        // Re-scan after removal: empty (idempotent uninstall).
        let second = f.scanner().scan()
        #expect(second.isEmpty,
                "after remove() on every artifact, scanner must find nothing — got \(second.map(\.category.rawValue))")
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
}
