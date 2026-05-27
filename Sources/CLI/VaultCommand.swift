import ArgumentParser
import Foundation
import Core

/// `senkani vault …` — manage credential-vault entries.
///
/// V.13a-2 ships the first verb, `vault add openai-key`, which provisions
/// a bearer key for the OpenAI-compatible endpoint (`senkani serve
/// --openai`). The plaintext key is printed ONCE; only its SHA-256 hash
/// is persisted (see `OpenAIKeyProvisioner`).
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
        abstract: "Provision a credential. Currently supports `openai-key`."
    )

    @Argument(help: "Credential kind. Only `openai-key` is supported today.")
    var kind: String

    @Option(name: .long, help: "Routing preset the key uses (one of: \(ModelPreset.allCases.map(\.rawValue).joined(separator: ", "))).")
    var preset: String

    @Option(name: .long, help: "Comma-list of surfaces the key may hit (default: chat,embeddings).")
    var scope: String?

    @Option(name: .long, help: "Per-key rate limit in requests-per-minute (default: 60).")
    var rate: Int?

    @Option(name: .long, help: "Expiry as ISO-8601 (e.g. 2026-12-31T23:59:59Z).")
    var expires: String?

    @Option(name: .long, help: "Operator-facing label for the key.")
    var label: String?

    func run() async throws {
        guard kind == "openai-key" else {
            throw ValidationError("unsupported credential kind '\(kind)'. Supported: openai-key.")
        }

        // `--preset` selects the routing tier (v13a-3). Validate against the
        // `ModelPreset` vocabulary at provision time so an unrecognized value
        // is rejected loudly here, not silently degraded to `.auto` at serve
        // time. The normalized (lowercased) value is what we store.
        let validatedPreset: String
        do {
            validatedPreset = try OpenAIKeyProvisioner.validatePreset(preset)
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
}
