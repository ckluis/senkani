import Testing
import Foundation
import ArgumentParser
@testable import Core
@testable import CLI

/// V.13b-1 — `senkani vault add anthropic-key`.
///
/// ALL coverage here drives the `InMemoryKeychainStore` seam (via
/// `AnthropicKeyProvisioner.store`/`load`). NO test constructs
/// `MacOSKeychainStore` or calls `AnthropicKeyProvisioner.vault()` — the real
/// login Keychain is never touched in CI. Real-Keychain CRUD is operator /
/// CI-host territory (a host with an unlocked login Keychain).
///
/// Bullet-3 re-scope (panel-justified): the original acceptance wanted a test
/// asserting `--label` lands on the `key_label` of a recorded
/// `OpenAIServedRequestSink` row. That is premature — `key_label` only sources
/// from the OpenAI record path, and the Anthropic record-and-serve arm that
/// would carry this label into a sink row is v13b-2 (not built). So a sink-row
/// test would re-exercise shipped openai-key plumbing as theatre. Instead we
/// prove the label is STORED and ROUND-TRIPS via the seam: write the key +
/// `--label`, read both back, assert both match.
@Suite("Anthropic key vault (V.13b-1)")
struct AnthropicKeyVaultTests {

    // MARK: - 1. piped key (trailing newline) is stored TRIMMED; key + label round-trip

    @Test("a piped key with a trailing newline is stored trimmed and round-trips with its label")
    func pipedKeyStoredTrimmedAndRoundTrips() async throws {
        let store = InMemoryKeychainStore()
        let vault = CredentialVault(store: store)

        // The classic `echo $KEY | …` case bakes in a trailing newline; the
        // provisioner must strip it so the stored secret is exactly the key.
        let rawWithNewline = "sk-ant-test-abc123\n"
        try await AnthropicKeyProvisioner.store(
            key: rawWithNewline,
            label: "work",
            vault: vault
        )

        let record = try await AnthropicKeyProvisioner.load(label: "work", vault: vault)
        #expect(record.key == "sk-ant-test-abc123")     // newline trimmed
        #expect(!record.key.contains("\n"))
        #expect(record.label == "work")                 // label round-trips
    }

    @Test("surrounding whitespace (CRLF / spaces) is also trimmed from the piped key")
    func surroundingWhitespaceTrimmed() async throws {
        let store = InMemoryKeychainStore()
        let vault = CredentialVault(store: store)
        try await AnthropicKeyProvisioner.store(
            key: "  sk-ant-test-xyz \r\n",
            label: "ci",
            vault: vault
        )
        let record = try await AnthropicKeyProvisioner.load(label: "ci", vault: vault)
        #expect(record.key == "sk-ant-test-xyz")
        #expect(record.label == "ci")
    }

    @Test("normalizeKey is pure and strips trailing newline + surrounding whitespace")
    func normalizeKeyPure() {
        #expect(AnthropicKeyProvisioner.normalizeKey("sk-ant-1\n") == "sk-ant-1")
        #expect(AnthropicKeyProvisioner.normalizeKey("  sk-ant-2  ") == "sk-ant-2")
        #expect(AnthropicKeyProvisioner.normalizeKey("sk-ant-3\r\n\n") == "sk-ant-3")
        #expect(AnthropicKeyProvisioner.normalizeKey("sk-ant-4") == "sk-ant-4")
    }

    @Test("re-provisioning the same label updates in place (add-vs-update via the seam)")
    func reprovisionSameLabelUpdates() async throws {
        let store = InMemoryKeychainStore()
        let vault = CredentialVault(store: store)
        try await AnthropicKeyProvisioner.store(key: "sk-ant-first", label: "work", vault: vault)
        try await AnthropicKeyProvisioner.store(key: "sk-ant-second", label: "work", vault: vault)

        let record = try await AnthropicKeyProvisioner.load(label: "work", vault: vault)
        #expect(record.key == "sk-ant-second")          // latest wins
        // One label → one item (no duplicate).
        let labels = try await vault.list(scope: AnthropicKeyProvisioner.vaultScope)
        #expect(labels == ["work"])
    }

    // MARK: - 2. --label REQUIRED for anthropic-key; no --key flag exists

    @Test("an empty/whitespace label is rejected at the provisioner seam")
    func emptyLabelRejectedAtSeam() async throws {
        let vault = CredentialVault(store: InMemoryKeychainStore())
        await #expect(throws: AnthropicKeyProvisioner.ProvisionError.missingLabel) {
            try await AnthropicKeyProvisioner.store(key: "sk-ant-x", label: "   ", vault: vault)
        }
    }

    @Test("an empty key (nothing piped in) is rejected at the provisioner seam")
    func emptyKeyRejectedAtSeam() async throws {
        let vault = CredentialVault(store: InMemoryKeychainStore())
        await #expect(throws: AnthropicKeyProvisioner.ProvisionError.emptyKey) {
            try await AnthropicKeyProvisioner.store(key: "\n  \n", label: "work", vault: vault)
        }
    }

    @Test("`vault add anthropic-key` with no --label throws ValidationError before any store/STDIN read")
    func missingLabelThrowsValidationError() async throws {
        // run() guards on --label FIRST, so this throws without reading STDIN
        // or constructing MacOSKeychainStore — safe to drive in CI.
        var cmd = try VaultAdd.parse(["anthropic-key"])
        await #expect(throws: ValidationError.self) {
            try await cmd.run()
        }
    }

    @Test("no --key flag exists on vault add (secrets come from STDIN, never a flag)")
    func noKeyFlagExists() {
        // Parsing a --key option must fail: the flag does not exist, so a
        // secret cannot land in shell history via `--key`.
        #expect(throws: (any Error).self) {
            _ = try VaultAdd.parse(["anthropic-key", "--label", "work", "--key", "sk-ant-secret"])
        }
        // And the rendered help never advertises a `--key` flag.
        let help = VaultAdd.helpMessage()
        #expect(!help.contains("--key"))
    }

    @Test("anthropic-key parses with --label and no required --preset")
    func anthropicKeyParsesWithoutPreset() throws {
        // openai-key needs --preset; anthropic-key must NOT require it.
        let cmd = try VaultAdd.parse(["anthropic-key", "--label", "work"])
        #expect(cmd.kind == "anthropic-key")
        #expect(cmd.label == "work")
        #expect(cmd.preset == nil)
    }

    // MARK: - openai-key not regressed: --label stays optional

    @Test("openai-key still parses with no --label (label stays optional on that path)")
    func openAIKeyLabelStillOptional() throws {
        let cmd = try VaultAdd.parse(["openai-key", "--preset", "auto"])
        #expect(cmd.kind == "openai-key")
        #expect(cmd.label == nil)
        #expect(cmd.preset == "auto")
    }
}
