import Foundation

/// T.4a — Credential vault foundation.
///
/// `KeychainStore` is the storage seam shared between `CredentialVault`
/// (T.4) and the future Pushover sink (T.6c). Conformances expose only
/// Swift-stdlib types — no `Security` framework leak (`OSStatus`,
/// `CFTypeRef`) — so the protocol can be reused on non-macOS test
/// platforms and so callers never depend on macOS Security types.
///
/// The protocol is `async throws` from day 1. Today's macOS Keychain
/// reads are synchronous OSStatus calls, but `CredentialVault` is an
/// `actor`, so all callers are already on an async path — the async
/// surface costs nothing and unblocks future broker / hardware-token
/// store conformances that are inherently async.
public protocol KeychainStore: Sendable {
    func read(key: String, scope: String) async throws -> Data?
    func write(key: String, scope: String, value: Data) async throws
    func delete(key: String, scope: String) async throws
    func list(scope: String) async throws -> [String]
}

/// In-memory `KeychainStore` for tests and dry-run scenarios. An
/// `actor` so the internal map is serialized without explicit locking;
/// no disk I/O. Real macOS Keychain conformance lands in T.4c.
public actor InMemoryKeychainStore: KeychainStore {
    private var storage: [String: [String: Data]] = [:]

    public init() {}

    public func read(key: String, scope: String) async throws -> Data? {
        storage[scope]?[key]
    }

    public func write(key: String, scope: String, value: Data) async throws {
        var bucket = storage[scope] ?? [:]
        bucket[key] = value
        storage[scope] = bucket
    }

    public func delete(key: String, scope: String) async throws {
        storage[scope]?[key] = nil
        if storage[scope]?.isEmpty == true {
            storage[scope] = nil
        }
    }

    public func list(scope: String) async throws -> [String] {
        Array(storage[scope]?.keys ?? [:].keys).sorted()
    }
}

/// Error surface for `CredentialVault`. `missingKey` carries BOTH key
/// and scope so the operator can pick the right `senkani vault add`
/// invocation without guessing.
///
/// Callers that log this error in shipped (non-debug) log paths SHOULD
/// redact `scope` if their scope namespace exposes engagement IDs or
/// similar sensitive identifiers. Log redaction is the caller's
/// responsibility — the API contract is "the error carries enough
/// for actionability"; T.4b's hook injection point and T.4c's CLI
/// add the runtime-side log redaction.
public enum CredentialVaultError: Error, Equatable, Sendable {
    case missingKey(key: String, scope: String)
}

extension CredentialVaultError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .missingKey(key, scope):
            return "Credential missing for key=\"\(key)\" scope=\"\(scope)\". " +
                "Run `senkani vault add --key \(key) --scope \(scope)` to seed it."
        }
    }
}

/// Vault facade over a `KeychainStore`. An `actor` so concurrent reads
/// across pane handlers and MCP tools are serialized without locks
/// at the call site.
///
/// `scope` defaults to `CredentialVault.defaultScope == "default"` —
/// the only scope used today. T.2c slots in `engagement-<id>` scopes
/// without an ABI break by passing a non-default value.
public actor CredentialVault {
    public static let defaultScope = "default"

    private let store: KeychainStore

    public init(store: KeychainStore) {
        self.store = store
    }

    /// Read a credential. With `dryRun: false` (production default),
    /// a missing key throws `CredentialVaultError.missingKey`. With
    /// `dryRun: true`, a missing key returns sentinel bytes shaped
    /// `FAKE_KEY_<scope>_<key>` — opaque from the contract's
    /// perspective beyond the `FAKE_KEY_` prefix; callers must not
    /// parse the suffix.
    public func read(
        key: String,
        scope: String = CredentialVault.defaultScope,
        dryRun: Bool = false
    ) async throws -> Data {
        if let value = try await store.read(key: key, scope: scope) {
            return value
        }
        if dryRun {
            return Data("FAKE_KEY_\(scope)_\(key)".utf8)
        }
        throw CredentialVaultError.missingKey(key: key, scope: scope)
    }

    public func write(
        key: String,
        scope: String = CredentialVault.defaultScope,
        value: Data
    ) async throws {
        try await store.write(key: key, scope: scope, value: value)
    }

    public func delete(
        key: String,
        scope: String = CredentialVault.defaultScope
    ) async throws {
        try await store.delete(key: key, scope: scope)
    }

    public func list(
        scope: String = CredentialVault.defaultScope
    ) async throws -> [String] {
        try await store.list(scope: scope)
    }
}
