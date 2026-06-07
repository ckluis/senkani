import Foundation

/// Phase V.17b-1 — the per-provider health snapshot row that the V.17b
/// Dashboard pane renders (the SwiftUI render itself is the carved-off
/// Cowork sibling `phase-v17b-2-dashboard-pane-row`; this type ships the
/// data/CLI/no-network spine the pane reads).
///
/// One row per `providerID` in the `provider_health_snapshot` table
/// (migration v48). The snapshot is populated from LOCAL signals only —
/// the provider's own `--version` CLI subcommand + the locally-recorded
/// auth state — and refreshed two ways:
///   1. event-driven: a `turn_completed` `provider_runtime_event` flips
///      that provider's `lastRefresh` forward (no background timer);
///   2. explicit: `senkani provider refresh <provider_id>` re-probes the
///      local CLI and upserts.
///
/// **No-network invariant (Russell):** populating a snapshot writes ZERO
/// rows to `egress_decisions`. The refresh probes the local CLI binary's
/// `--version` and reads locally-recorded auth state; it never makes a
/// network auth/probe call. The invariant is itself test-pinned by an
/// egress-audit-log assertion over a representative refresh session.
///
/// **Staleness (Karpathy, deterministic):** `.fresh` / `.stale` /
/// `.error` is a PURE function of `(lastRefresh, now, ttl)` — never a
/// stored column, never a timer side-effect. The yellow/red VISUAL tier
/// the operator sees is the GUI sibling's job; this type ships the
/// enum + thresholds the pane reads.
public struct ProviderHealthSnapshot: Sendable, Equatable, Codable {

    /// Locally-derivable auth state. Read from the provider's own
    /// on-disk session/credential state — NOT from a network probe.
    /// `unknown` is the fail-safe default when the local state cannot
    /// be classified (Russell: never block, never network-probe to
    /// disambiguate — report `unknown` and let the operator act).
    public enum AuthState: String, Sendable, Equatable, Codable, CaseIterable {
        case signedIn   = "signed_in"
        case signedOut  = "signed_out"
        case expired    = "expired"
        case unknown    = "unknown"
    }

    /// Derived freshness tier. NOT stored — computed from
    /// `(lastRefresh, now, ttl)` by `staleness(now:)`. The GUI sibling
    /// maps `.stale → yellow` and `.error → red`; this type owns only
    /// the enum + the thresholds.
    public enum Staleness: String, Sendable, Equatable, Codable, CaseIterable {
        /// Within the stale TTL — the snapshot is current.
        case fresh
        /// Older than the stale TTL but within the error TTL — yellow
        /// tier in the GUI. The data is probably still accurate but the
        /// operator should refresh.
        case stale
        /// Older than the error TTL — red tier in the GUI. The snapshot
        /// is too old to trust.
        case error
    }

    /// Per-provider TTL thresholds. "Configurable but not auto-tuned"
    /// per the V.17b spec; the v0.4.0 ship uses the spec'd placeholder
    /// defaults (24h stale / 7d error). The 2026-05-31 backlog audit
    /// ruled the TTL-confirm a soft caveat, not a status blocker.
    public struct TTL: Sendable, Equatable, Codable {
        /// Seconds after `lastRefresh` past which the snapshot is `.stale`.
        public let staleSeconds: TimeInterval
        /// Seconds after `lastRefresh` past which the snapshot is `.error`.
        public let errorSeconds: TimeInterval

        public init(staleSeconds: TimeInterval, errorSeconds: TimeInterval) {
            self.staleSeconds = staleSeconds
            self.errorSeconds = errorSeconds
        }

        /// Spec'd placeholder defaults: 24h stale, 7d error.
        public static let standard = TTL(
            staleSeconds: Self.defaultStaleSeconds,
            errorSeconds: Self.defaultErrorSeconds
        )

        /// 24 hours, as a `Core` constant (per the build plan).
        public static let defaultStaleSeconds: TimeInterval = 24 * 60 * 60
        /// 7 days, as a `Core` constant (per the build plan).
        public static let defaultErrorSeconds: TimeInterval = 7 * 24 * 60 * 60
    }

    /// The adapter this snapshot describes (e.g. `codex`, `claude_code`,
    /// `gemini`, `opencode`). Matches `ProviderRuntimeEvent.providerID`.
    public let providerID: String

    /// True when the provider's CLI binary was found locally. When
    /// false, `version`/`selectedModel` are nil and `remediationHint`
    /// names the install step.
    public let cliInstalled: Bool

    /// The version string parsed from the local `--version` output, or
    /// nil when the CLI is not installed / the probe could not parse a
    /// version.
    public let version: String?

    /// Locally-derived auth state.
    public let authState: AuthState

    /// The model the provider's local config currently selects, or nil
    /// when unknown / not installed.
    public let selectedModel: String?

    /// Free-form subscription/plan state read from local config, or nil
    /// when unknown. Not enumerated — provider vocabularies vary.
    public let subscriptionState: String?

    /// Wall-clock moment this snapshot was last refreshed (either by an
    /// explicit `provider refresh` or an event-driven `turn_completed`
    /// flip). Staleness is derived from this against `now`.
    public let lastRefresh: Date

    /// The TTL thresholds applied to this snapshot's staleness.
    public let ttl: TTL

    /// Operator-facing remediation hint when something is off (CLI not
    /// installed, signed out, expired), or nil when healthy.
    public let remediationHint: String?

    public init(
        providerID: String,
        cliInstalled: Bool,
        version: String? = nil,
        authState: AuthState = .unknown,
        selectedModel: String? = nil,
        subscriptionState: String? = nil,
        lastRefresh: Date,
        ttl: TTL = .standard,
        remediationHint: String? = nil
    ) {
        self.providerID = providerID
        self.cliInstalled = cliInstalled
        self.version = version
        self.authState = authState
        self.selectedModel = selectedModel
        self.subscriptionState = subscriptionState
        self.lastRefresh = lastRefresh
        self.ttl = ttl
        self.remediationHint = remediationHint
    }

    /// Derive the freshness tier as a PURE function of
    /// `(lastRefresh, now, ttl)`. Boundaries are inclusive of the older
    /// tier: an age EXACTLY at `staleSeconds` is `.stale`, EXACTLY at
    /// `errorSeconds` is `.error` (so a snapshot that just crossed a TTL
    /// reports the more-conservative tier — fail-safe toward
    /// "refresh me" rather than "I'm fine").
    public func staleness(now: Date = Date()) -> Staleness {
        let age = now.timeIntervalSince(lastRefresh)
        if age >= ttl.errorSeconds {
            return .error
        }
        if age >= ttl.staleSeconds {
            return .stale
        }
        return .fresh
    }
}
