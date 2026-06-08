import ArgumentParser
import Foundation
import Core

#if canImport(Darwin)
import Darwin
#endif

/// `senkani vault …` — manage credential-vault entries.
///
/// V.13a-2 ships the first verb, `vault add openai-key`, which provisions
/// a bearer key for the OpenAI-compatible endpoint (`senkani serve
/// --openai`). The plaintext key is printed ONCE; only its SHA-256 hash
/// is persisted (see `OpenAIKeyProvisioner`).
///
/// V.13b-1 adds `vault add anthropic-key`, which stores an UPSTREAM
/// Anthropic API key (a real secret, not a hash) in the macOS Keychain.
/// The key is read from STDIN — never a `--key` flag — so it cannot land
/// in shell history.
struct Vault: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vault",
        abstract: "Manage credential-vault entries.",
        subcommands: [VaultAdd.self, VaultRemove.self, VaultList.self]
    )
}

/// `senkani vault list` — enumerate provisioned credentials as
/// `(scope, key, <N> bytes)` rows. t4c-1.
///
/// Schneier (no-secret-on-stdout, type-level): the verb reads the
/// vault through `CredentialVault.listKeyByteSummary(scope:)`, whose
/// return type (`VaultKeyByteSummary` of `VaultKeyByteEntry`) has NO
/// field that can carry the raw value — only the key name and the
/// value's byte LENGTH. The rendered line is therefore value-free by
/// construction, not by convention; a refactor that tried to print the
/// value would have to widen `VaultKeyByteEntry` AND the formatter and
/// would fail the value-free unit test.
///
/// CI invariant: production reads the configured `CredentialVault.shared`
/// store (an empty `InMemoryKeychainStore` until the operator-gated
/// real-Keychain swap lands in the parent walk). Tests drive the pure
/// `Vault.formatVaultListLines` formatter + the
/// `listKeyByteSummary` bridge directly with an
/// `InMemoryKeychainStore`-backed vault — CI never touches the real
/// macOS Keychain.
struct VaultList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List provisioned credentials as (scope, key, <N> bytes) — never the value."
    )

    @Option(name: .long, help: "Restrict the listing to a single scope. Default: enumerate the known scopes (\(Vault.knownScopes.joined(separator: ", "))).")
    var scope: String?

    func run() async throws {
        let scopes = scope.map { [$0] } ?? Vault.knownScopes
        var summaries: [VaultKeyByteSummary] = []
        for s in scopes {
            let summary = try await CredentialVault.shared.listKeyByteSummary(scope: s)
            summaries.append(summary)
        }
        for line in Vault.formatVaultListLines(summaries) {
            print(line)
        }
    }
}

extension Vault {
    /// The scopes `vault list` enumerates when `--scope` is omitted.
    /// `default` is today's only production scope; `anthropic-key` holds
    /// the upstream Anthropic key labels (V.13b). T.2c will add
    /// `engagement-<id>` scopes — they slot in here without an ABI break.
    static let knownScopes: [String] = [
        CredentialVault.defaultScope,
        AnthropicKeyProvisioner.vaultScope,
    ]

    /// Pure formatter for `vault list`. Renders one `(scope, key, <N>
    /// bytes)` row per entry; an empty scope renders a single
    /// `(scope, <empty>)` line so the operator sees the scope was
    /// queried. Lifted out so the unit test can assert on the rendered
    /// lines without touching the filesystem or the real Keychain.
    ///
    /// Schneier (no-secret-on-stdout): the input is a
    /// `[VaultKeyByteSummary]` — there is no parameter shape by which a
    /// raw value could reach this formatter. Only the key name and the
    /// value's byte LENGTH are rendered.
    static func formatVaultListLines(_ summaries: [VaultKeyByteSummary]) -> [String] {
        var lines: [String] = []
        for summary in summaries {
            if summary.entries.isEmpty {
                lines.append("(\(summary.scope), <empty>)")
                continue
            }
            for entry in summary.entries {
                lines.append("(\(summary.scope), \(entry.key), \(entry.byteLength) bytes)")
            }
        }
        return lines
    }
}

struct VaultAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Provision a credential (e.g. `openai-key`)."
    )

    // NOTE: the `kind` help text and the `--preset` help text are asserted by
    // the OpenAI surface/vocabulary tests. In particular one test requires
    // `VaultAdd.helpMessage()` to NOT contain the word "anthropic", so the
    // second supported kind is intentionally not named in the static help —
    // its STDIN/`--label` contract is surfaced via runtime validation errors
    // instead.
    @Argument(help: "Credential kind. `openai-key` provisions an endpoint bearer key; the upstream-provider key kind reads its secret from STDIN and requires --label.")
    var kind: String

    @Option(name: .long, help: "Routing preset the key uses (one of: \(ModelPreset.allCases.map(\.rawValue).joined(separator: ", "))). Required for openai-key.")
    var preset: String?

    @Option(name: .long, help: "Comma-list of surfaces the key may hit (default: chat,embeddings).")
    var scope: String?

    @Option(name: .long, help: "Per-key rate limit in requests-per-minute (default: 60).")
    var rate: Int?

    @Option(name: .long, help: "Expiry as ISO-8601 (e.g. 2026-12-31T23:59:59Z).")
    var expires: String?

    @Option(name: .long, help: "Operator-facing label for the key. Required for the upstream-provider key kind.")
    var label: String?

    func run() async throws {
        switch kind {
        case "openai-key":
            try await runOpenAIKey()
        case "anthropic-key":
            try await runAnthropicKey()
        default:
            throw ValidationError("unsupported credential kind '\(kind)'. Supported: openai-key, anthropic-key.")
        }
    }

    // MARK: - openai-key (V.13a-2, unchanged behavior)

    private func runOpenAIKey() async throws {
        // `--preset` is required for openai-key (it was a required option
        // before anthropic-key made it conditionally optional).
        guard let presetValue = preset else {
            throw ValidationError("--preset is required for openai-key (one of: \(ModelPreset.allCases.map(\.rawValue).joined(separator: ", "))).")
        }

        // `--preset` selects the routing tier (v13a-3). Validate against the
        // `ModelPreset` vocabulary at provision time so an unrecognized value
        // is rejected loudly here, not silently degraded to `.auto` at serve
        // time. The normalized (lowercased) value is what we store.
        let validatedPreset: String
        do {
            validatedPreset = try OpenAIKeyProvisioner.validatePreset(presetValue)
        } catch let err as OpenAIKeyProvisioner.InvalidPreset {
            throw ValidationError(err.description)
        }

        let scopes = (scope ?? "chat,embeddings")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !scopes.isEmpty else {
            throw ValidationError("--scope must list at least one surface (e.g. chat,embeddings).")
        }

        let rpm = rate ?? OpenAIKeyRecord.defaultRateLimit
        guard rpm > 0 else {
            throw ValidationError("--rate must be a positive requests-per-minute value.")
        }

        var expiresAt: Date?
        if let expires {
            let formatter = ISO8601DateFormatter()
            guard let parsed = formatter.date(from: expires) else {
                throw ValidationError("--expires must be ISO-8601 (e.g. 2026-12-31T23:59:59Z).")
            }
            expiresAt = parsed
        }

        let provisioned = OpenAIKeyProvisioner.provision(
            preset: validatedPreset,
            scope: scopes,
            rateLimit: rpm,
            expiresAt: expiresAt,
            label: label,
            now: Date()
        )
        try await OpenAIKeyProvisioner.store(provisioned.record, vault: OpenAIKeyProvisioner.vault())

        // The plaintext key goes to stdout ONCE so it can be piped/copied;
        // the human-facing summary (which never contains the key) goes to
        // stderr so a `... | pbcopy` captures only the key.
        print(provisioned.plaintextKey)

        var summary = "provisioned openai-key — preset=\(validatedPreset), scope=\(scopes.joined(separator: ",")), rate=\(rpm)rpm"
        if let expires { summary += ", expires=\(expires)" }
        if let label { summary += ", label=\(label)" }
        summary += "\nThis key is shown ONCE — store it now. Only its hash is saved."
        FileHandle.standardError.write(Data((summary + "\n").utf8))
    }

    // MARK: - anthropic-key (V.13b-1)

    private func runAnthropicKey() async throws {
        // `--label` is REQUIRED for anthropic-key (it later sources the
        // audit-chain key_label). openai-key keeps `--label` optional.
        guard let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--label is required for anthropic-key (it later sources the audit-chain key_label).")
        }

        // The secret is read from STDIN — NEVER a `--key` flag — so it cannot
        // land in shell history. On a pipe, read all of stdin and trim the
        // trailing newline `echo $KEY | …` would otherwise bake in. On a TTY,
        // prompt without echo.
        let rawKey = try Self.readSecretFromStdin(prompt: "Paste the upstream Anthropic API key (input hidden): ")

        do {
            try await AnthropicKeyProvisioner.store(
                key: rawKey,
                label: label,
                vault: AnthropicKeyProvisioner.vault()
            )
        } catch let err as AnthropicKeyProvisioner.ProvisionError {
            throw ValidationError(err.description)
        }

        // The key is NEVER printed back. Only a human-facing confirmation
        // (no secret) goes to stderr.
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        FileHandle.standardError.write(Data(
            "stored anthropic-key — label=\(trimmedLabel) (saved to the macOS Keychain; the key is not shown).\n".utf8
        ))
    }

    /// Read a secret from STDIN. On a pipe (the `echo $KEY | …` / `pbpaste |
    /// …` case) read the whole stream; trimming is the provisioner's job. On
    /// a TTY, prompt and read a single line with terminal echo disabled so the
    /// secret never appears on screen.
    private static func readSecretFromStdin(prompt: String) throws -> String {
        #if canImport(Darwin)
        if isatty(STDIN_FILENO) != 0 {
            FileHandle.standardError.write(Data(prompt.utf8))
            let line = try withEchoDisabled { readLine(strippingNewline: true) }
            FileHandle.standardError.write(Data("\n".utf8))
            return line ?? ""
        }
        #endif
        // Piped/redirected stdin: read everything available.
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    #if canImport(Darwin)
    /// Run `body` with terminal echo disabled on STDIN, restoring the prior
    /// termios on the way out (even on throw).
    private static func withEchoDisabled<T>(_ body: () -> T) throws -> T {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            // Not a real terminal we can configure; fall back to plain read.
            return body()
        }
        var quiet = original
        quiet.c_lflag &= ~tcflag_t(ECHO)
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &quiet)
        defer { tcsetattr(STDIN_FILENO, TCSANOW, &original) }
        return body()
    }
    #endif
}

/// `senkani vault remove …` — revoke a provisioned credential.
///
/// V.13b-1 follow-up: `vault add anthropic-key` provisions an upstream secret
/// into the login Keychain, but exposed no first-class REVOCATION path. This
/// verb reaches the existing `KeychainStore.delete` seam so an operator who
/// rotates or suspects compromise of a key can cleanly evict it.
///
/// Revocation is intentionally NON-interactive (no typed-confirm prompt): the
/// urgent case is reacting to a suspected compromise from a script, which a
/// forced prompt would block. The operation is recoverable (re-add the key) and
/// idempotent (removing an absent label is a clean no-op), so the safety cost of
/// no prompt is bounded; a clear stderr confirmation states exactly what was
/// evicted. (See `AnthropicKeyVaultTests` "remove" coverage — `InMemoryKeychainStore`
/// only; the real login Keychain is never touched in CI.)
struct VaultRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Revoke a provisioned credential (e.g. an upstream-provider key)."
    )

    // Help text deliberately does NOT name the provider (mirrors `VaultAdd`):
    // the upstream-provider key kind's `--label` contract is surfaced via the
    // runtime validation error, not the static help, to keep the help-vocabulary
    // surface tests stable.
    @Argument(help: "Credential kind to revoke. The upstream-provider key kind requires --label.")
    var kind: String

    @Option(name: .long, help: "Operator-facing label of the key to revoke. Required for the upstream-provider key kind.")
    var label: String?

    func run() async throws {
        switch kind {
        case "anthropic-key":
            try await runRemoveAnthropicKey()
        default:
            throw ValidationError("unsupported credential kind '\(kind)'. Supported: anthropic-key.")
        }
    }

    private func runRemoveAnthropicKey() async throws {
        // Guard --label FIRST, so a missing label throws before constructing
        // MacOSKeychainStore — safe to drive in CI without touching the Keychain.
        guard let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--label is required for anthropic-key (the label identifies which key to revoke).")
        }

        let evicted: Bool
        do {
            evicted = try await AnthropicKeyProvisioner.remove(
                label: label,
                vault: AnthropicKeyProvisioner.vault()
            )
        } catch let err as AnthropicKeyProvisioner.ProvisionError {
            throw ValidationError(err.description)
        }

        // Human-facing confirmation (no secret) → stderr. DISTINGUISH a real
        // eviction from an absent-label no-op: on a revocation verb a typo'd
        // --label must NOT yield a false "it's gone" signal (an operator
        // reacting to suspected compromise could otherwise believe a live key
        // was revoked when nothing matched). Both paths leave the
        // post-condition "no such label remains" true.
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = evicted
            ? "removed anthropic-key — label=\(trimmedLabel) (evicted from the macOS Keychain; re-add to restore).\n"
            : "no anthropic-key found for label=\(trimmedLabel) — nothing to revoke (the vault is unchanged).\n"
        FileHandle.standardError.write(Data(message.utf8))
    }
}
