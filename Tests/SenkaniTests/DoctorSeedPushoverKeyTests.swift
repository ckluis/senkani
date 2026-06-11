import Testing
import Foundation
@testable import CLI
@testable import Core

/// T.6c child A contract tests for `senkani doctor --seed-pushover-key`
/// (`phase-t6c-doctor-seed-subcommand-2026-06-09`).
///
/// HERMETIC by construction: every test drives the testable
/// `Doctor.seedPushoverKeyMotion` with (a) a scripted prompt reader in
/// place of the echo-disabled tty read, (b) a `CredentialVault` backed by
/// an `InMemoryKeychainStore` — the REAL login Keychain is never opened,
/// read, or written — and (c) an in-memory audit spy in place of the
/// `SessionDatabase` recorder, so no SQLite row is written. The secrets
/// here are FAKE strings; seeding the REAL Pushover token is the
/// operator leg of the parent T.6c item.
@Suite("Doctor --seed-pushover-key — T.6c prompt-twice seed motion")
struct DoctorSeedPushoverKeyTests {

    /// Scripted prompt reader: returns queued entries in order, `nil`
    /// once exhausted. Records every prompt string it was shown so tests
    /// can assert how many prompts fired.
    private final class ScriptedPrompts: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [String?]
        private var _promptsShown: [String] = []
        init(_ entries: [String?]) { self.queue = entries }
        var promptsShown: [String] {
            lock.lock(); defer { lock.unlock() }; return _promptsShown
        }
        func read(_ prompt: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            _promptsShown.append(prompt)
            guard !queue.isEmpty else { return nil }
            return queue.removeFirst()
        }
    }

    /// Captures audit payloads — the ONLY audit sink in these tests; no
    /// `SessionDatabase` row is ever written.
    private final class AuditSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _payloads: [String] = []
        var payloads: [String] {
            lock.lock(); defer { lock.unlock() }; return _payloads
        }
        func record(_ payload: String) {
            lock.lock(); defer { lock.unlock() }; _payloads.append(payload)
        }
    }

    /// A FAKE credential with a distinctive fragment so the no-secret
    /// audit assertion can also check for partial leakage.
    private static let fakeSecret = "po-FAKE-app-token-XyZzY123:po-FAKE-user-key-456"

    @Test("match: entry + confirm agree ⇒ credential written through the Keychain seam under the canonical key, exactly one audit row")
    func matchWritesThroughKeychainSeam() async throws {
        let vault = CredentialVault(store: InMemoryKeychainStore())
        let prompts = ScriptedPrompts([Self.fakeSecret, Self.fakeSecret])
        let audit = AuditSpy()

        let outcome = try await Doctor.seedPushoverKeyMotion(
            vault: vault,
            promptReader: prompts.read,
            recordAudit: audit.record
        )

        #expect(outcome == .seeded)
        #expect(prompts.promptsShown.count == 2,
                "the motion must prompt exactly twice (entry + confirm), got \(prompts.promptsShown.count)")

        // The write went through the Keychain seam (CredentialVault over
        // KeychainStore) under the canonical key + scope the transport
        // sibling reads.
        let readBack = try await vault.read(
            key: PushoverCredentialsRef.vaultKey,
            scope: PushoverCredentialsRef.vaultScope
        )
        #expect(readBack == Data(Self.fakeSecret.utf8))

        // Exactly ONE audit row for the successful seed.
        #expect(audit.payloads.count == 1)
    }

    @Test("mismatch: entry and confirm differ ⇒ rejected, NO vault write, NO audit row")
    func mismatchRejects() async throws {
        let store = InMemoryKeychainStore()
        let vault = CredentialVault(store: store)
        let prompts = ScriptedPrompts([Self.fakeSecret, "a-DIFFERENT-entry"])
        let audit = AuditSpy()

        let outcome = try await Doctor.seedPushoverKeyMotion(
            vault: vault,
            promptReader: prompts.read,
            recordAudit: audit.record
        )

        #expect(outcome == .abortedMismatch)
        let keys = try await vault.list(scope: PushoverCredentialsRef.vaultScope)
        #expect(keys.isEmpty, "a mismatch must leave the vault untouched, found keys: \(keys)")
        #expect(audit.payloads.isEmpty, "a mismatch must record NO audit row")
    }

    @Test("audit row carries the key NAME only — the canonical payload never contains the secret (not even a fragment)")
    func auditRowHasNoSecret() async throws {
        let vault = CredentialVault(store: InMemoryKeychainStore())
        let prompts = ScriptedPrompts([Self.fakeSecret, Self.fakeSecret])
        let audit = AuditSpy()

        let outcome = try await Doctor.seedPushoverKeyMotion(
            vault: vault,
            promptReader: prompts.read,
            recordAudit: audit.record
        )
        #expect(outcome == .seeded)

        let payload = try #require(audit.payloads.first)
        // Canonical, name-only shape (the formatter has no parameter by
        // which the secret could arrive).
        #expect(payload == Doctor.seedPushoverAuditPayload(
            key: PushoverCredentialsRef.vaultKey,
            scope: PushoverCredentialsRef.vaultScope
        ))
        #expect(payload == "pushover.seed key=senkani.pushover scope=default")
        #expect(payload.contains(PushoverCredentialsRef.vaultKey))
        // Never the secret — whole OR distinctive fragment.
        #expect(!payload.contains(Self.fakeSecret))
        #expect(!payload.contains("XyZzY123"))
    }

    @Test("missing confirm: nil second entry ⇒ aborted, NO write, NO audit row")
    func missingConfirmAborts() async throws {
        let vault = CredentialVault(store: InMemoryKeychainStore())
        let prompts = ScriptedPrompts([Self.fakeSecret, nil])
        let audit = AuditSpy()

        let outcome = try await Doctor.seedPushoverKeyMotion(
            vault: vault,
            promptReader: prompts.read,
            recordAudit: audit.record
        )

        #expect(outcome == .abortedMissingConfirm)
        let keys = try await vault.list(scope: PushoverCredentialsRef.vaultScope)
        #expect(keys.isEmpty, "a missing confirm must leave the vault untouched, found keys: \(keys)")
        #expect(audit.payloads.isEmpty, "a missing confirm must record NO audit row")
    }

    @Test("missing entry: whitespace-only first entry ⇒ aborted at the FIRST prompt (confirm never shown), NO write, NO audit row")
    func missingEntryAborts() async throws {
        let vault = CredentialVault(store: InMemoryKeychainStore())
        let prompts = ScriptedPrompts(["   "])
        let audit = AuditSpy()

        let outcome = try await Doctor.seedPushoverKeyMotion(
            vault: vault,
            promptReader: prompts.read,
            recordAudit: audit.record
        )

        #expect(outcome == .abortedMissingEntry)
        #expect(prompts.promptsShown.count == 1,
                "a missing entry must abort BEFORE the confirm prompt, prompts shown: \(prompts.promptsShown.count)")
        let keys = try await vault.list(scope: PushoverCredentialsRef.vaultScope)
        #expect(keys.isEmpty)
        #expect(audit.payloads.isEmpty)
    }
}
