import Testing
import Foundation
@testable import Core

// Phase V.17b-2a — tests for the headless Core presentation logic that maps
// the shipped `ProviderHealthSnapshot` into presentation-ready rows. Pure
// functions of `(snapshot, now)` — no DB, no fd, no spawn — modeled on
// `SprintReviewViewModelTests`. The SwiftUI render + refresh-button
// interaction are the operator-gated Cowork REMAINDER and are NOT exercised
// here.

// MARK: - Helpers

private let anchor = Date(timeIntervalSince1970: 1_713_360_000) // 2024-04-17

/// Build a snapshot `age` seconds old relative to `now` (default `anchor`),
/// using the shipped `TTL.standard` thresholds unless overridden.
private func snapshot(
    providerID: String = "codex",
    cliInstalled: Bool = true,
    version: String? = "1.2.3",
    authState: ProviderHealthSnapshot.AuthState = .signedIn,
    age: TimeInterval = 0,
    now: Date = anchor,
    ttl: ProviderHealthSnapshot.TTL = .standard,
    remediationHint: String? = nil
) -> ProviderHealthSnapshot {
    ProviderHealthSnapshot(
        providerID: providerID,
        cliInstalled: cliInstalled,
        version: version,
        authState: authState,
        lastRefresh: now.addingTimeInterval(-age),
        ttl: ttl,
        remediationHint: remediationHint
    )
}

// MARK: - Tier mapping

@Suite("ProviderHealthRowViewModel — tier mapping")
struct ProviderHealthVisualTierMappingTests {

    /// Tier-mapping table (one `#expect` per arm) plus CaseIterable
    /// exhaustiveness: every `Staleness` case maps to a distinct, defined
    /// tier. A new `Staleness` case forces this test to be updated (and the
    /// exhaustive `switch` in `tier(for:)` to gain an arm).
    @Test func tierMappingTableAndExhaustiveness() {
        // Per-arm table.
        #expect(ProviderHealthRowViewModel.tier(for: .fresh) == .normal)
        #expect(ProviderHealthRowViewModel.tier(for: .stale) == .warning)
        #expect(ProviderHealthRowViewModel.tier(for: .error) == .danger)

        let mapping: [ProviderHealthSnapshot.Staleness: ProviderHealthVisualTier] = [
            .fresh: .normal,
            .stale: .warning,
            .error: .danger,
        ]
        // Every Staleness case is covered by the table above...
        for staleness in ProviderHealthSnapshot.Staleness.allCases {
            #expect(mapping[staleness] != nil,
                "Staleness.\(staleness) has no tier mapping — update tier(for:) + this test")
            #expect(ProviderHealthRowViewModel.tier(for: staleness) == mapping[staleness])
        }
        // ...and the mapping covers exactly the known cases (no stragglers).
        #expect(mapping.count == ProviderHealthSnapshot.Staleness.allCases.count)
        // The visual tier token itself is also closed (token contract).
        #expect(ProviderHealthVisualTier.allCases.count == 3)
    }
}

// MARK: - Row field mapping

@Suite("ProviderHealthRowViewModel — row mapping")
struct ProviderHealthRowMappingTests {

    @Test func installedSignedInFreshSnapshotMapsToNormalRow() {
        let snap = snapshot(
            providerID: "claude_code",
            cliInstalled: true,
            version: "2.0.1",
            authState: .signedIn,
            age: 0
        )
        let row = ProviderHealthRowViewModel.row(from: snap, now: anchor)

        #expect(row.id == "claude_code")
        #expect(row.providerID == "claude_code")
        #expect(row.cliInstalled == true)
        #expect(row.versionLabel == "2.0.1")
        #expect(row.authStateLabel == "signed_in")
        #expect(row.staleness == .fresh)
        #expect(row.tier == .normal)
        #expect(row.showsRemediation == false)
        #expect(row.remediationHint == nil)
    }

    @Test func remediationHintSurfacesVerbatimWhenCliMissing() {
        let hint = "Install the codex CLI: `brew install codex` then `senkani provider refresh codex`."
        let snap = snapshot(
            providerID: "codex",
            cliInstalled: false,
            version: nil,
            authState: .unknown,
            age: 0,
            remediationHint: hint
        )
        let row = ProviderHealthRowViewModel.row(from: snap, now: anchor)

        #expect(row.cliInstalled == false)
        #expect(row.versionLabel == ProviderHealthRowViewModel.notInstalledLabel)
        #expect(row.showsRemediation == true)
        #expect(row.remediationHint == hint)  // passed through verbatim
    }
}

// MARK: - Boundary tiers (data-side of yellow / red)

@Suite("ProviderHealthRowViewModel — boundary tiers")
struct ProviderHealthRowBoundaryTests {

    @Test func staleBoundaryYieldsWarningTier() {
        // Aged just past the stale TTL ⇒ .stale ⇒ .warning (yellow tier).
        let age = ProviderHealthSnapshot.TTL.standard.staleSeconds + 1
        let snap = snapshot(age: age, ttl: .standard)
        let row = ProviderHealthRowViewModel.row(from: snap, now: anchor)

        #expect(row.staleness == .stale)
        #expect(row.tier == .warning)
    }

    @Test func errorBoundaryYieldsDangerTier() {
        // Aged just past the error TTL ⇒ .error ⇒ .danger (red tier).
        let age = ProviderHealthSnapshot.TTL.standard.errorSeconds + 1
        let snap = snapshot(age: age, ttl: .standard)
        let row = ProviderHealthRowViewModel.row(from: snap, now: anchor)

        #expect(row.staleness == .error)
        #expect(row.tier == .danger)
    }
}

// MARK: - rows() determinism

@Suite("ProviderHealthRowViewModel — rows() determinism")
struct ProviderHealthRowsDeterminismTests {

    @Test func rowsSortStablyByProviderIDOneRowEach() {
        let unordered = [
            snapshot(providerID: "opencode"),
            snapshot(providerID: "codex"),
            snapshot(providerID: "gemini"),
            snapshot(providerID: "claude_code"),
        ]
        let rows = ProviderHealthRowViewModel.rows(from: unordered, now: anchor)

        // One row per snapshot, deterministically sorted by providerID.
        #expect(rows.map(\.providerID) == ["claude_code", "codex", "gemini", "opencode"])
        #expect(rows.count == unordered.count)

        // Stable + idempotent: re-running over the same input yields identical rows.
        let again = ProviderHealthRowViewModel.rows(from: unordered, now: anchor)
        #expect(rows == again)
    }
}
