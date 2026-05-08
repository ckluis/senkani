import Testing
import Foundation
@testable import Core

/// T.4a — vault foundation. Acceptance-driven coverage:
///   - protocol surface uses only Swift-stdlib types (compile-time check
///     via the conformance below — no `Security` types named anywhere)
///   - InMemoryKeychainStore exists, is actor-safe, no disk I/O
///   - CredentialVault default scope == "default"
///   - missing key + dryRun:false throws structured error w/ key+scope
///     and a `localizedDescription` mentioning both + the CLI hint
///   - missing key + dryRun:true returns FAKE_KEY_<scope>_<key>
///   - round-trip is binary-safe
///   - cross-scope reads return missing-key (scope isolation)
///   - list/delete behave per acceptance
@Suite("CredentialVault")
struct CredentialVaultTests {

    @Test("defaultScope constant is the documented value")
    func defaultScopeConstant() {
        #expect(CredentialVault.defaultScope == "default")
    }

    @Test("write then read round-trips bytes verbatim (binary-safe)")
    func roundTripBinarySafe() async throws {
        let store = InMemoryKeychainStore()
        let vault = CredentialVault(store: store)
        // Bytes that include a NUL, high-bits, and non-UTF8 sequences.
        let payload = Data([0x00, 0xFF, 0x10, 0x80, 0xC3, 0x28, 0xDE, 0xAD, 0xBE, 0xEF])
        try await vault.write(key: "api-token", value: payload)
        let got = try await vault.read(key: "api-token")
        #expect(got == payload)
    }

    @Test("missing key with dryRun:false throws structured missingKey carrying key+scope")
    func missingKeyThrowsStructured() async throws {
        let vault = CredentialVault(store: InMemoryKeychainStore())
        do {
            _ = try await vault.read(key: "absent", scope: "engagement-42")
            Issue.record("expected missingKey throw, got value")
        } catch let CredentialVaultError.missingKey(key, scope) {
            #expect(key == "absent")
            #expect(scope == "engagement-42")
        } catch {
            Issue.record("expected CredentialVaultError.missingKey, got \(error)")
        }
    }

    @Test("missingKey localizedDescription mentions both key and scope and the CLI hint")
    func missingKeyDescription() {
        let err = CredentialVaultError.missingKey(key: "OPENAI_API_KEY", scope: "engagement-7")
        let msg = err.localizedDescription
        #expect(msg.contains("OPENAI_API_KEY"))
        #expect(msg.contains("engagement-7"))
        #expect(msg.contains("senkani vault add"))
    }

    @Test("missing key with dryRun:true returns FAKE_KEY sentinel and does not throw")
    func dryRunReturnsFakeKey() async throws {
        let vault = CredentialVault(store: InMemoryKeychainStore())
        let got = try await vault.read(key: "PUSHOVER_TOKEN", scope: "default", dryRun: true)
        let expected = Data("FAKE_KEY_default_PUSHOVER_TOKEN".utf8)
        #expect(got == expected)
    }

    @Test("dryRun:true does NOT shadow a present real value")
    func dryRunReturnsRealWhenPresent() async throws {
        // FAKE_KEY-never-aliases-real contract: when the key actually
        // exists in the store, dryRun must surface the real value, not
        // the sentinel. The sentinel only fills in for absent keys.
        let store = InMemoryKeychainStore()
        let vault = CredentialVault(store: store)
        let real = Data("real-token-bytes".utf8)
        try await vault.write(key: "tok", value: real)
        let got = try await vault.read(key: "tok", dryRun: true)
        #expect(got == real)
    }

    @Test("scope isolation: writes to one scope are invisible to another")
    func scopeIsolation() async throws {
        let vault = CredentialVault(store: InMemoryKeychainStore())
        try await vault.write(key: "shared", scope: "alpha", value: Data("A".utf8))
        try await vault.write(key: "shared", scope: "beta",  value: Data("B".utf8))

        let a = try await vault.read(key: "shared", scope: "alpha")
        let b = try await vault.read(key: "shared", scope: "beta")
        #expect(a == Data("A".utf8))
        #expect(b == Data("B".utf8))

        // A scope with no writes returns missing-key.
        do {
            _ = try await vault.read(key: "shared", scope: "gamma")
            Issue.record("expected missingKey from empty scope")
        } catch let CredentialVaultError.missingKey(key, scope) {
            #expect(key == "shared")
            #expect(scope == "gamma")
        } catch {
            Issue.record("expected missingKey, got \(error)")
        }
    }

    @Test("list returns sorted keys for the requested scope only; delete removes a single key")
    func listAndDelete() async throws {
        let vault = CredentialVault(store: InMemoryKeychainStore())
        try await vault.write(key: "z", scope: "default", value: Data("z".utf8))
        try await vault.write(key: "a", scope: "default", value: Data("a".utf8))
        try await vault.write(key: "m", scope: "default", value: Data("m".utf8))
        try await vault.write(key: "x", scope: "other",   value: Data("x".utf8))

        let listed = try await vault.list()
        #expect(listed == ["a", "m", "z"])

        try await vault.delete(key: "m")
        let after = try await vault.list()
        #expect(after == ["a", "z"])

        // Delete is scope-aware: deleting "m" in default did not touch
        // the "other" scope.
        let other = try await vault.list(scope: "other")
        #expect(other == ["x"])
    }
}
