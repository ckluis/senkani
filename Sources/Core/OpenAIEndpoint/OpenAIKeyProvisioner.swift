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
///
/// V.13a-2 hardening (`process-gap-v13a-2-…-2026-05-27`, Finding #2): the
/// store is **sealed to a single non-secret scope** (`allowedScope`,
/// default `openai-endpoint`). Because it persists base64 — NOT encrypted —
/// to a plaintext-on-disk file, backing a scope that holds actual SECRETS
/// would silently leak them. Any read/write/delete/list for a different
/// scope throws `ScopeViolation` so the misuse is LOUD, not silent. Secrets
/// belong in the macOS Keychain store (T.4c), which is encrypted at rest.
public actor JSONFileKeychainStore: KeychainStore {
    private let path: String
    private let allowedScope: String

    /// Thrown when a caller addresses any scope other than the one this
    /// store is sealed to. Equatable so tests can assert the exact pair.
    public struct ScopeViolation: Error, Equatable, CustomStringConvertible {
        public let requested: String
        public let allowed: String
        public var description: String {
            "JSONFileKeychainStore is sealed to scope '\(allowed)' (base64-on-disk, not encrypted); refusing scope '\(requested)'. Use the macOS Keychain store (T.4c) for secrets."
        }
    }

    public init(path: String, allowedScope: String = OpenAIKeyProvisioner.vaultScope) {
        self.path = path
        self.allowedScope = allowedScope
    }

    /// Gate every operation on the sealed scope. A mismatch is a
    /// programming error (a caller wiring this store for a secret scope),
    /// so it throws rather than no-ops.
    private func ensureScope(_ scope: String) throws {
        guard scope == allowedScope else {
            throw ScopeViolation(requested: scope, allowed: allowedScope)
        }
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
        try ensureScope(scope)
        guard let b64 = loadRoot()[scope]?[key] else { return nil }
        return Data(base64Encoded: b64)
    }

    public func write(key: String, scope: String, value: Data) async throws {
        try ensureScope(scope)
        var root = loadRoot()
        var bucket = root[scope] ?? [:]
        bucket[key] = value.base64EncodedString()
        root[scope] = bucket
        try persist(root)
    }

    public func delete(key: String, scope: String) async throws {
        try ensureScope(scope)
        var root = loadRoot()
        root[scope]?[key] = nil
        if root[scope]?.isEmpty == true { root[scope] = nil }
        try persist(root)
    }

    public func list(scope: String) async throws -> [String] {
        try ensureScope(scope)
        return Array(loadRoot()[scope]?.keys ?? [:].keys).sorted()
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

    /// Thrown when `senkani vault add openai-key --preset` is handed a value
    /// that is not a `ModelPreset` raw value. The `--preset` flag selects
    /// the routing tier (v13a-3: the per-key preset wins over the request
    /// `model`), so only the `ModelPreset` vocabulary is valid — provider
    /// names like `openai`/`anthropic` are rejected at provision time rather
    /// than silently degrading to `.auto` at serve time. Equatable so tests
    /// can assert the exact rejected value.
    public struct InvalidPreset: Error, Equatable, CustomStringConvertible {
        public let provided: String
        public var description: String {
            "--preset '\(provided)' is not a routing preset. Valid presets: "
            + ModelPreset.allCases.map(\.rawValue).joined(separator: ", ")
            + "."
        }
    }

    /// Validate + normalize a `--preset` value against the `ModelPreset`
    /// vocabulary. Returns the lowercased raw value on success; throws
    /// `InvalidPreset` (listing every valid case) otherwise.
    ///
    /// This is the strict, provision-time counterpart to the serve-time
    /// `OpenAIChatHandler.preset(forRecordPreset:)`, which stays lenient
    /// (unknown → `.auto`) so a legacy or hand-edited record never crashes
    /// the listener. Validating here means an operator-chosen tier is
    /// honored end-to-end instead of an unrecognized `--preset` silently
    /// resolving to `.auto`.
    public static func validatePreset(_ raw: String) throws -> String {
        let normalized = raw.lowercased()
        guard ModelPreset(rawValue: normalized) != nil else {
            throw InvalidPreset(provided: raw)
        }
        return normalized
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

    /// Synchronous read of the `openai-endpoint` scope records straight off
    /// disk, mirroring `JSONFileKeychainStore`'s `{ scope: { key:
    /// base64(value) } }` shape. Used by `OpenAIKeyRecordSnapshot` so the
    /// serve-time authenticator (a synchronous `@Sendable` closure) can
    /// fetch the CURRENT key set per request without hopping onto the
    /// store actor. Equivalent to `loadAll` for this scope; missing/garbled
    /// file → `[]`.
    public static func loadAllSync(path: String = defaultVaultPath()) -> [OpenAIKeyRecord] {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]],
              let bucket = obj[vaultScope]
        else { return [] }
        var records: [OpenAIKeyRecord] = []
        for (_, b64) in bucket {
            guard let valueData = Data(base64Encoded: b64),
                  let record = try? JSONDecoder().decode(OpenAIKeyRecord.self, from: valueData)
            else { continue }
            records.append(record)
        }
        return records
    }
}

/// V.13a-2 hardening (`process-gap-v13a-2-…-2026-05-27`, Finding #1): a
/// live, mtime-gated snapshot of the OpenAI-endpoint key records. The
/// serve authenticator + chat/embeddings/stream handlers hold ONE instance
/// and call `current()` synchronously per request, so a key provisioned —
/// or revoked — with `senkani vault add/remove openai-key` while
/// `senkani serve --openai` is already running is picked up WITHOUT a
/// restart.
///
/// Cost is bounded: one `stat` per call, and the JSON file is re-read +
/// re-parsed only when its `(modificationDate, size)` pair advances. The
/// size is a belt-and-suspenders second key so a same-second rewrite of a
/// different length is not missed by mtime alone. Thread-safe (`NSLock`) —
/// `NWListener` connection handlers can fire concurrently.
public final class OpenAIKeyRecordSnapshot: @unchecked Sendable {
    private let path: String
    private let lock = NSLock()
    private var loaded = false
    private var cachedKey: CacheKey?
    private var cachedRecords: [OpenAIKeyRecord] = []

    private struct CacheKey: Equatable {
        let mtime: TimeInterval
        let size: Int
    }

    public init(path: String = OpenAIKeyProvisioner.defaultVaultPath()) {
        self.path = path
    }

    /// The current key records, re-reading the file only when it has
    /// changed since the last call. A missing file yields `[]` and is
    /// cached as the nil key, so a steady absence costs one `stat` per call
    /// and zero reads.
    public func current() -> [OpenAIKeyRecord] {
        lock.lock(); defer { lock.unlock() }
        let key = Self.cacheKey(path)
        // Optional `==` makes nil == nil true, so a steady file ABSENCE
        // after the first call serves the cached [] (one stat, no read).
        if loaded && cachedKey == key {
            return cachedRecords
        }
        cachedRecords = OpenAIKeyProvisioner.loadAllSync(path: path)
        cachedKey = key
        loaded = true
        return cachedRecords
    }

    /// `(mtime, size)` of the file, or nil when it does not exist. Two
    /// distinct file states never share a key in practice; identical keys
    /// across calls mean the file is unchanged → serve the cache.
    private static func cacheKey(_ path: String) -> CacheKey? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
              let size = (attrs[.size] as? NSNumber)?.intValue
        else { return nil }
        return CacheKey(mtime: mtime, size: size)
    }
}
