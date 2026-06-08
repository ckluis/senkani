import Foundation

// MARK: - ProviderHealthRowViewModel
//
// Phase V.17b-2a — the headless, Core-side presentation logic for the
// V.17b provider-health Dashboard pane row. GUI-facing counterpart to the
// shipped `ProviderHealthSnapshot` data spine (V.17b-1), modeled exactly on
// the ratified `SprintReviewViewModel` precedent: GUI presentation logic
// lives in Core precisely because the `SenkaniTests` target does NOT depend
// on the `SenkaniApp` target — "anything testable about the surface must sit
// here."
//
// This carve ships ONLY the presentation TOKEN + the pure mapping. The
// SwiftUI render (binding `.warning → yellow`, `.danger → red`, the
// at-a-glance distinguishability check) and the refresh-button interaction
// (click → re-probe → row-update) are the operator-gated Cowork REMAINDER on
// the parent `phase-v17b-2-dashboard-pane-row` — they need a running GUI + an
// operator eye and are NOT in this build.
//
// INVARIANTS (Russell / Carmack / Torvalds):
//   - (Russell, no-network) the carve introduces NO probe path; the refresh
//     BUTTON stays in the Cowork remainder. The tier mapping reads the
//     already-no-network snapshot only.
//   - (Carmack, no-IO) `tier(for:)`, `row(from:now:)` and `rows(from:now:)`
//     are PURE functions of `(snapshot, now)` — no DB read, no fd, no spawn.
//     They consume the snapshot the existing `ProviderHealthSnapshotStore`
//     already produces.
//   - (Torvalds, zero new capability surface) Core gains zero new
//     IO/network/process reach; the tier is a TOKEN, never a SwiftUI `Color`,
//     keeping Core AppKit-free.

/// The operator-facing visual tier TOKEN for a provider-health row.
///
/// A pure presentation token, NOT a color: the SwiftUI sibling binds
/// `.warning → yellow` and `.danger → red`; this carve ships only the token
/// (Core stays AppKit-free). `CaseIterable` so the tier-mapping test can
/// assert exhaustiveness — a new case forces a test update.
public enum ProviderHealthVisualTier: String, Sendable, Equatable, Codable, CaseIterable {
    /// `.fresh` snapshot — normal rendering, no operator attention needed.
    case normal
    /// `.stale` snapshot — yellow tier in the GUI; refresh suggested.
    case warning
    /// `.error` snapshot — red tier in the GUI; too old to trust.
    case danger
}

/// A presentation-ready provider-health row. A deterministic projection of a
/// single `ProviderHealthSnapshot` against `now` — one row per `providerID`
/// (last-write-wins is already enforced upstream).
public struct ProviderHealthRow: Sendable, Equatable, Identifiable {
    /// Stable identity for SwiftUI lists — the provider's adapter ID.
    public var id: String { providerID }

    /// The adapter this row describes (e.g. `codex`, `claude_code`).
    public let providerID: String

    /// True when the provider's CLI binary was found locally.
    public let cliInstalled: Bool

    /// Display label for the version: the parsed version string, or
    /// `"not installed"` when the CLI is absent / no version was parsed.
    public let versionLabel: String

    /// Display label for the locally-derived auth state (the snapshot's
    /// `AuthState` raw value, e.g. `"signed_in"`).
    public let authStateLabel: String

    /// The derived freshness tier (`.fresh` / `.stale` / `.error`), carried
    /// through so the GUI can show the raw tier alongside the visual token.
    public let staleness: ProviderHealthSnapshot.Staleness

    /// The visual tier TOKEN mapped from `staleness` via `tier(for:)`.
    public let tier: ProviderHealthVisualTier

    /// Operator-facing remediation hint, surfaced verbatim from the snapshot
    /// when something is off (CLI not installed, signed out, expired).
    public let remediationHint: String?

    /// Derived: whether the row should surface its remediation hint.
    public var showsRemediation: Bool { remediationHint != nil }

    public init(
        providerID: String,
        cliInstalled: Bool,
        versionLabel: String,
        authStateLabel: String,
        staleness: ProviderHealthSnapshot.Staleness,
        tier: ProviderHealthVisualTier,
        remediationHint: String?
    ) {
        self.providerID = providerID
        self.cliInstalled = cliInstalled
        self.versionLabel = versionLabel
        self.authStateLabel = authStateLabel
        self.staleness = staleness
        self.tier = tier
        self.remediationHint = remediationHint
    }
}

public enum ProviderHealthRowViewModel {

    /// Label used when the CLI is not installed / no version could be parsed.
    public static let notInstalledLabel = "not installed"

    /// Pure mapping from the data-side freshness tier to the operator-facing
    /// visual token. Total + side-effect-free: `.fresh → .normal`,
    /// `.stale → .warning`, `.error → .danger`. The `switch` is exhaustive
    /// (no `default`) so a new `Staleness` case is a compile error here.
    public static func tier(
        for staleness: ProviderHealthSnapshot.Staleness
    ) -> ProviderHealthVisualTier {
        switch staleness {
        case .fresh: return .normal
        case .stale: return .warning
        case .error: return .danger
        }
    }

    /// Project a single snapshot into a presentation-ready row. Pure
    /// function of `(snapshot, now)`: staleness via the shipped
    /// `snapshot.staleness(now:)`, tier via `tier(for:)`.
    public static func row(
        from snapshot: ProviderHealthSnapshot,
        now: Date
    ) -> ProviderHealthRow {
        let staleness = snapshot.staleness(now: now)
        let versionLabel: String
        if snapshot.cliInstalled, let version = snapshot.version, !version.isEmpty {
            versionLabel = version
        } else {
            versionLabel = notInstalledLabel
        }
        return ProviderHealthRow(
            providerID: snapshot.providerID,
            cliInstalled: snapshot.cliInstalled,
            versionLabel: versionLabel,
            authStateLabel: snapshot.authState.rawValue,
            staleness: staleness,
            tier: tier(for: staleness),
            remediationHint: snapshot.remediationHint
        )
    }

    /// Project an unordered set of snapshots into presentation rows, stable-
    /// sorted by `providerID` for deterministic GUI ordering (mirroring the
    /// SprintReview section ordering). One row per snapshot; the caller is
    /// responsible for the upstream last-write-wins dedup.
    public static func rows(
        from snapshots: [ProviderHealthSnapshot],
        now: Date
    ) -> [ProviderHealthRow] {
        snapshots
            .map { row(from: $0, now: now) }
            .sorted { $0.providerID < $1.providerID }
    }
}
