import Foundation

#if canImport(Security)
import Security

/// V.13b-1 — the real macOS Keychain conformance of the `KeychainStore`
/// seam. Backs `kSecClassGenericPassword` items so a secret provisioned by
/// one process (`senkani vault add anthropic-key`) survives the short-lived
/// CLI exit and is readable by another (a future `senkani serve` Anthropic
/// arm). Unlike `JSONFileKeychainStore` — which holds only hash VERIFIERS
/// and writes base64-on-disk — this store holds actual SECRETS, so it must
/// live in the encrypted-at-rest Keychain, never a flat file.
///
/// ## CI / test invariant (DO NOT REMOVE)
/// `MacOSKeychainStore` is wired ONLY in production (`senkani vault add
/// anthropic-key` constructs it via `AnthropicKeyProvisioner.vault()`).
/// It is NEVER constructed by any test — all test coverage injects
/// `InMemoryKeychainStore`. The real login Keychain must therefore never be
/// touched in CI. If you find a test that constructs this type, that test is
/// wrong: route it through `InMemoryKeychainStore` instead. Real-Keychain
/// CRUD is operator / CI-host territory (a host with an unlocked login
/// Keychain), explicitly out of scope for the in-process test suite.
///
/// ## Scope mapping
/// `kSecAttrService` namespaces by scope (`"dev.senkani.vault.<scope>"`) and
/// `kSecAttrAccount` carries the per-label/scope key. This keeps each scope's
/// items in their own service bucket so `list(scope:)` can enumerate one
/// scope with `kSecMatchLimitAll` without colliding with other scopes' keys.
///
/// ## Accessibility
/// `kSecAttrAccessibleAfterFirstUnlock` (NOT `WhenUnlocked`). A senkani secret
/// is read by a potentially long-running, headless-ish process (`senkani
/// serve`) that must keep authenticating upstream even after the operator's
/// screen locks. `WhenUnlocked` would make the secret unreadable the moment
/// the screen locks and silently 401 a running serve; `AfterFirstUnlock`
/// keeps it readable for the rest of the boot session once the user has
/// logged in at least once — the least-surprising posture for a daemon-style
/// CLI credential. It is still not exported to other devices.
public struct MacOSKeychainStore: KeychainStore {
    /// Stable service prefix. Per-scope items live under
    /// `"\(servicePrefix).\(scope)"` so each scope is its own bucket.
    public static let servicePrefix = "dev.senkani.vault"

    public init() {}

    private func service(for scope: String) -> String {
        "\(MacOSKeychainStore.servicePrefix).\(scope)"
    }

    public func read(key: String, scope: String) async throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: scope),
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &item) {
            SecItemCopyMatching(query as CFDictionary, $0)
        }
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw keychainError(status, op: "read", scope: scope, key: key)
        }
    }

    public func write(key: String, scope: String, value: Data) async throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: scope),
            kSecAttrAccount as String: key,
        ]
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = value
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // Add-vs-update: re-provisioning an existing label must NOT
            // hard-fail. Update the value in place under the same item.
            let attrs: [String: Any] = [kSecValueData as String: value]
            let updStatus = SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary)
            guard updStatus == errSecSuccess else {
                throw keychainError(updStatus, op: "update", scope: scope, key: key)
            }
        default:
            throw keychainError(addStatus, op: "write", scope: scope, key: key)
        }
    }

    public func delete(key: String, scope: String) async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: scope),
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        // A delete of an absent item is a no-op success (mirrors the
        // in-memory store, which never errors on a missing key).
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status, op: "delete", scope: scope, key: key)
        }
    }

    public func list(scope: String) async throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: scope),
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &result) {
            SecItemCopyMatching(query as CFDictionary, $0)
        }
        switch status {
        case errSecSuccess:
            let items = (result as? [[String: Any]]) ?? []
            let accounts = items.compactMap { $0[kSecAttrAccount as String] as? String }
            return accounts.sorted()
        case errSecItemNotFound:
            return []
        default:
            throw keychainError(status, op: "list", scope: scope, key: "*")
        }
    }

    /// Surface an `OSStatus` as a stdlib `Error` so the `KeychainStore`
    /// contract leaks no `Security` types to callers.
    private func keychainError(_ status: OSStatus, op: String, scope: String, key: String) -> Error {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return NSError(domain: "MacOSKeychainStore", code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: "Keychain \(op) failed (scope=\(scope), key=\(key)): \(message)",
        ])
    }
}
#endif
