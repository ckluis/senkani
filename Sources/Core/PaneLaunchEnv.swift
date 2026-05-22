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
        public let paneMode: PaneMode
        /// The pane's `initialCommand`. Used to decide whether to inject
        /// `OTEL_EXPORTER_OTLP_ENDPOINT` based on the dev-server allowlist
        /// (`matchesDevServerCommand`). Empty string for plain shells.
        public let initialCommand: String
        /// Per-pane opt-out for runtime telemetry forwarding. When `false`,
        /// `OTEL_EXPORTER_OTLP_ENDPOINT` is never injected regardless of
        /// allowlist match or endpoint availability.
        public let forwardDevServerTelemetry: Bool
        /// Resolved local OTLP/HTTP endpoint URL (e.g. `http://127.0.0.1:54321`).
        /// `nil` when the receiver hasn't bound a port yet — no injection
        /// happens in that case so a non-instrumented pane is the failure mode.
        public let runtimeTelemetryEndpoint: String?

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
            terseOn: Bool,
            paneMode: PaneMode = .default,
            initialCommand: String = "",
            forwardDevServerTelemetry: Bool = true,
            runtimeTelemetryEndpoint: String? = nil
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
            self.paneMode = paneMode
            self.initialCommand = initialCommand
            self.forwardDevServerTelemetry = forwardDevServerTelemetry
            self.runtimeTelemetryEndpoint = runtimeTelemetryEndpoint
        }
    }

    /// V.18b-1 — pane `initialCommand` prefixes whose match triggers OTEL
    /// endpoint injection. Matches are whitespace-trimmed and case-sensitive
    /// (Node.js binary names and npm script syntax are case-sensitive on
    /// the platforms senkani ships to). A pane configured with one of these
    /// commands inherits `OTEL_EXPORTER_OTLP_ENDPOINT` through its login
    /// shell, so any dev-server child process observes it automatically.
    public static let devServerCommandPrefixes: [String] = [
        "npm run dev",
        "bun dev",
        "pnpm dev",
        "yarn dev",
        "vite",
        "next dev",
    ]

    /// True when `command` starts with one of `devServerCommandPrefixes`
    /// after whitespace trim. A prefix matches when `command` equals the
    /// prefix exactly OR continues with a whitespace separator (so
    /// `"vite --port 5173"` matches but `"vitest"` does not).
    public static func matchesDevServerCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in devServerCommandPrefixes {
            if trimmed == prefix { return true }
            if trimmed.hasPrefix(prefix + " ") { return true }
            if trimmed.hasPrefix(prefix + "\t") { return true }
        }
        return false
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
        "SENKANI_PANE_MODE",
    ]

    /// Env bundle for a plain Terminal pane. Used by
    /// `PaneContainerView.paneBody` (case `.terminal`).
    ///
    /// Does NOT include `CLAUDE_MODEL` or `SENKANI_MODEL_PRESET` — those
    /// are the terminal pane's extra concern and the caller layers them
    /// on top of this bundle. Keeping the model-routing keys out of the
    /// shared contract preserves the bounded context: every pane type
    /// ships the same MCP gate keys, and each pane layers its own extras.
    ///
    /// V.18b-1 — when `inputs.initialCommand` matches a dev-server prefix
    /// (`matchesDevServerCommand`), forwarding is opted in
    /// (`inputs.forwardDevServerTelemetry == true`), and a receiver
    /// endpoint is available (`inputs.runtimeTelemetryEndpoint != nil`),
    /// the bundle adds `OTEL_EXPORTER_OTLP_ENDPOINT` so the dev server
    /// inherited through the login shell pushes traces/logs into the
    /// local OTLP receiver.
    public static func terminal(_ inputs: Inputs) -> [String: String] {
        var env = baseMCPBundle(inputs)
        if let endpoint = otlpEndpointForInjection(inputs) {
            env["OTEL_EXPORTER_OTLP_ENDPOINT"] = endpoint
        }
        return env
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

    /// Returns the OTLP endpoint string to inject for this pane, or nil
    /// when the gate fails (opt-out, no command match, or no receiver
    /// endpoint discovered). Centralized so future pane types that want
    /// the same injection (e.g. an Ollama launcher whose model server
    /// wraps a dev-server) can opt in by calling this helper.
    private static func otlpEndpointForInjection(_ i: Inputs) -> String? {
        guard i.forwardDevServerTelemetry else { return nil }
        guard let endpoint = i.runtimeTelemetryEndpoint, !endpoint.isEmpty else { return nil }
        guard matchesDevServerCommand(i.initialCommand) else { return nil }
        return endpoint
    }

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
            // T.1b follow-up: subprocess-facing pane mode. Senkani-aware
            // HTTP clients read this and add the `X-Senkani-Pane-Mode`
            // header on outbound requests; the EgressProxy daemon parses
            // it and routes through the per-mode policy engine. Defense-
            // in-depth — daemon defaults to `.general` when the header
            // is missing, so a subprocess that ignores this env var
            // still hits the deny-on-miss invariant of the rule engine.
            "SENKANI_PANE_MODE":      i.paneMode.rawValue,
        ]
    }
}
