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
        subcommands: [VaultAdd.self]
    )
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
