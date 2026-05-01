import Foundation

/// Activation proof model for the active-terminal "is Senkani working?" strip.
///
/// Pure derivation: callers gather probe values (filesystem reads, watcher
/// flags, last-event timestamps) and hand them to ``ActivationStatus/derive``.
/// The model carries one ``ComponentStatus`` per surface — project, MCP
/// registration, project-level hooks, the per-pane session watcher, and
/// the recency of the latest token event. Each component carries a literal
/// label and detail string (so the UI never relies on color or icons alone)
/// plus a single, runnable next-action when the component is missing.
public struct ActivationStatus: Equatable, Sendable {

    /// The five surfaces the strip reports on.
    public enum Component: String, Sendable, CaseIterable {
        case project, mcp, hooks, tracking, events
    }

    /// Per-component readiness state.
    public enum State: String, Sendable, Equatable {
        /// Surface is healthy.
        case ok
        /// Surface is partially active — a follow-up is expected but the
        /// user does not need to fix anything (e.g. tracking is running but
        /// no events have landed yet).
        case waiting
        /// Surface is not active — actionable.
        case missing
    }

    public struct ComponentStatus: Equatable, Sendable, Identifiable {
        public let component: Component
        public let state: State
        public let label: String
        public let detail: String
        public let nextAction: String?

        public var id: Component { component }

        public init(component: Component, state: State, label: String,
                    detail: String, nextAction: String?) {
            self.component = component
            self.state = state
            self.label = label
            self.detail = detail
            self.nextAction = nextAction
        }
    }

    public let components: [ComponentStatus]
    public let evaluatedAt: Date

    public init(components: [ComponentStatus], evaluatedAt: Date) {
        self.components = components
        self.evaluatedAt = evaluatedAt
    }

    /// Look up a component's status by enum.
    public func status(for component: Component) -> ComponentStatus {
        if let match = components.first(where: { $0.component == component }) {
            return match
        }
        // Defensive default; ``derive`` always emits all five.
        return ComponentStatus(component: component, state: .missing,
                               label: component.rawValue.uppercased(),
                               detail: "unknown", nextAction: nil)
    }

    /// True when nothing is ``State/missing``.
    public var isReady: Bool {
        components.allSatisfy { $0.state != .missing }
    }

    /// True when every component is ``State/ok``.
    public var isFullyActive: Bool {
        components.allSatisfy { $0.state == .ok }
    }

    /// First component with ``State/missing`` — used by the UI to surface a
    /// single banner-row next-action when more than one is missing.
    public var firstMissing: ComponentStatus? {
        components.first { $0.state == .missing }
    }
}

/// Inputs to ``ActivationStatusDerivation/derive`` — the host provides
/// filesystem-derived facts so the derivation itself stays pure and easy
/// to test.
public struct ActivationProbes: Equatable, Sendable {
    /// Active project root, or `nil` if no project is selected.
    public var projectRoot: String?
    /// True if `~/.claude/settings.json` contains a `mcpServers.senkani`
    /// entry pointing at a Senkani binary.
    public var mcpRegistered: Bool
    /// True if the project's `.claude/settings.json` contains a
    /// senkani-hook entry under PreToolUse or PostToolUse.
    public var projectHooksRegistered: Bool
    /// True if a `ClaudeSessionWatcher` is currently running for the
    /// active terminal pane.
    public var sessionWatcherRunning: Bool
    /// Timestamp of the most recent tracked token event for this project,
    /// or `nil` if none has been seen yet.
    public var lastEventAt: Date?

    public init(projectRoot: String?,
                mcpRegistered: Bool,
                projectHooksRegistered: Bool,
                sessionWatcherRunning: Bool,
                lastEventAt: Date?) {
        self.projectRoot = projectRoot
        self.mcpRegistered = mcpRegistered
        self.projectHooksRegistered = projectHooksRegistered
        self.sessionWatcherRunning = sessionWatcherRunning
        self.lastEventAt = lastEventAt
    }
}

/// Pure derivation: probe inputs → an ``ActivationStatus`` with five
/// ``ActivationStatus/ComponentStatus`` rows.
public enum ActivationStatusDerivation {

    public static func derive(
        probes: ActivationProbes,
        homeDirectory: String = NSHomeDirectory(),
        now: Date = Date()
    ) -> ActivationStatus {
        let project = projectComponent(probes: probes, home: homeDirectory)
        let mcp = mcpComponent(probes: probes)
        let hooks = hooksComponent(probes: probes)
        let tracking = trackingComponent(probes: probes)
        let events = eventsComponent(probes: probes, now: now)

        return ActivationStatus(
            components: [project, mcp, hooks, tracking, events],
            evaluatedAt: now
        )
    }

    // MARK: - Components

    private static func projectComponent(
        probes: ActivationProbes,
        home: String
    ) -> ActivationStatus.ComponentStatus {
        if let root = probes.projectRoot, !root.isEmpty {
            return .init(
                component: .project,
                state: .ok,
                label: "PROJECT",
                detail: shorthand(path: root, home: home),
                nextAction: nil
            )
        }
        return .init(
            component: .project,
            state: .missing,
            label: "PROJECT",
            detail: "no project selected",
            nextAction: "Choose a project folder from the Welcome screen."
        )
    }

    private static func mcpComponent(
        probes: ActivationProbes
    ) -> ActivationStatus.ComponentStatus {
        if probes.mcpRegistered {
            return .init(
                component: .mcp,
                state: .ok,
                label: "MCP",
                detail: "registered with Claude Code",
                nextAction: nil
            )
        }
        return .init(
            component: .mcp,
            state: .missing,
            label: "MCP",
            detail: "not registered",
            nextAction: "Restart Senkani to re-register, or run `senkani mcp-install --global`."
        )
    }

    private static func hooksComponent(
        probes: ActivationProbes
    ) -> ActivationStatus.ComponentStatus {
        if probes.projectHooksRegistered {
            return .init(
                component: .hooks,
                state: .ok,
                label: "HOOKS",
                detail: "project hooks active",
                nextAction: nil
            )
        }
        return .init(
            component: .hooks,
            state: .missing,
            label: "HOOKS",
            detail: "not installed in this project",
            nextAction: "Run `senkani init` in the project root to install hooks."
        )
    }

    private static func trackingComponent(
        probes: ActivationProbes
    ) -> ActivationStatus.ComponentStatus {
        if probes.sessionWatcherRunning {
            return .init(
                component: .tracking,
                state: .ok,
                label: "TRACK",
                detail: "watching Claude session",
                nextAction: nil
            )
        }
        return .init(
            component: .tracking,
            state: .missing,
            label: "TRACK",
            detail: "session watcher not running",
            nextAction: "Restart the terminal pane to start the watcher."
        )
    }

    private static func eventsComponent(
        probes: ActivationProbes,
        now: Date
    ) -> ActivationStatus.ComponentStatus {
        if let last = probes.lastEventAt {
            let age = relativeAgeLabel(from: last, to: now)
            return .init(
                component: .events,
                state: .ok,
                label: "EVENTS",
                detail: "last \(age) ago",
                nextAction: nil
            )
        }
        return .init(
            component: .events,
            state: .waiting,
            label: "EVENTS",
            detail: "no events yet",
            nextAction: "Run a Claude command — events should land within a second."
        )
    }

    // MARK: - Helpers

    /// Render a path relative to `home` if possible, else return the
    /// path unchanged. Last segment is preserved so `~/.../senkani` is
    /// always meaningful.
    static func shorthand(path: String, home: String) -> String {
        if !home.isEmpty, path.hasPrefix(home) {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    /// Compact human-readable age label: `12s`, `7m`, `3h`, `4d`.
    /// Always non-negative; future timestamps clamp to `0s`.
    static func relativeAgeLabel(from old: Date, to now: Date) -> String {
        let dt = max(0, Int(now.timeIntervalSince(old)))
        if dt < 60 { return "\(dt)s" }
        if dt < 3_600 { return "\(dt / 60)m" }
        if dt < 86_400 { return "\(dt / 3_600)h" }
        return "\(dt / 86_400)d"
    }
}

/// Filesystem-backed probes for the activation strip. The host calls
/// these on a refresh tick (or on-demand) to populate
/// ``ActivationProbes`` before handing it to the derivation.
public enum ActivationProbeIO {

    /// Read `~/.claude/settings.json` and return true if it carries a
    /// `mcpServers.senkani` entry whose `command` field is non-empty.
    /// Returns false on read or parse failure (the strip surfaces this
    /// as "not registered" with a recovery action — never throws).
    public static func mcpRegistered(home: String = NSHomeDirectory()) -> Bool {
        let path = home + "/.claude/settings.json"
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = obj["mcpServers"] as? [String: Any],
              let senkani = servers["senkani"] as? [String: Any],
              let command = senkani["command"] as? String,
              !command.isEmpty
        else { return false }
        return true
    }

    /// Inspect `<projectRoot>/.claude/settings.json` and return true if
    /// any PreToolUse or PostToolUse entry references a senkani-hook
    /// command path. Empty/missing project root → false.
    public static func projectHooksRegistered(projectRoot: String) -> Bool {
        guard !projectRoot.isEmpty else { return false }
        let settingsPath = projectRoot + "/.claude/settings.json"
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = obj["hooks"] as? [String: Any]
        else { return false }

        for event in ["PreToolUse", "PostToolUse"] {
            guard let entries = hooks[event] as? [[String: Any]] else { continue }
            for entry in entries {
                guard let inner = entry["hooks"] as? [[String: Any]] else { continue }
                for hook in inner {
                    if let command = hook["command"] as? String,
                       command.hasSuffix("/senkani-hook") || command.contains("/senkani-hook ") {
                        return true
                    }
                }
            }
        }
        return false
    }
}
