import Testing
import Foundation
@testable import Core

#if canImport(Darwin)
import Darwin
#endif

/// V.13a-2 persistence hardening
/// (`process-gap-v13a-2-openai-key-vault-persistence-hardening-2026-05-27`).
/// Two findings filed by the v13a-2 build round:
///
///   1. `serve` read a START-TIME key snapshot (no live reload) — a key
///      provisioned mid-serve 401'd until restart. The live
///      `OpenAIKeyRecordSnapshot` now reflects mid-serve provisioning AND
///      revocation without a restart, at a bounded `(mtime, size)`-gated
///      cost.
///   2. `JSONFileKeychainStore` was a general `KeychainStore` that persists
///      base64 (NOT encrypted) to a 0600 JSON file — a future caller could
///      wire it for a SECRET scope and silently leak plaintext. It is now
///      SEALED to a single non-secret scope and throws `ScopeViolation` on
///      any other scope, across all four protocol methods.
@Suite("OpenAI key-vault persistence hardening (V.13a-2)")
struct OpenAIKeyVaultHardeningTests {

    private static func tempPath() -> String {
        NSTemporaryDirectory() + "v13a-2-hardening-\(UUID().uuidString).json"
    }

    /// Provision a hash-only record for `key` and persist it under the
    /// `openai-endpoint` scope at `path` (mirrors `vault add openai-key`).
    private static func storeKey(
        _ key: String, into path: String, scope: [String] = ["chat"]
    ) async throws {
        let record = OpenAIKeyRecord(
            keyHash: OpenAIAuthGate.hash(key),
            preset: "openai", scope: scope,
            rateLimit: 60, createdAt: Date(timeIntervalSince1970: 0)
        )
        try await OpenAIKeyProvisioner.store(record, vault: OpenAIKeyProvisioner.vault(path: path))
    }

    // MARK: - Finding #1 — live reload of the key snapshot

    @Test("snapshot picks up a key provisioned AFTER it first read (no restart)")
    func snapshotPicksUpMidServeProvisioning() async throws {
        let path = Self.tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // "serve" starts: the snapshot first reads an absent vault.
        let keys = OpenAIKeyRecordSnapshot(path: path)
        #expect(keys.current().isEmpty)

        // Operator provisions a key while "serve" is already running.
        let key = "sk-senkani-midserve"
        try await Self.storeKey(key, into: path)

        // The very next request sees it WITHOUT a restart, and the auth gate
        // admits it.
        let live = keys.current()
        #expect(live.count == 1)
        let decision = OpenAIAuthGate.decide(
            authorizationHeader: "Bearer \(key)", requestedSurface: "chat",
            now: Date(), records: live, rateLimiter: OpenAIRateLimiter()
        )
        guard case .ok = decision else {
            Issue.record("mid-serve provisioned key should be admitted, got \(decision)"); return
        }
    }

    @Test("snapshot reflects mid-serve REVOCATION and is (mtime,size)-gated")
    func snapshotReflectsRevocationAndCaches() async throws {
        let path = Self.tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let key = "sk-senkani-revoke"
        try await Self.storeKey(key, into: path)
        let keys = OpenAIKeyRecordSnapshot(path: path)
        #expect(keys.current().count == 1)
        // A second call with no file change returns the same (cached) set —
        // bounded cost is the contract.
        #expect(keys.current().count == 1)

        // Revoke: delete the record (file shrinks to `{}` — a size change the
        // cache key catches even if mtime resolution coincided).
        try await OpenAIKeyProvisioner.vault(path: path)
            .delete(key: OpenAIAuthGate.hash(key), scope: OpenAIKeyProvisioner.vaultScope)

        let after = keys.current()
        #expect(after.isEmpty)
        let decision = OpenAIAuthGate.decide(
            authorizationHeader: "Bearer \(key)", requestedSurface: "chat",
            now: Date(), records: after, rateLimiter: OpenAIRateLimiter()
        )
        guard case .unauthorized = decision else {
            Issue.record("revoked key should 401 without a restart, got \(decision)"); return
        }
    }

    // MARK: - Finding #2 — JSONFileKeychainStore sealed to its scope

    @Test("JSONFileKeychainStore rejects a foreign scope on every method; allowed scope works")
    func storeSealedToScope() async throws {
        let path = Self.tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = JSONFileKeychainStore(path: path)   // default allowedScope = openai-endpoint
        let foreign = "anthropic-secret"
        let secret = Data("super-secret-plaintext".utf8)

        // All four protocol methods refuse a scope other than the sealed one
        // — a write oracle AND a read/list oracle are both closed.
        await #expect(throws: JSONFileKeychainStore.ScopeViolation.self) {
            try await store.write(key: "k", scope: foreign, value: secret)
        }
        await #expect(throws: JSONFileKeychainStore.ScopeViolation.self) {
            _ = try await store.read(key: "k", scope: foreign)
        }
        await #expect(throws: JSONFileKeychainStore.ScopeViolation.self) {
            try await store.delete(key: "k", scope: foreign)
        }
        await #expect(throws: JSONFileKeychainStore.ScopeViolation.self) {
            _ = try await store.list(scope: foreign)
        }

        // The sealed (allowed) scope round-trips normally.
        try await store.write(key: "h", scope: OpenAIKeyProvisioner.vaultScope, value: Data("hash-only".utf8))
        let back = try await store.read(key: "h", scope: OpenAIKeyProvisioner.vaultScope)
        #expect(back == Data("hash-only".utf8))

        // The refused secret never reached disk under any scope.
        let onDisk = FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) } ?? ""
        #expect(!onDisk.contains("super-secret-plaintext"))
        #expect(!onDisk.contains(foreign))
    }

    // MARK: - Regression — v13a-2's own invariants still hold

    @Test("regression: 0600 + hash-only on disk; loadAllSync matches loadAll")
    func regressionPermissionsAndSyncLoad() async throws {
        let path = Self.tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let provisioned = OpenAIKeyProvisioner.provision(
            preset: "openai", scope: ["chat"], rateLimit: 60,
            expiresAt: nil, label: "reg", now: Date(timeIntervalSince1970: 0)
        )
        let vault = OpenAIKeyProvisioner.vault(path: path)
        try await OpenAIKeyProvisioner.store(provisioned.record, vault: vault)

        // hash-only: the file carries the verifier hash, never the plaintext.
        let raw = try #require(FileManager.default.contents(atPath: path))
        let onDisk = String(decoding: raw, as: UTF8.self)
        #expect(onDisk.contains(provisioned.record.keyHash))
        #expect(!onDisk.contains(provisioned.plaintextKey))

        // 0600 (owner-only) still holds after the sealing change.
        #if canImport(Darwin)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = try #require(attrs[.posixPermissions] as? NSNumber)
        #expect((perms.uint16Value & 0o177) == 0)
        #endif

        // The synchronous loader the snapshot uses agrees with the async
        // `loadAll` — the live path and the start-time path read the same set.
        let asyncRecords = try await OpenAIKeyProvisioner.loadAll(vault: vault)
        let syncRecords = OpenAIKeyProvisioner.loadAllSync(path: path)
        #expect(syncRecords.count == asyncRecords.count)
        #expect(syncRecords.first?.keyHash == asyncRecords.first?.keyHash)
        #expect(syncRecords.first?.keyHash == provisioned.record.keyHash)
    }
}
