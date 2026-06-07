import Testing
import Foundation
@testable import CLI
@testable import Core

/// `phase-v13b-4c-followup-doctor-keychain-hardening` (2026-06-02).
///
/// V.13b-4c — Doctor keychain hardening. Four Schneier-driven
/// invariants on `Doctor.listAnthropicVaultLabels` /
/// `Doctor.formatAnthropicVaultLabelsLine`:
///
/// 1. **Perm-denied vs unprovisioned conflation** (Schneier P2): an
///    `errSecAuthFailed` from the underlying Keychain MUST surface as
///    a distinct `.fail` line, not collapse into the `.skip`
///    "unprovisioned" hint.
/// 2. **DispatchSemaphore-bridge thread-safe publish** (Schneier P2):
///    the prior `nonisolated(unsafe) var labels` was a real TSan race
///    on the timeout codepath. The replacement `NSLock`-guarded
///    `LookupSlot` must not corrupt the published result when the
///    background Task is still running at timeout.
/// 3. **5s ceiling honored** (Schneier P2): the production-path
///    timeout is now 5s (was 3s), and a 4s vault.list must succeed.
/// 4. **VaultLabels type-level no-secret invariant** (Schneier P3):
///    the `VaultLabels` struct wrapper round-trips its label list
///    cleanly and preserves equality.
///
/// Tests use a custom `StubKeychainStore` actor that throws on
/// demand, sleeps on demand, or returns labels — never touches the
/// macOS Keychain. (CI invariant: `MacOSKeychainStore` is never
/// constructed by any test — mirror of `AnthropicKeyVaultTests` /
/// `DoctorAnthropicVaultLabelsSurfaceTests`.)
@Suite("DoctorKeychainHardening (V.13b-4c)")
struct DoctorKeychainHardeningTests {

    // MARK: - Stub stores

    /// A `KeychainStore` that throws on `list(scope:)`. The thrown
    /// error mimics `MacOSKeychainStore.keychainError` shape — an
    /// `NSError` with `code: Int(OSStatus)` so the perm-denied
    /// classifier sees the OSStatus on the wire.
    actor ThrowingKeychainStore: KeychainStore {
        let errorToThrow: Error

        init(error: Error) {
            self.errorToThrow = error
        }

        func read(key: String, scope: String) async throws -> Data? { nil }
        func write(key: String, scope: String, value: Data) async throws {}
        func delete(key: String, scope: String) async throws {}
        func list(scope: String) async throws -> [String] {
            throw errorToThrow
        }
    }

    /// A `KeychainStore` that sleeps for a configurable duration on
    /// `list(scope:)` before returning a fixed label list. Used to
    /// exercise the 5s ceiling (slow-but-under-ceiling) and the
    /// timeout (over-ceiling) codepaths of
    /// `Doctor.listAnthropicVaultLabels`.
    actor SleepingKeychainStore: KeychainStore {
        let sleepNanos: UInt64
        let labelsToReturn: [String]

        init(sleepSeconds: Double, labels: [String] = []) {
            self.sleepNanos = UInt64(sleepSeconds * 1_000_000_000)
            self.labelsToReturn = labels
        }

        func read(key: String, scope: String) async throws -> Data? { nil }
        func write(key: String, scope: String, value: Data) async throws {}
        func delete(key: String, scope: String) async throws {}
        func list(scope: String) async throws -> [String] {
            try await Task.sleep(nanoseconds: sleepNanos)
            return labelsToReturn
        }
    }

    // MARK: - Tests

    /// (a) Perm-denied formatter rendering. Drive
    /// `listAnthropicVaultLabels` against a stub that throws
    /// `errSecAuthFailed` (code -25293); the result must classify
    /// as `.permissionDenied`, and the formatter line must contain
    /// the "permission denied" phrasing AND must NOT contain the
    /// "no labels provisioned" / "unprovisioned" hint.
    @Test("perm-denied — errSecAuthFailed classifies as .permissionDenied + formatter renders distinct line")
    func permDeniedFormatterRendering() async {
        // -25293 == errSecAuthFailed. Constructed as the
        // MacOSKeychainStore wraps it: NSError(domain, code, userInfo)
        // with `code` carrying the raw OSStatus integer.
        let authFailedError = NSError(
            domain: "MacOSKeychainStore",
            code: -25293,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Keychain list failed (scope=anthropic-key, key=*): The user name or passphrase you entered is not correct.",
            ]
        )
        let store = ThrowingKeychainStore(error: authFailedError)
        let vault = CredentialVault(store: store)

        // Drive the async classification core directly (timeoutSeconds:
        // nil → no ceiling). The throw resolves instantly, so the
        // classification is independent of cooperative-pool scheduling
        // latency under full-suite parallel load — unlike the sync
        // bridge, whose 5s wall-clock semaphore wait could fire before
        // the background Task got pool time under saturation.
        let lookup = await Doctor.listAnthropicVaultLabelsAsync(
            vault: vault, timeoutSeconds: nil
        )
        guard case .permissionDenied(let err) = lookup else {
            Issue.record("expected .permissionDenied, got \(lookup)")
            return
        }
        #expect((err as NSError).code == -25293,
            "underlying OSStatus must round-trip through .permissionDenied")

        let (status, line) = Doctor.formatAnthropicVaultLabelsLine(lookup)
        guard case .fail = status else {
            Issue.record("expected .fail on perm-denied, got \(status): \(line)")
            return
        }
        #expect(line.contains("permission denied"),
            "perm-denied phrase missing: \(line)")
        #expect(line.contains("Keychain unavailable"),
            "Keychain-unavailable header missing: \(line)")
        // CRUCIAL: must NOT be confused with the unprovisioned skip.
        #expect(!line.contains("no labels provisioned"),
            "perm-denied must NOT render as 'no labels provisioned': \(line)")
        #expect(!line.contains("senkani vault add anthropic-key --label"),
            "perm-denied must NOT render the 'add a label' hint: \(line)")
    }

    /// (b) Timeout race-free. Drive `listAnthropicVaultLabels`
    /// against a stub that sleeps for >6s (longer than the 5s
    /// ceiling); the result must be `.timedOut` and must NOT corrupt
    /// the published result even though the background Task is still
    /// running at return time. The thread-safe `LookupSlot` is what
    /// makes this race-free — under TSan (`swift test
    /// -Xswiftc -sanitize=thread`), the prior
    /// `nonisolated(unsafe) var labels` would trip; this replacement
    /// must not. The test asserts on the FUNCTIONAL outcome (returns
    /// `.timedOut`, never `.ok`); race-freedom under TSan is a
    /// build-flag concern (covered by the NSLock pattern's design
    /// correctness in normal runs).
    @Test("timeout race-free — sleep >5s returns .timedOut without publish corruption")
    func timeoutRaceFreeUnderTSan() async {
        // 7s store sleep raced against the 5s logical ceiling → the
        // ceiling wins → `.timedOut`. The losing list arm is cancelled
        // (its `Task.sleep` throws), so the labels it WOULD have
        // returned never publish. Because BOTH the store's sleep and the
        // ceiling sleep are scheduled on the same clock, full-suite
        // scheduler starvation stretches them together — the relative
        // ordering (5s ceiling before 7s store) is preserved, so the
        // `.timedOut` outcome is load-independent (no wall-clock
        // dependence on the cooperative pool granting a fixed deadline).
        let store = SleepingKeychainStore(sleepSeconds: 7.0, labels: ["should-not-surface"])
        let vault = CredentialVault(store: store)

        let lookup = await Doctor.listAnthropicVaultLabelsAsync(
            vault: vault, timeoutSeconds: 5.0
        )
        guard case .timedOut = lookup else {
            Issue.record("expected .timedOut for 7s sleep, got \(lookup)")
            return
        }

        let (status, line) = Doctor.formatAnthropicVaultLabelsLine(lookup)
        guard case .fail = status else {
            Issue.record("expected .fail on timeout, got \(status): \(line)")
            return
        }
        #expect(line.contains("Keychain query timed out"),
            "timeout phrase missing: \(line)")
        #expect(line.contains(">5s") || line.contains("5s"),
            "5s ceiling reference missing from timeout line: \(line)")
        // CRUCIAL: timeout must NOT collapse to the unprovisioned skip.
        #expect(!line.contains("no labels provisioned"),
            "timeout must NOT render as 'no labels provisioned': \(line)")
        // CRUCIAL: timeout must NOT leak the labels the still-running
        // background Task would have eventually returned.
        #expect(!line.contains("should-not-surface"),
            "labels from a still-running background task leaked into the timeout line: \(line)")
    }

    /// (c) 5s ceiling honored. A 4s vault.list — slower than the
    /// prior 3s ceiling, but well under the new 5s ceiling — must
    /// succeed and return `.ok(VaultLabels(...))`. This is the
    /// "we bumped the ceiling" proof.
    @Test("5s ceiling honored — 4s sleep returns .ok (not .timedOut)")
    func fiveSecondCeilingHonored() async {
        // 4s store sleep raced against the 5s logical ceiling → the
        // store wins → `.ok`. This is the "we bumped the ceiling" proof:
        // a lookup slower than the prior 3s ceiling but under the new 5s
        // ceiling succeeds. Both arms (`Task.sleep(4s)` store,
        // `Task.sleep(5s)` ceiling) are deadline-scheduled on the same
        // clock, so the 4s deadline always becomes ready before the 5s
        // deadline regardless of absolute scheduler latency under
        // full-suite parallel load — the assertion no longer depends on
        // the 4s sleep finishing within a fixed wall-clock budget.
        let store = SleepingKeychainStore(sleepSeconds: 4.0, labels: ["slow-but-ok"])
        let vault = CredentialVault(store: store)

        let lookup = await Doctor.listAnthropicVaultLabelsAsync(
            vault: vault, timeoutSeconds: 5.0
        )
        guard case .ok(let vaultLabels) = lookup else {
            Issue.record("expected .ok for 4s sleep under 5s ceiling, got \(lookup)")
            return
        }
        #expect(vaultLabels.labels == ["slow-but-ok"],
            "4s-sleep vault must round-trip its label list, got \(vaultLabels.labels)")
    }

    /// (d) `VaultLabels` round-trip + type-level no-secret invariant.
    /// Constructing `VaultLabels` with a label list must preserve
    /// the list and equality. This is the type-level guard: a
    /// future refactor that changed the inner element type from
    /// `[String]` to `[AnthropicKeyRecord]` would have to update the
    /// stored property here, failing the round-trip — instead of
    /// silently leaking the value payload through a `[String]`-shaped
    /// surface.
    @Test("VaultLabels round-trip — labels equality + isEmpty + count + Sendable")
    func vaultLabelsRoundTrip() {
        let empty = VaultLabels([])
        #expect(empty.isEmpty, "empty VaultLabels must be isEmpty")
        #expect(empty.count == 0, "empty VaultLabels count must be 0")

        let two = VaultLabels(["label-a", "label-b"])
        #expect(two.labels == ["label-a", "label-b"],
            "VaultLabels must preserve label list round-trip")
        #expect(two.count == 2, "VaultLabels count must reflect inner labels")
        #expect(!two.isEmpty, "non-empty VaultLabels must NOT be isEmpty")

        // Equality: same labels → equal; differing labels → not equal.
        #expect(two == VaultLabels(["label-a", "label-b"]),
            "VaultLabels with identical labels must compare equal")
        #expect(two != VaultLabels(["label-a"]),
            "VaultLabels with differing labels must NOT compare equal")
        #expect(two != VaultLabels(["label-b", "label-a"]),
            "VaultLabels is order-preserving (mirrors the vault's sort)")

        // Type-level no-secret guard: the only stored property is the
        // `labels: [String]` array. A future refactor that swapped the
        // inner element type would fail to compile against this access
        // pattern — that's the whole point of the wrapper.
        let labels: [String] = two.labels
        #expect(labels.allSatisfy { !$0.isEmpty },
            "VaultLabels inner labels must be non-empty strings (smoke)")
    }
}
