import Foundation

/// Env-var bundles that Senkani injects into every pane subprocess. The
/// MCP server reads these (see `MCPMain` + `MCPSession.resolve`) to
/// decide which pane it's running inside, which project root to anchor
/// to, and which feature toggles to respect.
///
/// Both the plain terminal pane and the Ollama-launcher pane must
/// produce the same core SENKANI_* gate keys so the MCP server behaves
/// identically regardless of pane type. The Ollama variant additionally
/// sets `SENKANI_OLLAMA_MODEL` so downstream tooling can surface the
/// model the pane booted with.
///
/// Extracted from inline dict builds in `OllamaLauncherPane.swift` and
/// `PaneContainerView.swift` so:
///   1. The two views share one source of truth (no drift).
///   2. The env contract is unit-testable without SwiftUI in scope.
public enum PaneLaunchEnv {

    /// Fields a pane provides to assemble its launch env. Kept as
    /// primitives so this module stays UI-framework-free — the app
    /// target maps its `PaneModel` onto this struct at the call site.
    public struct Inputs: Sendable, Equatable {
        public let paneID: UUID
        public let projectRoot: String
        public let metricsFilePath: String
        public let configFilePath: String
        public let workspaceSlug: String
        public let paneSlug: String
        public let filterOn: Bool
        public let cacheOn: Bool
        public let secretsOn: Bool
        public let indexerOn: Bool
        public let terseOn: Bool

        public init(
            paneID: UUID,
            projectRoot: String,
            metricsFilePath: String,
            configFilePath: String,
            workspaceSlug: String,
            paneSlug: String,
            filterOn: Bool,
            cacheOn: Bool,
            secretsOn: Bool,
            indexerOn: Bool,
            terseOn: Bool
        ) {
            self.paneID = paneID
            self.projectRoot = projectRoot
            self.metricsFilePath = metricsFilePath
            self.configFilePath = configFilePath
            self.workspaceSlug = workspaceSlug
            self.paneSlug = paneSlug
            self.filterOn = filterOn
            self.cacheOn = cacheOn
            self.secretsOn = secretsOn
            self.indexerOn = indexerOn
            self.terseOn = terseOn
        }
    }

    /// SENKANI_* keys the MCP server's gate check (`MCPMain.swift:19`)
    /// or its feature resolvers need present. Every pane subprocess
    /// must inject all of these — a missing key silently disables the
    /// corresponding subsystem, which is the exact regression this
    /// helper's tests pin.
    public static let requiredGateKeys: [String] = [
        "SENKANI_PANE_ID",
        "SENKANI_PROJECT_ROOT",
        "SENKANI_HOOK",
        "SENKANI_INTERCEPT",
        "SENKANI_METRICS_FILE",
        "SENKANI_CONFIG_FILE",
        "SENKANI_WORKSPACE_SLUG",
        "SENKANI_PANE_SLUG",
        "SENKANI_MCP_FILTER",
        "SENKANI_MCP_CACHE",
        "SENKANI_MCP_SECRETS",
        "SENKANI_MCP_INDEX",
        "SENKANI_MCP_TERSE",
    ]

    /// Env bundle for a plain Terminal pane. Used by
    /// `PaneContainerView.paneBody` (case `.terminal`).
    ///
    /// Does NOT include `CLAUDE_MODEL` or `SENKANI_MODEL_PRESET` — those
    /// are the terminal pane's extra concern and the caller layers them
    /// on top of this bundle. Keeping the model-routing keys out of the
    /// shared contract preserves the bounded context: every pane type
    /// ships the same MCP gate keys, and each pane layers its own extras.
    public static func terminal(_ inputs: Inputs) -> [String: String] {
        return baseMCPBundle(inputs)
    }

    /// Env bundle for an Ollama-launcher pane. Mirrors the Terminal
    /// bundle key-for-key (so the MCP gate fires identically) and adds
    /// `SENKANI_OLLAMA_MODEL` so tools can surface the model the REPL
    /// booted with.
    ///
    /// `resolvedModelTag` MUST have already passed
    /// `OllamaLauncherSupport.isValidModelTag` — the caller owns that
    /// gate because the tag also ends up interpolated into a shell
    /// command. Bundling the same rejection here would be defense-in-
    /// depth but would also hide the caller's bug; let the unit test
    /// catch an invalid tag at the env-build boundary instead.
    public static func ollamaLauncher(
        _ inputs: Inputs,
        resolvedModelTag: String
    ) -> [String: String] {
        var env = baseMCPBundle(inputs)
        env["SENKANI_OLLAMA_MODEL"] = resolvedModelTag
        return env
    }

    // MARK: - Internal

    private static func baseMCPBundle(_ i: Inputs) -> [String: String] {
        return [
            "SENKANI_METRICS_FILE":  i.metricsFilePath,
            "SENKANI_CONFIG_FILE":   i.configFilePath,
            "SENKANI_INTERCEPT":     "on",
            "SENKANI_HOOK":          "on",
            "SENKANI_PROJECT_ROOT":  i.projectRoot,
            "SENKANI_PANE_ID":       i.paneID.uuidString,
            "SENKANI_MCP_FILTER":    i.filterOn  ? "on" : "off",
            "SENKANI_MCP_CACHE":     i.cacheOn   ? "on" : "off",
            "SENKANI_MCP_SECRETS":   i.secretsOn ? "on" : "off",
            "SENKANI_MCP_INDEX":     i.indexerOn ? "on" : "off",
            "SENKANI_MCP_TERSE":     i.terseOn   ? "on" : "off",
            "SENKANI_WORKSPACE_SLUG": i.workspaceSlug,
            "SENKANI_PANE_SLUG":      i.paneSlug,
        ]
    }
}
