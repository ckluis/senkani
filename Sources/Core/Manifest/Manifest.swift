import Foundation

/// Phase S.1 — per-project skill/tool/hook manifest.
///
/// On-disk home: `<projectRoot>/.senkani/senkani.json` (team source of
/// truth, committed). User-local overrides live in
/// `~/.senkani/overrides.json`, keyed by absolute project-root path
/// (never committed).
///
/// Resolution rule (see `ManifestResolver`):
///   effective = team ∩ user.optOuts ∪ user.additions
///
/// A small set of MCP tools is considered "core" and always-on
/// regardless of manifest state, so agents retain a usable baseline
/// even against an empty or absent manifest: `Manifest.coreTools`.
///
/// Format note: the Phase S spec (`spec/roadmap.md:526`) describes the
/// manifest as YAML. This round ships JSON because no YAML parser is
/// in-tree; JSON is a strict YAML subset so a future Yams-backed
/// round can read today's files verbatim.
public struct Manifest: Codable, Sendable, Equatable {
    public var skills: [String]
    public var mcpTools: [String]
    public var hooks: [String]

    public init(
        skills: [String] = [],
        mcpTools: [String] = [],
        hooks: [String] = []
    ) {
        self.skills = skills
        self.mcpTools = mcpTools
        self.hooks = hooks
    }

    /// MCP tools that are always registered regardless of manifest
    /// state. Keeps an empty-manifest project usable (an agent can
    /// always read, outline, follow deps, and query session state).
    ///
    /// Names here are the internal MCP tool names (the `params.name`
    /// values switched on in `ToolRouter`), not the `senkani_`-prefixed
    /// names used in agent-facing docs.
    public static let coreTools: Set<String> = ["read", "outline", "deps", "session"]
}

/// User-local overrides layered on top of the committed team manifest.
/// One file per user, at `~/.senkani/overrides.json`, keyed by the
/// absolute project-root path so a single file covers every repo the
/// user works in.
public struct ManifestOverrides: Codable, Sendable, Equatable {
    public var optOutSkills: [String]
    public var optOutTools: [String]
    public var optOutHooks: [String]
    public var addSkills: [String]
    public var addTools: [String]
    public var addHooks: [String]

    public init(
        optOutSkills: [String] = [],
        optOutTools: [String] = [],
        optOutHooks: [String] = [],
        addSkills: [String] = [],
        addTools: [String] = [],
        addHooks: [String] = []
    ) {
        self.optOutSkills = optOutSkills
        self.optOutTools = optOutTools
        self.optOutHooks = optOutHooks
        self.addSkills = addSkills
        self.addTools = addTools
        self.addHooks = addHooks
    }

    public static let empty = ManifestOverrides()
}

/// The resolved set of skills / tools / hooks enabled for a project,
/// after layering user overrides on top of the committed manifest and
/// unioning in the always-on core tools.
public struct EffectiveSet: Sendable, Equatable {
    public let skills: Set<String>
    public let mcpTools: Set<String>
    public let hooks: Set<String>

    /// `true` when no manifest file was present at load time. Callers
    /// that need backwards-compat fallback (pre-manifest behavior)
    /// check this — see `ToolRouter.allTools()`.
    public let manifestPresent: Bool

    public init(
        skills: Set<String>,
        mcpTools: Set<String>,
        hooks: Set<String>,
        manifestPresent: Bool
    ) {
        self.skills = skills
        self.mcpTools = mcpTools
        self.hooks = hooks
        self.manifestPresent = manifestPresent
    }

    public func isToolEnabled(_ name: String) -> Bool {
        if Manifest.coreTools.contains(name) { return true }
        if !manifestPresent { return true }
        return mcpTools.contains(name)
    }
}
