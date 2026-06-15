import Foundation
import Core

/// U.3 leg 4 — seed-gated real-Pushover-transport selection for `senkani autorun`.
///
/// Legs 1–3 hardwired the autorun loop's notification sink to a
/// `PushoverSink` over a `FakePushoverTransport` with a `.synthetic`
/// credential ref and a hardcoded `pushoverSeededForReal = false`, so the
/// loop could never push for real and always refused an unattended run.
/// This leg replaces that stopgap with a real, seed-gated selection:
///
///   - If the operator has genuinely seeded the Pushover credential
///     (`senkani doctor --seed-pushover-key`), build a `PushoverSink` over
///     the REAL `KeychainPushoverTransport` (reads the seed from the
///     Keychain at send time) and report `pushoverSeededForReal == true`.
///   - Otherwise the sink is INERT (`credentials == nil`) and
///     `pushoverSeededForReal == false`, so the existing unattended-refusal
///     gate (`AutorunLoopDriver.unattendedRefusalReason`) still refuses a
///     no-TTY run.
///
/// ## What this leg is and is NOT
/// This is PLUMBING. `CredentialVault.shared` still defaults to the
/// in-memory store (the real macOS Keychain conformance is the unshipped
/// T.4c operator remainder), so in a fresh `senkani autorun` process the
/// vault is EMPTY and the seed-present branch does not fire in production
/// TODAY — it auto-activates the day T.4c lands and the operator seeds.
/// The live device push (the `URLSessionPushoverHTTPClient` network POST),
/// the egress-policy edit, and the first-run approval walk remain the
/// operator leg C of `phase-t6c-1-pushover-seed-operator`; this leg does
/// NOT prove or claim live delivery.
///
/// ## Safety posture (recursive-autonomy guardrail)
/// The seed-presence probe is VALUE-FREE (it lists key NAMES via
/// `CredentialVault.list(scope:)` and checks membership — it NEVER reads
/// the secret bytes, mirroring the `listLabels`/`VaultLabels` no-secret
/// invariant) and FAIL-CLOSED (any timeout or thrown error resolves to
/// "not seeded", so an unattended run refuses rather than starting with a
/// non-working notifier). The same probe drives BOTH the sink construction
/// AND `pushoverSeededForReal`, so the sink and the refusal gate can never
/// disagree.
enum AutorunSinkSelector {

    /// The pure selection decision. Given whether a seed is present and the
    /// transport to use when it is, returns the sink to wire into the loop
    /// plus the `pushoverSeededForReal` flag the unattended-refusal gate
    /// keys on. NO vault, NO network — fully unit-testable.
    ///
    /// - Parameters:
    ///   - seedPresent: whether the operator-seeded Pushover credential is
    ///     present in the vault (resolved separately by `seedPresent(...)`).
    ///   - transport: the transport to install on the seed-present branch.
    ///     Production passes `KeychainPushoverTransport`; tests pass any
    ///     `PushoverTransport`. Irrelevant on the seed-absent branch (the
    ///     inert sink never touches it).
    static func select(seedPresent: Bool, transport: PushoverTransport) -> AutorunSinkSelection {
        if seedPresent {
            // Real, seed-gated send. Use the DEFAULT-initialized ref — its
            // `keychainAccount` defaults to `PushoverCredentialsRef.vaultKey`
            // ("senkani.pushover"), the slot the doctor seed writes and the
            // Keychain transport reads. NOT `.synthetic`.
            return AutorunSinkSelection(
                sink: PushoverSink(credentials: PushoverCredentialsRef(), transport: transport),
                pushoverSeededForReal: true
            )
        }
        // No seed: inert sink (credentials == nil), never sends, and the
        // refusal gate keeps a no-TTY run from starting.
        return AutorunSinkSelection(
            sink: PushoverSink(credentials: nil, transport: transport),
            pushoverSeededForReal: false
        )
    }

    /// The async CORE of the seed-presence probe — the value-free,
    /// fail-closed vault read with NO sync bridge. The synchronous
    /// `seedPresent(...)` wraps this for the CLI's synchronous `run()` body;
    /// TESTS drive THIS directly via `async`/`await` so they never exercise
    /// the sync semaphore bridge under parallel `swift test` load (the
    /// 2026-06-05 cooperative-pool-starvation lesson: a plain `Task` + a
    /// wall-clock ceiling can spuriously time out when ~thousands of tests
    /// saturate the pool — the production CLI path is single-threaded, so
    /// the bridge below is safe there but must not gate a unit test).
    ///
    /// Checks membership of `key` among the scope's key NAMES — it NEVER
    /// reads the secret value (using `read()` would both pull secret bytes
    /// into the CLI process and, in a dry-run vault, return a `FAKE_KEY_`
    /// sentinel that makes an absent key look present).
    ///
    /// FAIL-CLOSED: any thrown error resolves to `false` (so a wedged or
    /// empty store reads as "not seeded").
    static func seedPresentAsync(
        vault: CredentialVault = .shared,
        key: String = PushoverCredentialsRef.vaultKey,
        scope: String = PushoverCredentialsRef.vaultScope
    ) async -> Bool {
        // VALUE-FREE: list key names only; never read the secret bytes.
        let labels = (try? await vault.list(scope: scope)) ?? []
        return labels.contains(key)
    }

    /// Synchronous seed-presence probe for the `ArgumentParser` `run()`
    /// body. Bridges `seedPresentAsync` onto the sync path with the
    /// balanced-semaphore lifecycle proven by `Doctor.vaultRoundTrip` (a
    /// plain `Task` + a wall-clock ceiling + `defer { signal() }`; the
    /// dedicated send-bridge executor is private to the transport and
    /// cannot be reused here).
    ///
    /// FAIL-CLOSED in BOTH bridge-failure directions too: a timeout OR a
    /// missing result resolves to `false`, so a wedged store reads as "not
    /// seeded" and an unattended run refuses — the safe direction.
    static func seedPresent(
        vault: CredentialVault = .shared,
        key: String = PushoverCredentialsRef.vaultKey,
        scope: String = PushoverCredentialsRef.vaultScope,
        ceiling: TimeInterval = 5
    ) -> Bool {
        final class Slot: @unchecked Sendable {
            private let lock = NSLock()
            private var _value: Bool?
            func publish(_ v: Bool) {
                lock.lock(); defer { lock.unlock() }; _value = v
            }
            func snapshot() -> Bool? {
                lock.lock(); defer { lock.unlock() }; return _value
            }
        }
        let slot = Slot()
        let sem = DispatchSemaphore(value: 0)
        Task {
            defer { sem.signal() }
            slot.publish(await seedPresentAsync(vault: vault, key: key, scope: scope))
        }
        // FAIL-CLOSED on a wedged store: timeout ⇒ not seeded.
        if sem.wait(timeout: .now() + ceiling) == .timedOut {
            return false
        }
        // FAIL-CLOSED on a missing result: nil ⇒ not seeded.
        return slot.snapshot() ?? false
    }

    /// The single resolver `AutorunCommand` calls: probe the real vault,
    /// then select the sink over the real Keychain transport. NOT part of
    /// the unit-tested surface — it constructs `URLSessionPushoverHTTPClient`
    /// (the network path is the operator leg C). Tests exercise
    /// `select(seedPresent:transport:)` and `seedPresent(vault:)` directly
    /// with their own injected vault and never touch the network.
    static func resolve(
        vault: CredentialVault = .shared,
        httpClient: any PushoverHTTPClient = URLSessionPushoverHTTPClient()
    ) -> AutorunSinkSelection {
        let present = seedPresent(vault: vault)
        return select(
            seedPresent: present,
            transport: KeychainPushoverTransport(httpClient: httpClient)
        )
    }
}

/// The result of `AutorunSinkSelector`: the notification sink to wire into
/// the autorun loop plus whether a real Pushover seed is present (the flag
/// `AutorunLoopDriver.unattendedRefusalReason` keys on). The two are
/// derived from the same probe so they can never disagree.
struct AutorunSinkSelection {
    let sink: PushoverSink
    let pushoverSeededForReal: Bool
}
