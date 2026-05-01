import Foundation

/// Per-tool policy metadata consulted by `ConfirmationGate`. Phase T.6a
/// round 1 surface — round 1 ships the catalog + `requiresConfirmation`
/// flag derived from each tool's tags. Settings UI (round T.6b) can
/// override the flag at runtime.
///
/// A tool's tag set decides the default: any tool tagged `.write` or
/// `.exec` requires confirmation; pure-`.read` tools do not. The catalog
/// is a process-wide registry — the gate looks up by tool name and gets
/// either an explicit entry or a permissive default for unknown tools.
public enum MCPToolTag: String, Sendable, Codable, Equatable, CaseIterable {
    /// Pure read — file reads, search, outline, etc. Never requires
    /// confirmation by default.
    case read
    /// Mutates state on disk or in the user's environment. Requires
    /// confirmation by default.
    case write
    /// Executes user-supplied code or shells out. Requires confirmation
    /// by default.
    case exec
    /// Reaches the network. Independent axis — can pair with `.read`
    /// (HTTP GET) or `.write` (POST). Round T.1's egress proxy is the
    /// gate for this tag; T.6a only consumes it for confirmation
    /// classification.
    case network
}

/// One row of the tool registry.
public struct MCPToolConfig: Sendable, Equatable {
    public let name: String
    public let tags: Set<MCPToolTag>
    /// True when an operator override has flipped the default. Round 1
    /// ships the auto-derived value; round T.6b's Settings UI lets the
    /// operator override per tool.
    public let requiresConfirmationOverride: Bool?

    public init(
        name: String,
        tags: Set<MCPToolTag>,
        requiresConfirmationOverride: Bool? = nil
    ) {
        self.name = name
        self.tags = tags
        self.requiresConfirmationOverride = requiresConfirmationOverride
    }

    /// Effective `requires_confirmation` for this tool. Override wins if
    /// set; otherwise the tag set decides.
    public var requiresConfirmation: Bool {
        if let override = requiresConfirmationOverride { return override }
        return tags.contains(.write) || tags.contains(.exec)
    }
}

/// Process-wide catalog of `MCPToolConfig` entries, keyed by tool name.
///
/// Round 1 ships the static defaults for senkani's MCP surface and the
/// Claude Code hook tools (`Edit`, `Write`, `Bash`) that HookRouter
/// observes. Tests inject a fresh catalog via `MCPToolCatalog(entries:)`
/// to exercise specific tag sets without polluting the shared singleton.
public final class MCPToolCatalog: @unchecked Sendable {
    public static let shared = MCPToolCatalog(entries: MCPToolCatalog.defaults)

    private let lock = NSLock()
    private var entries: [String: MCPToolConfig]

    public init(entries: [MCPToolConfig]) {
        var map: [String: MCPToolConfig] = [:]
        for entry in entries { map[entry.name] = entry }
        self.entries = map
    }

    public func config(for toolName: String) -> MCPToolConfig? {
        lock.lock()
        defer { lock.unlock() }
        return entries[toolName]
    }

    /// True iff the catalog has an entry whose effective
    /// `requiresConfirmation` is true. Unknown tools return false —
    /// HookRouter only consults the gate for tools we know about.
    public func requiresConfirmation(for toolName: String) -> Bool {
        return config(for: toolName)?.requiresConfirmation ?? false
    }

    /// Operator override seam — round 1 has no Settings UI, but the
    /// flag is already settable so tests cover the override path.
    public func setOverride(toolName: String, requiresConfirmation: Bool?) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = entries[toolName] {
            entries[toolName] = MCPToolConfig(
                name: existing.name,
                tags: existing.tags,
                requiresConfirmationOverride: requiresConfirmation
            )
        }
    }

    /// Static defaults wired in at init. Hook-observed tools (`Edit`,
    /// `Write`, `Bash`) ship as `.write` / `.exec` so the gate fires on
    /// them today. The senkani MCP surface is enumerated here so the
    /// catalog stays in one place — no new entry should slip in without
    /// the operator deciding its tag set.
    public static let defaults: [MCPToolConfig] = [
        // Claude Code hook-observed tools. The hook router sees these
        // by name; the gate flags Edit/Write/Bash as confirmation-
        // worthy. Read goes through the read intercept path and never
        // needs confirmation.
        MCPToolConfig(name: "Edit",  tags: [.write]),
        MCPToolConfig(name: "Write", tags: [.write]),
        MCPToolConfig(name: "Bash",  tags: [.exec]),
        MCPToolConfig(name: "Read",  tags: [.read]),
        MCPToolConfig(name: "Grep",  tags: [.read]),

        // Senkani MCP tools — read surface is the long tail; only
        // senkani_exec writes / executes today.
        MCPToolConfig(name: "senkani_read",     tags: [.read]),
        MCPToolConfig(name: "senkani_search",   tags: [.read]),
        MCPToolConfig(name: "senkani_outline",  tags: [.read]),
        MCPToolConfig(name: "senkani_deps",     tags: [.read]),
        MCPToolConfig(name: "senkani_explore",  tags: [.read]),
        MCPToolConfig(name: "senkani_repo",     tags: [.read]),
        MCPToolConfig(name: "senkani_session",  tags: [.read]),
        MCPToolConfig(name: "senkani_version",  tags: [.read]),
        MCPToolConfig(name: "senkani_bundle",   tags: [.read]),
        MCPToolConfig(name: "senkani_embed",    tags: [.read]),
        MCPToolConfig(name: "senkani_fetch",    tags: [.read]),
        MCPToolConfig(name: "senkani_parse",    tags: [.read]),
        MCPToolConfig(name: "senkani_vision",   tags: [.read]),
        MCPToolConfig(name: "senkani_watch",    tags: [.read]),
        MCPToolConfig(name: "senkani_knowledge", tags: [.read]),
        MCPToolConfig(name: "senkani_pane",     tags: [.read]),
        MCPToolConfig(name: "senkani_validate", tags: [.read]),
        MCPToolConfig(name: "senkani_web",      tags: [.read, .network]),

        // The exec surface — sandboxed today (T.3 will harden), but
        // still classified as `.exec` so it walks the gate.
        MCPToolConfig(name: "senkani_exec", tags: [.exec]),
    ]
}
