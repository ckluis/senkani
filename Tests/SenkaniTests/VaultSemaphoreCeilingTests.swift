import Testing
import Foundation
@testable import Core

/// phase-hook-relay-async-decouple-a-2 — the credential-vault
/// `DispatchSemaphore` bridge stays SYNCHRONOUS by conscious,
/// operator-ratified decision (the verdict depends on the lookup
/// result, so the read is on the critical path by necessity; see the
/// a-2 item `## Design decision 2026-07-06`). This suite REGRESSION-PINS
/// the leave-sync outcome:
///
///   1. The 5s blocking ceiling is a named constant pinned to 5 — a
///      future edit that silently WIDENS (or removes) it trips this pin.
///   2. The actual synchronous bridge fails CLOSED (DENY) on the
///      defensive timeout path — exercised deterministically via a
///      slow store + tiny injected ceiling (correct-direction: a 500ms
///      read always exceeds a 10ms ceiling; saturation only slows the
///      read, so there is no flake).
///   3. The synchronous bridge fails CLOSED (DENY) on a missing key
///      (flake-immune: the Box default equals the published value).
///   4. A timeout NEVER fabricates success — a slow store that WOULD
///      have returned a real value still DENYs under a tiny ceiling, so
///      no injection happens without an in-time explicit vault hit.
///
/// ## CI invariant (Schneier fail-CLOSED, no production behavior flips)
/// Every test drives an in-memory / test-double store. NO test flips
/// `CredentialVault.shared` to the real Keychain, and NO test passes a
/// `ceiling` to the PRODUCTION install path — the production 5s deadline
/// stays pinned to `credentialVaultLookupCeilingSeconds`.
@Suite("a-2 — credential-vault semaphore ceiling (leave-sync regression pins)")
struct VaultSemaphoreCeilingTests {

    // A store whose read sleeps `delayNanos` before returning `value`.
    // Models a wedged `securityd` for the timeout path. Only `read` is
    // exercised; the other seam methods are inert.
    private actor SlowKeychainStore: KeychainStore {
        let delayNanos: UInt64
        let value: Data?
        init(delayNanos: UInt64, value: Data?) {
            self.delayNanos = delayNanos
            self.value = value
        }
        func read(key: String, scope: String) async throws -> Data? {
            try? await Task.sleep(nanoseconds: delayNanos)
            return value
        }
        func write(key: String, scope: String, value: Data) async throws {}
        func delete(key: String, scope: String) async throws {}
        func list(scope: String) async throws -> [String] { [] }
    }

    // MARK: 1. ceiling constant pinned to 5s

    @Test("the sync-bridge blocking ceiling is pinned to 5 seconds")
    func ceilingConstantPinnedToFiveSeconds() {
        // A future edit that widens/shrinks/removes this MUST update this
        // pin — the whole point of the leave-sync close is that the
        // defensive fail-CLOSED deadline cannot drift silently.
        #expect(HookRouter.credentialVaultLookupCeilingSeconds == 5,
            "the credential-vault sync bridge ceiling must stay 5s; a silent widen defeats the wedged-securityd fail-CLOSED guarantee, a silent shrink spuriously DENYs slow-but-valid Keychain reads")
    }

    // MARK: 2. sync bridge times out → fail-CLOSED DENY

    @Test("sync bridge fails CLOSED (DENY) when the store is wedged past the ceiling")
    func syncBridgeTimesOutFailClosedOnWedgedStore() {
        // Store sleeps 500ms then would return nil (→ missingKey). Ceiling
        // 10ms. The 500ms >> 10ms margin makes the timeout deterministic
        // in the correct direction under any pool load.
        let vault = CredentialVault(store: SlowKeychainStore(delayNanos: 500_000_000, value: nil))
        let result = HookRouter.credentialVaultLookupBridge(
            vault: vault, key: "WEDGED_KEY", scope: "engagement-9", dryRun: false,
            ceiling: .milliseconds(10)
        )
        guard case .failure(.missingKey(let key, let scope)) = result else {
            Issue.record("expected fail-CLOSED .missingKey on timeout, got \(result)")
            return
        }
        // The defensive timeout still carries the actionable key + scope.
        #expect(key == "WEDGED_KEY")
        #expect(scope == "engagement-9")
    }

    // MARK: 3. sync bridge missing key → fail-CLOSED DENY (flake-immune)

    @Test("sync bridge fails CLOSED (DENY) on a missing key end-to-end")
    func syncBridgeMissingKeyIsFailClosedDeny() {
        // Empty in-memory vault + generous ceiling. Flake-immune: whether
        // the background Task publishes the missingKey OR the wait times
        // out, the Box default is already .missingKey — identical result.
        let vault = CredentialVault(store: InMemoryKeychainStore())
        let result = HookRouter.credentialVaultLookupBridge(
            vault: vault, key: "ABSENT", scope: "default", dryRun: false,
            ceiling: .seconds(5)
        )
        guard case .failure(.missingKey(let key, let scope)) = result else {
            Issue.record("expected .missingKey DENY on empty vault, got \(result)")
            return
        }
        #expect(key == "ABSENT")
        #expect(scope == "default")
    }

    // MARK: 4. timeout never fabricates success

    @Test("sync bridge NEVER injects a value the store returns after the ceiling")
    func syncBridgeTimeoutNeverFabricatesSuccess() {
        // Store WOULD return a real value, but only after 500ms — past the
        // 10ms ceiling. The bridge must DENY, never inject the late value:
        // no injection without an in-time explicit vault hit. (The late
        // publish into the heap-retained Box after we return is harmless —
        // the timeout branch already returned the DENY default.)
        let secret = Data("LATE-SECRET-should-never-inject".utf8)
        let vault = CredentialVault(store: SlowKeychainStore(delayNanos: 500_000_000, value: secret))
        let result = HookRouter.credentialVaultLookupBridge(
            vault: vault, key: "SLOW_HIT", scope: "default", dryRun: false,
            ceiling: .milliseconds(10)
        )
        switch result {
        case .success(let bytes):
            Issue.record("timeout fabricated a success (injected late value); bytes=\(bytes.count)B")
        case .failure(.missingKey(let key, let scope)):
            #expect(key == "SLOW_HIT")
            #expect(scope == "default")
        }
    }
}
