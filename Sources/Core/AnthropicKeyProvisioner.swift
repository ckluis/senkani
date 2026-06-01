import Foundation

/// V.13b-1 — vault record for a provisioned upstream Anthropic API key.
///
/// Unlike `OpenAIKeyRecord` (which persists only a hash VERIFIER), this
/// record carries the **actual upstream secret** plus its operator label,
/// because the key must be replayed verbatim to api.anthropic.com when the
/// Anthropic serve arm lands (v13b-2). It therefore lives in the encrypted
/// macOS Keychain (`MacOSKeychainStore`), never a flat file.
///
/// Both `key` and `label` round-trip: `label` will later feed the
/// audit-chain `key_label` column once the Anthropic record path is built
/// (v13b-2). Storing it here means the label is captured at provision time
/// and is retrievable without re-prompting the operator.
public struct AnthropicKeyRecord: Codable, Sendable, Equatable {
    /// The upstream Anthropic API key (the secret, replayed verbatim).
    public let key: String
    /// Operator-facing label. Required at provision time; round-trips so it
    /// can later source the audit-chain `key_label`.
    public let label: String

    public init(key: String, label: String) {
        self.key = key
        self.label = label
    }
}

/// V.13b-1 — provisions upstream Anthropic API keys into the credential
/// vault. The plaintext key is read from STDIN (never a `--key` flag, so it
/// cannot land in shell history) and stored under a per-label item via the
/// macOS Keychain seam.
public enum AnthropicKeyProvisioner {
    /// Vault scope all Anthropic upstream keys share. Distinct from the
    /// OpenAI-endpoint scope: these are SECRETS bound for the Keychain, not
    /// hash verifiers bound for a flat file.
    public static let vaultScope = "anthropic-key"

    /// Resolve the `CredentialVault` backing Anthropic upstream keys.
    /// Production uses the real macOS Keychain; tests inject an
    /// `InMemoryKeychainStore` and never call this factory.
    ///
    /// CI invariant: this is the ONLY constructor of `MacOSKeychainStore`,
    /// and it is reached only from the live `senkani vault add anthropic-key`
    /// path — never from a test.
    public static func vault() -> CredentialVault {
        #if canImport(Security)
        return CredentialVault(store: MacOSKeychainStore())
        #else
        // Non-Apple platforms have no Keychain; fall back to in-memory so the
        // package still builds. Production targets macOS, where the Security
        // branch above is taken.
        return CredentialVault(store: InMemoryKeychainStore())
        #endif
    }

    /// Normalize a key read from STDIN: strip a single trailing newline and
    /// any surrounding whitespace so `echo $KEY | senkani vault add …` does
    /// not bake a `\n` into the stored secret. Pure — no I/O — so it is
    /// directly testable.
    public static func normalizeKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Thrown when a required field is missing or the normalized key is
    /// empty. Equatable so tests can assert the exact case.
    public enum ProvisionError: Error, Equatable, CustomStringConvertible {
        case emptyKey
        case missingLabel

        public var description: String {
            switch self {
            case .emptyKey:
                return "no API key was read from STDIN. Pipe the key in, e.g. `pbpaste | senkani vault add anthropic-key --label work`."
            case .missingLabel:
                return "--label is required for anthropic-key (it later sources the audit-chain key_label)."
            }
        }
    }

    /// Store an upstream Anthropic key (already STDIN-normalized) under the
    /// per-label item, persisting the label so both round-trip. The account
    /// key is the label, so re-provisioning the same label updates in place
    /// (the Keychain store's add-vs-update path).
    public static func store(
        key: String,
        label: String,
        vault: CredentialVault
    ) async throws {
        let normalized = normalizeKey(key)
        guard !normalized.isEmpty else { throw ProvisionError.emptyKey }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else { throw ProvisionError.missingLabel }

        let record = AnthropicKeyRecord(key: normalized, label: trimmedLabel)
        let data = try JSONEncoder().encode(record)
        try await vault.write(key: trimmedLabel, scope: vaultScope, value: data)
    }

    /// Read back a provisioned record by label. Used by tests to prove the
    /// key + label round-trip; the Anthropic serve arm (v13b-2) will use the
    /// equivalent path to source the upstream key + `key_label`.
    public static func load(
        label: String,
        vault: CredentialVault
    ) async throws -> AnthropicKeyRecord {
        let data = try await vault.read(key: label, scope: vaultScope)
        return try JSONDecoder().decode(AnthropicKeyRecord.self, from: data)
    }

    /// V.13b-1 follow-up — revoke a provisioned Anthropic key by label, so a
    /// rotated or suspected-compromised key can be cleanly evicted from the
    /// vault. Deletes via the existing `KeychainStore.delete` seam under the
    /// shared `vaultScope`. Removing an ABSENT label is a clean no-op (the
    /// in-memory store drops a missing key silently; `MacOSKeychainStore.delete`
    /// maps `errSecItemNotFound` → success), so a re-run is idempotent.
    ///
    /// Returns `true` when a record was actually present and evicted, `false`
    /// when the label was already absent (the no-op case). The caller uses this
    /// to avoid a FALSE "it's gone" confirmation on a typo'd `--label`: on a
    /// revocation verb an operator reacting to suspected compromise must not be
    /// told a live key was revoked when nothing matched. The presence probe runs
    /// BEFORE the delete; the delete still always runs so the post-condition
    /// ("no such label remains") holds regardless.
    @discardableResult
    public static func remove(
        label: String,
        vault: CredentialVault
    ) async throws -> Bool {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else { throw ProvisionError.missingLabel }
        let wasPresent = try await vault.list(scope: vaultScope).contains(trimmedLabel)
        try await vault.delete(key: trimmedLabel, scope: vaultScope)
        return wasPresent
    }
}
