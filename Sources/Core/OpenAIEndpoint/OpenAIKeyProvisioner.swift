import Foundation

#if canImport(Darwin)
import Darwin
#endif
#if canImport(Security)
import Security
#endif

/// V.13a-2 — disk-backed `KeychainStore` for the OpenAI-endpoint key
/// records (`openai-endpoint` scope). Persists a 0600 JSON file so a key
/// provisioned by one process (`senkani vault add openai-key`) is visible
/// to another (`senkani serve --openai`).
///
/// Why not `CredentialVault.shared`? That singleton defaults to an
/// in-memory store, which evaporates when the short-lived `vault add`
/// process exits — provisioning would be theatre. The macOS Keychain
/// conformance (T.4c) is the eventual home for *secrets*; these records
/// hold only key HASHES (verifiers, not secrets), so a 0600 JSON file is
/// the right weight today. Values are opaque `Data`; for this scope they
/// are `OpenAIKeyRecord` JSON — the plaintext key is never written.
public actor JSONFileKeychainStore: KeychainStore {
    private let path: String

    public init(path: String) {
        self.path = path
    }

    /// On-disk shape: `{ scope: { key: base64(value) } }`.
    private func loadRoot() -> [String: [String: String]] {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
        else { return [:] }
        return obj
    }

    private func persist(_ root: [String: [String: String]]) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let out = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])

        // 0600 atomic write: temp file with explicit mode + fchmod (bypass
        // umask) + rename. Mirrors SocketAuthToken's F6 discipline so the
        // final file never exists with wider-than-0600 permissions.
        #if canImport(Darwin)
        let temp = path + ".tmp.\(ProcessInfo.processInfo.processIdentifier)"
        let fd = Darwin.open(temp, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
        guard fd >= 0 else {
            throw NSError(domain: "JSONFileKeychainStore", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "open(\(temp)) failed: \(String(cString: strerror(errno)))"
            ])
        }
        _ = Darwin.fchmod(fd, 0o600)
        let written = out.withUnsafeBytes { buf -> Int in
            Darwin.write(fd, buf.baseAddress!, out.count)
        }
        Darwin.close(fd)
        guard written == out.count else {
            Darwin.unlink(temp)
            throw NSError(domain: "JSONFileKeychainStore", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "write truncated: \(written) of \(out.count) bytes"
            ])
        }
        guard Darwin.rename(temp, path) == 0 else {
            Darwin.unlink(temp)
            throw NSError(domain: "JSONFileKeychainStore", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "rename(\(temp) → \(path)) failed: \(String(cString: strerror(errno)))"
            ])
        }
        #else
        try out.write(to: URL(fileURLWithPath: path), options: [.atomic])
        #endif
    }

    public func read(key: String, scope: String) async throws -> Data? {
        guard let b64 = loadRoot()[scope]?[key] else { return nil }
        return Data(base64Encoded: b64)
    }

    public func write(key: String, scope: String, value: Data) async throws {
        var root = loadRoot()
        var bucket = root[scope] ?? [:]
        bucket[key] = value.base64EncodedString()
        root[scope] = bucket
        try persist(root)
    }

    public func delete(key: String, scope: String) async throws {
        var root = loadRoot()
        root[scope]?[key] = nil
        if root[scope]?.isEmpty == true { root[scope] = nil }
        try persist(root)
    }

    public func list(scope: String) async throws -> [String] {
        Array(loadRoot()[scope]?.keys ?? [:].keys).sorted()
    }
}

/// V.13a-2 — provisions OpenAI-endpoint API keys and resolves the vault
/// they live in. The plaintext key is returned to the caller ONCE (for
/// the operator to copy) and is never persisted — only its hash lands in
/// the vault.
public enum OpenAIKeyProvisioner {
    /// Vault scope all OpenAI-endpoint key records share.
    public static let vaultScope = "openai-endpoint"

    /// Plaintext key prefix. Mirrors OpenAI's `sk-` convention with a
    /// senkani namespace so an operator can tell at a glance which
    /// surface a leaked key belongs to.
    public static let keyPrefix = "sk-senkani-"

    /// Default on-disk vault for OpenAI-endpoint keys.
    public static func defaultVaultPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.senkani/openai-keys.json"
    }

    /// Resolve the `CredentialVault` backing OpenAI-endpoint keys. Both
    /// `senkani vault add` and `senkani serve --openai` call this so they
    /// share the same on-disk file.
    public static func vault(path: String = defaultVaultPath()) -> CredentialVault {
        CredentialVault(store: JSONFileKeychainStore(path: path))
    }

    public struct Provisioned: Sendable {
        public let plaintextKey: String
        public let record: OpenAIKeyRecord
    }

    /// Generate a fresh `sk-senkani-…` key (24 random bytes → 48 hex).
    public static func generateKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        #if canImport(Security)
        let rc = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if rc != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        }
        #else
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        #endif
        return keyPrefix + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Build a key + its hash-only record. Pure — no I/O.
    public static func provision(
        preset: String,
        scope: [String],
        rateLimit: Int,
        expiresAt: Date?,
        label: String?,
        now: Date
    ) -> Provisioned {
        let key = generateKey()
        let record = OpenAIKeyRecord(
            keyHash: OpenAIAuthGate.hash(key),
            preset: preset,
            scope: scope,
            rateLimit: rateLimit,
            createdAt: now,
            expiresAt: expiresAt,
            label: label
        )
        return Provisioned(plaintextKey: key, record: record)
    }

    /// Persist a record (hash-only) under the `openai-endpoint` scope.
    public static func store(_ record: OpenAIKeyRecord, vault: CredentialVault) async throws {
        let data = try JSONEncoder().encode(record)
        try await vault.write(key: record.keyHash, scope: vaultScope, value: data)
    }

    /// Load every provisioned record from the vault (for the serve-time
    /// snapshot and the live key count).
    public static func loadAll(vault: CredentialVault) async throws -> [OpenAIKeyRecord] {
        let hashes = try await vault.list(scope: vaultScope)
        var records: [OpenAIKeyRecord] = []
        for hash in hashes {
            guard let data = try? await vault.read(key: hash, scope: vaultScope),
                  let record = try? JSONDecoder().decode(OpenAIKeyRecord.self, from: data)
            else { continue }
            records.append(record)
        }
        return records
    }
}
