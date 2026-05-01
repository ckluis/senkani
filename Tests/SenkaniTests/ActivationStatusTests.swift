import Testing
import Foundation
@testable import Core

@Suite("Activation Status")
struct ActivationStatusTests {

    // MARK: - Fixtures

    private static let now = Date(timeIntervalSinceReferenceDate: 700_000_000)
    private static let home = "/Users/test"
    private static let projectPath = "/Users/test/Desktop/projects/senkani"

    private static func ready(lastEventOffset: TimeInterval = -45) -> ActivationProbes {
        .init(
            projectRoot: projectPath,
            mcpRegistered: true,
            projectHooksRegistered: true,
            sessionWatcherRunning: true,
            lastEventAt: now.addingTimeInterval(lastEventOffset)
        )
    }

    // MARK: - Fully ready

    @Test func ready_allComponentsOk_andFullyActive() {
        let probes = Self.ready()
        let status = ActivationStatusDerivation.derive(
            probes: probes, homeDirectory: Self.home, now: Self.now
        )

        #expect(status.components.count == 5)
        #expect(status.isReady)
        #expect(status.isFullyActive)
        for component in ActivationStatus.Component.allCases {
            #expect(status.status(for: component).state == .ok,
                    "Expected \(component) to be .ok")
            #expect(status.status(for: component).nextAction == nil,
                    "Expected \(component) to have no next action when ready")
        }
        #expect(status.status(for: .project).detail == "~/Desktop/projects/senkani")
        #expect(status.status(for: .events).detail == "last 45s ago")
    }

    // MARK: - Missing MCP

    @Test func missingMCP_marksOnlyMcpMissing_andCarriesActionableCopy() {
        var probes = Self.ready()
        probes.mcpRegistered = false

        let status = ActivationStatusDerivation.derive(
            probes: probes, homeDirectory: Self.home, now: Self.now
        )

        #expect(status.isReady == false)
        #expect(status.isFullyActive == false)
        #expect(status.status(for: .mcp).state == .missing)
        #expect(status.status(for: .mcp).detail == "not registered")
        let action = status.status(for: .mcp).nextAction ?? ""
        #expect(action.contains("senkani mcp-install --global") || action.contains("Restart Senkani"))
        // Other components remain ok / waiting.
        #expect(status.status(for: .project).state == .ok)
        #expect(status.status(for: .hooks).state == .ok)
        #expect(status.status(for: .tracking).state == .ok)
        #expect(status.status(for: .events).state == .ok)
        #expect(status.firstMissing?.component == .mcp)
    }

    // MARK: - Missing project hooks

    @Test func missingHooks_marksHooksMissing_andSuggestsSenkaniInit() {
        var probes = Self.ready()
        probes.projectHooksRegistered = false

        let status = ActivationStatusDerivation.derive(
            probes: probes, homeDirectory: Self.home, now: Self.now
        )

        let hooks = status.status(for: .hooks)
        #expect(hooks.state == .missing)
        #expect(hooks.detail == "not installed in this project")
        let action = hooks.nextAction ?? ""
        #expect(action.contains("senkani init"))
        #expect(status.firstMissing?.component == .hooks)
    }

    // MARK: - No session watcher

    @Test func noSessionWatcher_marksTrackingMissing() {
        var probes = Self.ready()
        probes.sessionWatcherRunning = false

        let status = ActivationStatusDerivation.derive(
            probes: probes, homeDirectory: Self.home, now: Self.now
        )

        let tracking = status.status(for: .tracking)
        #expect(tracking.state == .missing)
        #expect(tracking.detail.contains("watcher"))
        let action = tracking.nextAction ?? ""
        #expect(action.contains("Restart the terminal pane"))
        #expect(status.isReady == false)
    }

    // MARK: - No events yet

    @Test func noEventsYet_marksEventsWaiting_butIsReadyTrue() {
        var probes = Self.ready()
        probes.lastEventAt = nil

        let status = ActivationStatusDerivation.derive(
            probes: probes, homeDirectory: Self.home, now: Self.now
        )

        let events = status.status(for: .events)
        #expect(events.state == .waiting)
        #expect(events.detail == "no events yet")
        let action = events.nextAction ?? ""
        #expect(action.contains("Claude command"))
        // Waiting != Missing → setup is "ready" enough that the user can act.
        #expect(status.isReady == true)
        #expect(status.isFullyActive == false)
        #expect(status.firstMissing == nil)
    }

    // MARK: - No project selected

    @Test func noProjectSelected_marksProjectMissing() {
        var probes = Self.ready()
        probes.projectRoot = nil

        let status = ActivationStatusDerivation.derive(
            probes: probes, homeDirectory: Self.home, now: Self.now
        )

        let project = status.status(for: .project)
        #expect(project.state == .missing)
        #expect(project.detail == "no project selected")
        let action = project.nextAction ?? ""
        #expect(action.contains("Welcome"))
    }

    // MARK: - Helpers

    @Test func relativeAgeLabel_secondsMinutesHoursDays() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        #expect(ActivationStatusDerivation.relativeAgeLabel(
            from: base.addingTimeInterval(-12), to: base) == "12s")
        #expect(ActivationStatusDerivation.relativeAgeLabel(
            from: base.addingTimeInterval(-180), to: base) == "3m")
        #expect(ActivationStatusDerivation.relativeAgeLabel(
            from: base.addingTimeInterval(-3_600 * 2), to: base) == "2h")
        #expect(ActivationStatusDerivation.relativeAgeLabel(
            from: base.addingTimeInterval(-86_400 * 4), to: base) == "4d")
        // Future timestamps clamp to 0s.
        #expect(ActivationStatusDerivation.relativeAgeLabel(
            from: base.addingTimeInterval(60), to: base) == "0s")
    }

    @Test func shorthand_collapsesHomeButLeavesNonHomePathsAlone() {
        let home = "/Users/test"
        #expect(ActivationStatusDerivation.shorthand(
            path: "/Users/test/Desktop/projects/senkani",
            home: home
        ) == "~/Desktop/projects/senkani")
        #expect(ActivationStatusDerivation.shorthand(
            path: "/opt/projects/foo", home: home
        ) == "/opt/projects/foo")
    }

    // MARK: - Probe IO

    @Test func mcpRegistered_returnsTrueWhenHomeSettingsContainsSenkani() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "senkani-act-mcp-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            atPath: tmp.path + "/.claude", withIntermediateDirectories: true
        )
        let payload: [String: Any] = [
            "mcpServers": [
                "senkani": ["command": "/usr/local/bin/senkani-mcp", "args": []],
            ] as [String: Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        try data.write(to: URL(fileURLWithPath: tmp.path + "/.claude/settings.json"))

        #expect(ActivationProbeIO.mcpRegistered(home: tmp.path) == true)

        try FileManager.default.removeItem(at: tmp)
    }

    @Test func mcpRegistered_returnsFalseWhenSettingsMissingOrNoSenkani() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "senkani-act-mcp-empty-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(atPath: tmp.path, withIntermediateDirectories: true)
        // No settings file yet.
        #expect(ActivationProbeIO.mcpRegistered(home: tmp.path) == false)

        // Settings file with no senkani entry.
        try FileManager.default.createDirectory(
            atPath: tmp.path + "/.claude", withIntermediateDirectories: true
        )
        let other: [String: Any] = ["mcpServers": ["other": ["command": "/x"]] as [String: Any]]
        let data = try JSONSerialization.data(withJSONObject: other, options: [])
        try data.write(to: URL(fileURLWithPath: tmp.path + "/.claude/settings.json"))
        #expect(ActivationProbeIO.mcpRegistered(home: tmp.path) == false)

        try FileManager.default.removeItem(at: tmp)
    }

    @Test func projectHooksRegistered_truthyOnSenkaniHookEntry() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "senkani-act-hooks-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            atPath: tmp.path + "/.claude", withIntermediateDirectories: true
        )
        let payload: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "Read|Bash",
                        "hooks": [
                            ["type": "command", "command": "/Users/test/.senkani/bin/senkani-hook"],
                        ],
                    ] as [String: Any],
                ],
            ] as [String: Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        try data.write(to: URL(fileURLWithPath: tmp.path + "/.claude/settings.json"))

        #expect(ActivationProbeIO.projectHooksRegistered(projectRoot: tmp.path) == true)
        // Empty project root → false.
        #expect(ActivationProbeIO.projectHooksRegistered(projectRoot: "") == false)
        // Random non-existent path → false.
        #expect(ActivationProbeIO.projectHooksRegistered(
            projectRoot: tmp.path + "-nope") == false)

        try FileManager.default.removeItem(at: tmp)
    }
}
