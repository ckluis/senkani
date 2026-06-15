import Testing
import Foundation
@testable import CLI
@testable import Core

/// U.3 leg 4 — `AutorunSinkSelector` wires the autorun loop's notification
/// sink to the REAL `KeychainPushoverTransport` only when the operator has
/// genuinely seeded the Pushover credential, and otherwise keeps the sink
/// inert while the unattended-refusal gate keeps a no-TTY run from starting.
///
/// These tests exercise the pure decision (`select`) and the value-free
/// fail-closed presence probe (`seedPresent`) with their own injected vault
/// and transport. They NEVER touch the network or `CredentialVault.shared`;
/// the `URLSessionPushoverHTTPClient` live-device push (and `resolve()`'s
/// URLSession construction) is the operator leg C remainder and is not
/// exercised here.
struct AutorunSinkSelectorTests {

    // MARK: - Pure decision (`select`)

    @Test("select(seedPresent: true) reports seededForReal and sends through the transport")
    func selectSeededSends() throws {
        let transport = FakePushoverTransport()
        let selection = AutorunSinkSelector.select(seedPresent: true, transport: transport)

        #expect(selection.pushoverSeededForReal == true)

        // Non-nil credentials + the default Pushover allow-engine ⇒ a notify
        // reaches the injected transport (the wired-real path).
        try selection.sink.notify(.notifyDone(toolName: "leg4", summary: "done"))
        #expect(transport.sent.count == 1)
    }

    @Test("select(seedPresent: false) is inert: no send, not seededForReal")
    func selectUnseededInert() throws {
        let transport = FakePushoverTransport()
        let selection = AutorunSinkSelector.select(seedPresent: false, transport: transport)

        #expect(selection.pushoverSeededForReal == false)

        // credentials == nil ⇒ the sink short-circuits before the transport;
        // nothing is ever sent.
        try selection.sink.notify(.notifyDone(toolName: "leg4", summary: "done"))
        #expect(transport.sent.isEmpty)
    }

    // MARK: - Value-free presence probe (`seedPresent`)

    // NOTE: these drive the async CORE `seedPresentAsync` directly via
    // await — NOT the synchronous `seedPresent` bridge — so they never
    // exercise the plain-Task + DispatchSemaphore lifecycle under parallel
    // `swift test` load (the 2026-06-05 cooperative-pool-starvation lesson:
    // a sync semaphore bridge driven directly by a test can spuriously time
    // out when the pool is saturated). The sync bridge is the CLI's
    // single-threaded path; its fail-closed logic is the same value.

    @Test("seedPresentAsync returns true when the pushover slot is seeded (list-based, value-free)")
    func seedPresentTrue() async throws {
        let vault = CredentialVault(store: InMemoryKeychainStore())
        try await vault.write(
            key: PushoverCredentialsRef.vaultKey,
            scope: PushoverCredentialsRef.vaultScope,
            value: Data("app-token:user-key".utf8)
        )
        #expect(await AutorunSinkSelector.seedPresentAsync(vault: vault) == true)
    }

    @Test("seedPresentAsync returns false for a fresh (empty) vault — the production default")
    func seedPresentFalseEmpty() async {
        let vault = CredentialVault(store: InMemoryKeychainStore())
        #expect(await AutorunSinkSelector.seedPresentAsync(vault: vault) == false)
    }

    @Test("seedPresentAsync ignores a different key in the scope (membership, not just non-empty)")
    func seedPresentFalseOtherKey() async throws {
        let vault = CredentialVault(store: InMemoryKeychainStore())
        try await vault.write(
            key: "some.other.credential",
            scope: PushoverCredentialsRef.vaultScope,
            value: Data("x".utf8)
        )
        #expect(await AutorunSinkSelector.seedPresentAsync(vault: vault) == false)
    }

    @Test("seedPresentAsync is FAIL-CLOSED: a throwing store resolves to not-seeded")
    func seedPresentFailClosed() async {
        let vault = CredentialVault(store: ThrowingKeychainStore())
        #expect(await AutorunSinkSelector.seedPresentAsync(vault: vault) == false)
    }

    // MARK: - Refusal coherence (the same flag drives the safety gate)

    @Test("the selector flag drives the unattended-refusal gate coherently")
    func refusalCoherence() {
        let unseeded = AutorunSinkSelector.select(seedPresent: false, transport: FakePushoverTransport())
        // No seed + no TTY ⇒ the run is refused.
        #expect(
            AutorunLoopDriver.unattendedRefusalReason(
                pushoverSeeded: unseeded.pushoverSeededForReal,
                attendedOnTTY: false
            ) != nil
        )

        let seeded = AutorunSinkSelector.select(seedPresent: true, transport: FakePushoverTransport())
        // Genuinely seeded ⇒ a no-TTY unattended run is allowed.
        #expect(
            AutorunLoopDriver.unattendedRefusalReason(
                pushoverSeeded: seeded.pushoverSeededForReal,
                attendedOnTTY: false
            ) == nil
        )
    }
}

/// Test-only `KeychainStore` that throws on every operation — exercises the
/// FAIL-CLOSED branch of `AutorunSinkSelector.seedPresent` (a wedged/erroring
/// store must resolve to "not seeded", never "seeded").
private struct ThrowingKeychainStore: KeychainStore {
    struct Boom: Error {}
    func read(key: String, scope: String) async throws -> Data? { throw Boom() }
    func write(key: String, scope: String, value: Data) async throws { throw Boom() }
    func delete(key: String, scope: String) async throws { throw Boom() }
    func list(scope: String) async throws -> [String] { throw Boom() }
}
