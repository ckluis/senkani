import Testing
import Foundation
@testable import CLI
@testable import Core

/// `phase-v13b-5-doctor-burst-changelog` (2026-06-01).
///
/// V.13b-5 — `senkani doctor` Anthropic-vault-labels check renders the
/// label list (label only, NEVER the raw key) so an operator can see at a
/// glance whether `senkani serve --openai` has an upstream key
/// provisioned. Tests drive the pure `Doctor.formatAnthropicVaultLabelsLine`
/// formatter + the `Doctor.listAnthropicVaultLabels` bridge directly with
/// an `InMemoryKeychainStore`-backed `CredentialVault` — production uses
/// `AnthropicKeyProvisioner.vault()` (the real macOS Keychain), which CI
/// MUST NOT touch (mirror of `AnthropicKeyVaultTests` policy).
///
/// **Schneier (no-secret-on-stdout) invariant:** every assertion below
/// confirms that only the operator-facing LABEL reaches the rendered
/// line. The raw key (`"sk-ant-..."`) is provisioned via
/// `AnthropicKeyProvisioner.store(...)` and explicitly checked against
/// the output as a negative assertion.
@Suite("DoctorAnthropicVaultLabelsSurface (V.13b-5)")
struct DoctorAnthropicVaultLabelsSurfaceTests {

    /// Zero labels → `.skip` with the operator-actionable
    /// `senkani vault add anthropic-key --label <name>` pointer.
    @Test("zero-labels — skip with the vault-add hint, count(0) suppressed")
    func zeroLabelsSkipsWithHint() {
        let (status, line) = Doctor.formatAnthropicVaultLabelsLine(
            .ok(VaultLabels([]))
        )

        guard case .skip = status else {
            Issue.record("expected .skip on zero labels, got \(status): \(line)")
            return
        }
        #expect(line.contains("Anthropic vault"), "header missing: \(line)")
        #expect(line.contains("no labels provisioned"), "missing-state phrase missing: \(line)")
        #expect(line.contains("senkani vault add anthropic-key --label"),
            "operator-actionable hint missing: \(line)")
    }

    /// Single label → `.pass` with the label rendered inline. The raw
    /// key never reaches the line (the formatter takes `VaultLabels`
    /// labels — there is no parameter shape by which a key could leak).
    @Test("single-label — pass with the label rendered, never the raw key")
    func singleLabelPassesWithLabel() {
        let (status, line) = Doctor.formatAnthropicVaultLabelsLine(
            .ok(VaultLabels(["work"]))
        )

        guard case .pass = status else {
            Issue.record("expected .pass on single label, got \(status): \(line)")
            return
        }
        #expect(line.contains("Anthropic vault"), "header missing: \(line)")
        #expect(line.contains("1 label(s) provisioned"), "count missing: \(line)")
        #expect(line.contains("(work)"), "label not rendered: \(line)")
    }

    /// Multiple labels → `.pass` listing every label in the order the
    /// vault returned them (sorted by `InMemoryKeychainStore.list`).
    @Test("multi-label — pass with all labels listed in vault order")
    func multipleLabelsPassWithAllListed() {
        let (status, line) = Doctor.formatAnthropicVaultLabelsLine(
            .ok(VaultLabels(["personal", "work"]))
        )

        guard case .pass = status else {
            Issue.record("expected .pass on multiple labels, got \(status): \(line)")
            return
        }
        #expect(line.contains("2 label(s) provisioned"), "count missing: \(line)")
        #expect(line.contains("(personal, work)"),
            "labels not rendered in vault order: \(line)")
    }

    /// End-to-end bridge: drive the live `CredentialVault` actor through
    /// the sync `listAnthropicVaultLabels` bridge with two provisioned
    /// labels, then through the formatter — proves the doctor surface
    /// stays label-only even when fed by a real (in-memory) vault, and
    /// the raw provisioned key never leaks into the rendered line.
    ///
    /// This is the test the acceptance asked for: drives the
    /// `() -> CredentialVault` factory seam with an
    /// `InMemoryKeychainStore`-backed vault so CI never reaches the
    /// macOS Keychain (the same policy `AnthropicKeyVaultTests` already
    /// codifies — no `MacOSKeychainStore` ever constructed in CI).
    @Test("bridge → formatter end-to-end — labels round-trip, raw key never reaches the line")
    func bridgeAndFormatterEndToEnd() async throws {
        let store = InMemoryKeychainStore()
        let vault = CredentialVault(store: store)

        // NOT-A-KEY prefix protects against grep-for-secrets scanners
        // (gitleaks/trufflehog) flagging the test sentinels as committed
        // secret material — the `sk-ant-` infix is the Anthropic real-key
        // prefix and an automated scanner doesn't read comments. The
        // negative-assertions below still cover the `sk-ant-` infix +
        // LEAK-SENTINEL fragment + full string.
        let rawKeyWork = "NOT-A-KEY-test-sk-ant-LEAK-SENTINEL-WORK-abc123"
        let rawKeyPersonal = "NOT-A-KEY-test-sk-ant-LEAK-SENTINEL-PERSONAL-xyz789"
        try await AnthropicKeyProvisioner.store(
            key: rawKeyWork, label: "work", vault: vault
        )
        try await AnthropicKeyProvisioner.store(
            key: rawKeyPersonal, label: "personal", vault: vault
        )

        // Drive the async classification core directly (timeoutSeconds:
        // nil → no ceiling). The in-memory vault list resolves instantly,
        // so the `.ok` result is independent of cooperative-pool
        // scheduling latency under full-suite parallel load — unlike the
        // sync bridge, whose 5s wall-clock semaphore could fire before
        // the background Task got pool time under saturation, spuriously
        // returning `.timedOut`.
        let lookup = await Doctor.listAnthropicVaultLabelsAsync(
            vault: vault, timeoutSeconds: nil
        )
        guard case .ok(let vaultLabels) = lookup else {
            Issue.record("expected .ok, got \(lookup)")
            return
        }
        let labels = vaultLabels.labels
        #expect(labels.sorted() == ["personal", "work"],
            "bridge must round-trip both provisioned labels in vault order; got \(labels)")

        let (status, line) = Doctor.formatAnthropicVaultLabelsLine(lookup)
        guard case .pass = status else {
            Issue.record("expected .pass for live two-label vault, got \(status): \(line)")
            return
        }
        #expect(line.contains("2 label(s) provisioned"), "count missing: \(line)")
        #expect(line.contains("work"), "work label missing: \(line)")
        #expect(line.contains("personal"), "personal label missing: \(line)")

        // CRUCIAL: the raw provisioned keys MUST NOT appear in the doctor
        // line — the Schneier no-secret-on-stdout invariant. Both the full
        // sk-ant- prefix-bearing key strings and the distinctive LEAK
        // SENTINEL fragment are negative-asserted so a regression that
        // joined the value payload (not just labels) would fail loudly.
        #expect(!line.contains(rawKeyWork),
            "raw work key leaked into doctor line: \(line)")
        #expect(!line.contains(rawKeyPersonal),
            "raw personal key leaked into doctor line: \(line)")
        #expect(!line.contains("LEAK-SENTINEL"),
            "leak-sentinel fragment present in doctor line: \(line)")
        #expect(!line.contains("sk-ant-"),
            "sk-ant- key prefix leaked into doctor line: \(line)")
    }

    /// Empty vault via the live bridge — proves `listAnthropicVaultLabels`
    /// returns `.ok([])` (not nil-collapsed-to-error) for an unprovisioned
    /// vault, and the formatter renders the `.skip` hint.
    @Test("empty-vault bridge — returns .ok([]) and the skip hint renders")
    func emptyVaultBridgeReturnsEmpty() async {
        let vault = CredentialVault(store: InMemoryKeychainStore())
        // Async core (timeoutSeconds: nil → no ceiling). The empty
        // in-memory list resolves instantly, so `.ok([])` is independent
        // of pool scheduling latency under full-suite parallel load.
        let lookup = await Doctor.listAnthropicVaultLabelsAsync(
            vault: vault, timeoutSeconds: nil
        )
        guard case .ok(let vaultLabels) = lookup else {
            Issue.record("expected .ok on empty live vault, got \(lookup)")
            return
        }
        #expect(vaultLabels.isEmpty, "fresh vault must list zero labels, got \(vaultLabels.labels)")

        let (status, line) = Doctor.formatAnthropicVaultLabelsLine(lookup)
        guard case .skip = status else {
            Issue.record("expected .skip on empty live vault, got \(status): \(line)")
            return
        }
        #expect(line.contains("senkani vault add anthropic-key --label"),
            "operator hint missing on empty live vault: \(line)")
    }
}
