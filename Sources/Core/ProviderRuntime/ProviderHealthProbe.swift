import Foundation

/// Phase V.17b-1 — builds a `ProviderHealthSnapshot` from LOCAL signals
/// only: the provider's own `--version` CLI subcommand + locally-recorded
/// auth state. NO network call is made — this is the load-bearing
/// no-network invariant (Russell). The probe is injectable so tests
/// drive it without spawning a real subprocess.
///
/// The CLI binary lookup + `--version` spawn is funnelled through a
/// single `LocalProbe` closure so:
///   - production wires it to a real allowlisted `Process` spawn of the
///     provider binary (no shell, no network);
///   - tests inject a canned probe and assert the snapshot shape +
///     the no-network invariant without ever spawning.
public struct ProviderHealthProbe: Sendable {

    /// The result of probing one provider's local CLI. All fields are
    /// derived from on-disk/local-process signals; producing this value
    /// never touches the network.
    public struct LocalProbeResult: Sendable, Equatable {
        public let cliInstalled: Bool
        public let version: String?
        public let authState: ProviderHealthSnapshot.AuthState
        public let selectedModel: String?
        public let subscriptionState: String?

        public init(
            cliInstalled: Bool,
            version: String? = nil,
            authState: ProviderHealthSnapshot.AuthState = .unknown,
            selectedModel: String? = nil,
            subscriptionState: String? = nil
        ) {
            self.cliInstalled = cliInstalled
            self.version = version
            self.authState = authState
            self.selectedModel = selectedModel
            self.subscriptionState = subscriptionState
        }

        /// The fail-safe result when the provider CLI is not installed.
        public static let notInstalled = LocalProbeResult(
            cliInstalled: false,
            version: nil,
            authState: .unknown,
            selectedModel: nil,
            subscriptionState: nil
        )
    }

    /// Injectable local probe. Takes a provider id, returns the locally-
    /// observable state. MUST NOT make a network call.
    public typealias LocalProbe = @Sendable (_ providerID: String) -> LocalProbeResult

    private let localProbe: LocalProbe
    private let ttl: ProviderHealthSnapshot.TTL

    public init(
        ttl: ProviderHealthSnapshot.TTL = .standard,
        localProbe: @escaping LocalProbe
    ) {
        self.ttl = ttl
        self.localProbe = localProbe
    }

    /// Default production probe: spawns the provider's local CLI binary
    /// with `--version` (no shell, no network) and parses install +
    /// version. Auth/model/subscription default to `.unknown`/nil until
    /// a provider-specific local-state reader is added (a follow-up; the
    /// v0.4.0 ship reports `unknown` rather than network-probing to
    /// disambiguate — Russell fail-safe).
    public static func production(
        ttl: ProviderHealthSnapshot.TTL = .standard
    ) -> ProviderHealthProbe {
        ProviderHealthProbe(ttl: ttl) { providerID in
            Self.spawnVersionProbe(providerID: providerID)
        }
    }

    /// Build a snapshot for one provider as of `now`. Pure orchestration
    /// over the injected local probe — no network, no SQLite (the caller
    /// upserts). `remediationHint` is derived from the local state.
    public func snapshot(providerID: String, now: Date = Date()) -> ProviderHealthSnapshot {
        let result = localProbe(providerID)
        return ProviderHealthSnapshot(
            providerID: providerID,
            cliInstalled: result.cliInstalled,
            version: result.version,
            authState: result.authState,
            selectedModel: result.selectedModel,
            subscriptionState: result.subscriptionState,
            lastRefresh: now,
            ttl: ttl,
            remediationHint: Self.remediationHint(providerID: providerID, result: result)
        )
    }

    /// Operator-facing remediation hint derived purely from local state.
    /// nil when healthy.
    public static func remediationHint(
        providerID: String,
        result: LocalProbeResult
    ) -> String? {
        if !result.cliInstalled {
            return "install the \(providerID) CLI and ensure it is on PATH"
        }
        switch result.authState {
        case .signedOut:
            return "sign in to \(providerID) (run its login command)"
        case .expired:
            return "\(providerID) credentials expired — re-authenticate"
        case .signedIn, .unknown:
            return nil
        }
    }

    // MARK: - Production version probe (local, no network)

    /// Spawn `<providerID-binary> --version` via a direct executable
    /// lookup (NO shell, NO network). Maps the provider id to its CLI
    /// binary name, resolves it on PATH, and parses the first version-
    /// looking token from stdout. Returns `.notInstalled` when the
    /// binary is absent or the spawn fails.
    static func spawnVersionProbe(providerID: String) -> LocalProbeResult {
        guard let binary = binaryName(forProviderID: providerID),
              let resolved = resolveOnPath(binary) else {
            return .notInstalled
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: resolved)
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .notInstalled
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let version = parseVersion(from: out)
        return LocalProbeResult(
            cliInstalled: true,
            version: version,
            authState: .unknown,
            selectedModel: nil,
            subscriptionState: nil
        )
    }

    /// Map a provider id to its CLI binary name. Returns nil for an
    /// unknown provider (treated as not-installed).
    static func binaryName(forProviderID providerID: String) -> String? {
        switch providerID {
        case "codex":       return "codex"
        case "claude_code": return "claude"
        case "gemini":      return "gemini"
        case "opencode":    return "opencode"
        default:            return nil
        }
    }

    /// Resolve a binary on PATH without spawning a shell. Returns the
    /// absolute path or nil. (Uses Foundation file existence + the
    /// process PATH — no `which`, no shell.)
    static func resolveOnPath(_ binary: String) -> String? {
        let fm = FileManager.default
        let pathVar = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for dir in pathVar.split(separator: ":") {
            let candidate = (String(dir) as NSString).appendingPathComponent(binary)
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Pull the first version-looking token (e.g. `1.2.3`, `v0.4.0`)
    /// out of a `--version` line. Returns the raw trimmed string if no
    /// semver-ish token is found but output exists; nil for empty output.
    static func parseVersion(from output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for token in trimmed.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            let t = String(token)
            let core = t.hasPrefix("v") ? String(t.dropFirst()) : t
            if core.first?.isNumber == true, core.contains(".") {
                return t
            }
        }
        return trimmed
    }
}
