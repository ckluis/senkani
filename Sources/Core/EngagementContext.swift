import Foundation
import CryptoKit

/// T.2c-1 — per-engagement state passed through `AnonymizationProxy`
/// and `SurrogateVault`. Carrying the `SymmetricKey` on the context
/// (rather than fetching it inside the vault) keeps the trust
/// boundary explicit: every method that touches an
/// `EngagementContext` is on the AES-GCM-trusted path.
///
/// `sensitivityThreshold` is the PIIClassifier softmax floor the
/// `PIISpanEmitter` applies — `redteam` pane mode lowers it
/// (T.2c-2) while normal panes keep the production default.
public struct EngagementContext: Sendable {
    public let id: String
    public let vaultPath: URL
    public let key: SymmetricKey
    public let sensitivityThreshold: Double

    public init(
        id: String,
        vaultPath: URL,
        key: SymmetricKey,
        sensitivityThreshold: Double
    ) {
        self.id = id
        self.vaultPath = vaultPath
        self.key = key
        self.sensitivityThreshold = sensitivityThreshold
    }
}

/// Provenance of the vault encryption key. Recorded in
/// `SurrogateVault.meta.key_source` so audits can distinguish a
/// Keychain-backed engagement from a random-fallback engagement
/// without re-deriving.
public enum EngagementKeySource: String, Sendable {
    case credentialVault = "credential_vault"
    case fallbackRandom = "fallback_random"
}

/// Actor responsible for assembling an `EngagementContext` —
/// deriving the symmetric key via `CredentialVault` when available,
/// falling back to a persisted random key otherwise. The fallback
/// keystore lives at `<root>/.keys` with mode 0600; entries are
/// keyed by engagement id and base64-encoded.
public actor EngagementContextProvider {

    /// Production root. Tests pass a `/tmp/...` override so the
    /// operator's `~/.senkani/surrogates` is never touched.
    public static let defaultRoot: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".senkani/surrogates", isDirectory: true)

    /// Hardcoded `vault-key` token inside `engagement-<id>` scope —
    /// matches the convention reserved for T.4 / T.2c integration.
    public static let credentialVaultKey = "vault-key"

    private let credentialVault: CredentialVault
    private let root: URL
    private let fallbackKeysURL: URL

    public init(
        credentialVault: CredentialVault = CredentialVault.shared,
        root: URL = EngagementContextProvider.defaultRoot,
        fallbackKeysURL: URL? = nil
    ) {
        self.credentialVault = credentialVault
        self.root = root
        self.fallbackKeysURL = fallbackKeysURL ?? root.appendingPathComponent(".keys")
    }

    /// Build a context. Returns the context paired with the source
    /// the key came from so `SurrogateVault` can persist it as
    /// `meta.key_source` provenance.
    public func makeContext(
        id: String,
        sensitivityThreshold: Double
    ) async throws -> (EngagementContext, EngagementKeySource) {
        try ensureRoot()
        let scope = "engagement-\(id)"
        var keySource: EngagementKeySource
        var key: SymmetricKey
        do {
            let data = try await credentialVault.read(
                key: EngagementContextProvider.credentialVaultKey,
                scope: scope
            )
            key = SymmetricKey(data: data)
            keySource = .credentialVault
        } catch CredentialVaultError.missingKey {
            key = try loadOrCreateFallbackKey(for: id)
            keySource = .fallbackRandom
        }
        let vaultPath = root.appendingPathComponent("\(id).sqlite")
        let context = EngagementContext(
            id: id,
            vaultPath: vaultPath,
            key: key,
            sensitivityThreshold: sensitivityThreshold
        )
        return (context, keySource)
    }

    private func ensureRoot() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.path) {
            try fm.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        if !fm.fileExists(atPath: fallbackKeysURL.path) {
            fm.createFile(
                atPath: fallbackKeysURL.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            )
        }
    }

    private func loadOrCreateFallbackKey(for id: String) throws -> SymmetricKey {
        var map: [String: String] = [:]
        if let data = try? Data(contentsOf: fallbackKeysURL), !data.isEmpty,
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            map = decoded
        }
        if let b64 = map[id], let raw = Data(base64Encoded: b64), raw.count == 32 {
            return SymmetricKey(data: raw)
        }
        let newKey = SymmetricKey(size: .bits256)
        let raw = newKey.withUnsafeBytes { Data($0) }
        map[id] = raw.base64EncodedString()
        let serialized = try JSONEncoder().encode(map)
        try serialized.write(to: fallbackKeysURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fallbackKeysURL.path
        )
        return newKey
    }
}
