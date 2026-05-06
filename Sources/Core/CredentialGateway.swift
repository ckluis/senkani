import Foundation

/// T.4b — Per-tool credential gateway policy.
///
/// Declares which vault keys to read at which scope before a tool
/// runs, what to do when a key is missing, and where to put the
/// resolved value. Carried on `MCPToolConfig.credentialGateway`. The
/// gateway is opt-in: a `nil` field — or `enabled == false` — means
/// the tool is left untouched.
///
/// Scope decisions from the T.4a interview that this struct
/// materializes:
///   * Forward-compat scope param — `scope: String` (defaults to
///     `CredentialVault.defaultScope` at the call site, not in the
///     struct, so a nil-equivalent doesn't slip past Codable).
///   * Structured-error default — `dryRun == false` means missing keys
///     deny via `CredentialVaultError.missingKey`; T.4b's `HookRouter`
///     surfaces that error verbatim in `permissionDecisionReason`.
///   * Per-tool dry-run opt-in — `dryRun == true` flips a single tool
///     to `FAKE_KEY_<scope>_<key>` for missing keys, scoped to that
///     tool only. (The vault-wide dry-run is still the default off; this
///     struct turns it on per row.)
///   * Injection target — env preferred for the long tail; args for
///     tools whose runtime doesn't propagate env reliably (rare).
public struct CredentialGatewayConfig: Sendable, Equatable, Codable {
    /// Where the resolved values should land in the spawned tool's
    /// invocation surface.
    public enum InjectionTarget: String, Sendable, Equatable, Codable, CaseIterable {
        /// Inject as environment variables in the spawned process.
        /// This is the default — most CLIs read auth from env (e.g.
        /// `GITHUB_TOKEN`, `OPENAI_API_KEY`).
        case env
        /// Inject as positional / flag arguments. Used only when the
        /// tool's runtime doesn't forward env reliably.
        case args
    }

    /// Master switch. When false, the gateway no-ops even if other
    /// fields are populated — this lets a catalog ship pre-staged
    /// configs that the operator turns on later via Settings UI.
    public let enabled: Bool

    /// `CredentialVault` scope. `"default"` covers the long tail; T.2c
    /// will populate `engagement-<id>` later for redteam panes.
    public let scope: String

    /// Names of the keys to fetch. Read in declaration order; the
    /// first missing key denies (or returns a FAKE_KEY in dry-run).
    public let vaultKeys: [String]

    /// Per-tool dry-run opt-in. When true, missing keys are filled
    /// with the `FAKE_KEY_<scope>_<key>` sentinel so the tool can run
    /// with a placeholder. Default: false (structured error).
    public let dryRun: Bool

    /// Where the values should land. Defaults to `.env`.
    public let injectionTarget: InjectionTarget

    public init(
        enabled: Bool,
        scope: String = CredentialVault.defaultScope,
        vaultKeys: [String],
        dryRun: Bool = false,
        injectionTarget: InjectionTarget = .env
    ) {
        self.enabled = enabled
        self.scope = scope
        self.vaultKeys = vaultKeys
        self.dryRun = dryRun
        self.injectionTarget = injectionTarget
    }
}

/// T.4b — Credential injection point invoked by `HookRouter` after
/// the budget gate and confirmation gate pass.
///
/// The gateway is intentionally synchronous + closure-driven so it
/// can run inside `HookRouter.handle()` without an actor bridge on
/// every tool call. Production wiring (`HookRouter.credentialVaultLookup`
/// in `HookRouter.swift`) supplies a sync closure that reads from
/// `CredentialVault.shared` (a `DispatchSemaphore` bridge happens at
/// that seam, not here). Tests pass an in-memory closure directly so
/// they exercise the policy without touching SQLite or the actor.
///
/// The token-events recorder is also pluggable — production records
/// to `SessionDatabase.shared`; tests pass a recorder backed by a
/// temp DB so they can read back the row and assert keyname + scope
/// were captured but the credential value was NOT.
public enum CredentialGateway {
    /// Synchronous lookup closure. Returns the resolved value for the
    /// given `(key, scope, dryRun)` tuple, or a structured error.
    /// The contract matches `CredentialVault.read(...)`'s — production
    /// implementations bridge to the actor; test implementations are
    /// pure.
    public typealias Lookup = (
        _ key: String,
        _ scope: String,
        _ dryRun: Bool
    ) -> Result<Data, CredentialVaultError>

    /// Successful resolution carried back to the caller.
    public struct Injection: Sendable, Equatable {
        /// Key → resolved bytes (real or FAKE_KEY sentinel). Iteration
        /// order mirrors `CredentialGatewayConfig.vaultKeys`.
        public let values: [(key: String, value: Data)]
        /// Scope the values came from.
        public let scope: String
        /// Whether the lookup was a dry run. Surfaced so the tool
        /// runtime can opt to refuse if it doesn't accept fakes.
        public let dryRun: Bool
        /// Where the values should land in the tool invocation.
        public let target: CredentialGatewayConfig.InjectionTarget

        public static func == (lhs: Injection, rhs: Injection) -> Bool {
            guard lhs.scope == rhs.scope,
                  lhs.dryRun == rhs.dryRun,
                  lhs.target == rhs.target,
                  lhs.values.count == rhs.values.count
            else { return false }
            for (l, r) in zip(lhs.values, rhs.values) {
                if l.key != r.key || l.value != r.value { return false }
            }
            return true
        }
    }

    /// Decision returned to the caller.
    public enum Decision: Sendable, Equatable {
        /// No gateway configured (nil) or `enabled == false`. Caller
        /// proceeds without injection. No row is written.
        case notConfigured
        /// All keys resolved. `Injection.values` is non-empty unless
        /// the config asked for zero keys (legal but a no-op).
        case proceed(Injection)
        /// At least one declared key was missing AND the config was
        /// not in dry-run mode. The reason carries the missing key +
        /// scope (the operator needs both to act).
        case deny(reason: String)
    }

    /// Recorder seam — production uses `.live` (writes to
    /// `SessionDatabase.shared` via `recordTokenEvent`). Tests pass
    /// a recorder backed by a temp DB and read the row back to
    /// assert the credential value was never serialized.
    public protocol Recorder: Sendable {
        func recordInjection(
            toolName: String,
            keys: [String],
            scope: String,
            dryRun: Bool,
            sessionId: String?,
            projectRoot: String?
        )
    }

    /// Production recorder. Routes to `SessionDatabase.shared`. Read
    /// pre-T.4b token_events flow: every row's `command` column
    /// already runs through `PersistenceRedaction.redactedString`
    /// (which calls `SecretDetector.scan`). The structured payload
    /// we serialize never contains the value — only key names — so
    /// the redaction step is defense-in-depth, not load-bearing.
    public struct LiveRecorder: Recorder {
        public init() {}
        public func recordInjection(
            toolName: String,
            keys: [String],
            scope: String,
            dryRun: Bool,
            sessionId: String?,
            projectRoot: String?
        ) {
            let payload = canonicalPayload(keys: keys, scope: scope, dryRun: dryRun)
            SessionDatabase.shared.recordTokenEvent(
                sessionId: sessionId ?? "anonymous",
                paneId: nil,
                projectRoot: projectRoot,
                source: "intercept",
                toolName: toolName,
                model: nil,
                inputTokens: 0,
                outputTokens: 0,
                savedTokens: 0,
                costCents: 0,
                feature: "credential_gateway",
                command: payload,
                modelTier: nil
            )
        }
    }

    /// Database-backed recorder for tests. Identical payload shape
    /// as `LiveRecorder` so tests assert against production shape.
    public struct DatabaseRecorder: Recorder {
        let database: SessionDatabase
        public init(database: SessionDatabase) {
            self.database = database
        }
        public func recordInjection(
            toolName: String,
            keys: [String],
            scope: String,
            dryRun: Bool,
            sessionId: String?,
            projectRoot: String?
        ) {
            let payload = canonicalPayload(keys: keys, scope: scope, dryRun: dryRun)
            database.recordTokenEvent(
                sessionId: sessionId ?? "anonymous",
                paneId: nil,
                projectRoot: projectRoot,
                source: "intercept",
                toolName: toolName,
                model: nil,
                inputTokens: 0,
                outputTokens: 0,
                savedTokens: 0,
                costCents: 0,
                feature: "credential_gateway",
                command: payload,
                modelTier: nil
            )
        }
    }

    /// Canonical `command`-column payload for a credential-gateway
    /// row. Records keyname + scope + dry-run flag. Never the value.
    /// The shape is `keys=a,b scope=default dry_run=false` — tests
    /// match on prefix + substring rather than exact bytes so the
    /// shape can evolve without breaking older fixtures.
    static func canonicalPayload(keys: [String], scope: String, dryRun: Bool) -> String {
        let keysJoined = keys.joined(separator: ",")
        return "credential_gateway keys=\(keysJoined) scope=\(scope) dry_run=\(dryRun)"
    }

    /// Evaluate the gateway for a given tool. Pure of side effects
    /// other than (a) calling the injected lookup and (b) recording
    /// a row via `recorder` on `.proceed`. No row is written on
    /// `.notConfigured` or `.deny` — those are not "successful
    /// injections" and recording them would spam the audit chain.
    @discardableResult
    public static func evaluate(
        toolName: String,
        config: CredentialGatewayConfig?,
        lookup: Lookup,
        recorder: Recorder = LiveRecorder(),
        sessionId: String? = nil,
        projectRoot: String? = nil
    ) -> Decision {
        guard let config, config.enabled else {
            return .notConfigured
        }

        var resolved: [(key: String, value: Data)] = []
        resolved.reserveCapacity(config.vaultKeys.count)

        for key in config.vaultKeys {
            switch lookup(key, config.scope, config.dryRun) {
            case .success(let value):
                resolved.append((key: key, value: value))
            case .failure(let err):
                switch err {
                case let .missingKey(missingKey, scope):
                    return .deny(reason: denyReason(key: missingKey, scope: scope))
                }
            }
        }

        recorder.recordInjection(
            toolName: toolName,
            keys: config.vaultKeys,
            scope: config.scope,
            dryRun: config.dryRun,
            sessionId: sessionId,
            projectRoot: projectRoot
        )

        return .proceed(.init(
            values: resolved,
            scope: config.scope,
            dryRun: config.dryRun,
            target: config.injectionTarget
        ))
    }

    /// Build the deny-reason string surfaced to the agent caller via
    /// `permissionDecisionReason`. Carries BOTH key and scope so the
    /// operator can run `senkani vault add` without guessing.
    public static func denyReason(key: String, scope: String) -> String {
        return "Credential gateway: missing key \"\(key)\" at scope \"\(scope)\". " +
            "Run `senkani vault add --key \(key) --scope \(scope)` to seed it."
    }
}
