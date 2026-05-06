import ArgumentParser
import Core
import Foundation

/// `senkani models` — operator-facing model registry surface.
///
/// Three subcommands:
///   - `list`    — print every registered model with status + on-disk size.
///   - `pull`    — download weights for a specific model and run verification.
///   - `verify`  — re-run the post-install verification fixture.
///
/// All three drive `ModelManager.shared`. `pull` and `verify` route to a
/// senkani-id-aware switch that, in T.2a, only knows `pii-classifier-int8`
/// (delegates to `PIIClassifierAdapter`). The MLX-driven gemma / embedding
/// IDs continue to flow through the SwiftUI app + MCP layer; the CLI emits
/// a clear "use the app or MCP" message for those.
struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "Manage Senkani's local ML model registry.",
        subcommands: [List.self, Pull.self, Verify.self],
        defaultSubcommand: List.self
    )

    // MARK: - list

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List all registered models with status and on-disk size."
        )

        @Flag(name: .long, help: "Output as machine-readable JSON.")
        var json = false

        func run() throws {
            let mgr = ModelManager.shared
            let models = mgr.models
            // Stable order (alphabetical by id) so scripted callers and
            // snapshot tests get deterministic output.
            let sorted = models.sorted { $0.id < $1.id }

            if json {
                let rows = sorted.map { info -> [String: Any] in
                    [
                        "id": info.id,
                        "name": info.name,
                        "repoId": info.repoId,
                        "status": info.status.rawValue,
                        "onDiskBytes": mgr.diskUsage(for: info.id),
                        "expectedSizeBytes": info.expectedSizeBytes,
                    ]
                }
                let data = try JSONSerialization.data(
                    withJSONObject: rows,
                    options: [.prettyPrinted, .sortedKeys]
                )
                print(String(decoding: data, as: UTF8.self))
                return
            }

            print("Registered models")
            print("=================")
            print("")
            for info in sorted {
                let onDisk = mgr.diskUsage(for: info.id)
                let onDiskStr = onDisk > 0
                    ? ModelManager.formatBytes(onDisk)
                    : "(not downloaded)"
                print("  \(info.id)")
                print("    name:    \(info.name)")
                print("    repo:    \(info.repoId)")
                print("    status:  \(info.status.rawValue)")
                print("    size:    \(onDiskStr)")
                if let err = info.lastError, !err.isEmpty {
                    print("    error:   \(err)")
                }
                print("")
            }
            print("\(sorted.count) model(s) registered")
        }
    }

    // MARK: - pull

    struct Pull: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pull",
            abstract: "Download a specific model and run its verification fixture."
        )

        @Argument(help: "Senkani model id (e.g. pii-classifier-int8).")
        var modelId: String

        func run() async throws {
            try await Models.installCLIHandlers()
            let mgr = ModelManager.shared
            guard let info = mgr.model(modelId) else {
                throw ValidationError("Unknown model id: \(modelId). Run `senkani models list` to see registered ids.")
            }
            print("Pulling \(info.name) (\(info.repoId))...")
            do {
                try await mgr.download(modelId: modelId)
            } catch {
                // download(modelId:) already records lastError; surface a
                // human-readable hint instead of duplicating the message.
                let after = mgr.model(modelId)
                let status = after?.status.rawValue ?? "unknown"
                let detail = after?.lastError ?? error.localizedDescription
                fputs("senkani: pull failed (\(status)): \(detail)\n", stderr)
                throw ExitCode.failure
            }
            let after = mgr.model(modelId)
            let status = after?.status.rawValue ?? "unknown"
            print("Pull complete — status: \(status)")
        }
    }

    // MARK: - verify

    struct Verify: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "verify",
            abstract: "Re-run the post-install verification fixture for a model."
        )

        @Argument(help: "Senkani model id (e.g. pii-classifier-int8).")
        var modelId: String

        func run() async throws {
            try await Models.installCLIHandlers()
            let mgr = ModelManager.shared
            guard mgr.model(modelId) != nil else {
                throw ValidationError("Unknown model id: \(modelId). Run `senkani models list` to see registered ids.")
            }
            do {
                try await mgr.verify(modelId: modelId)
            } catch {
                let after = mgr.model(modelId)
                let status = after?.status.rawValue ?? "unknown"
                let detail = after?.lastError ?? error.localizedDescription
                fputs("senkani: verify failed (\(status)): \(detail)\n", stderr)
                throw ExitCode.failure
            }
            let after = mgr.model(modelId)
            let status = after?.status.rawValue ?? "unknown"
            print("Verified — status: \(status)")
        }
    }

    // MARK: - CLI handler installation

    /// Install download + verification handlers tailored to the CLI process.
    /// Idempotent — registering the same closure twice is a no-op aside
    /// from replacing the previous closure.
    ///
    /// Routing:
    ///   - `pii-classifier-int8` → `PIIClassifierAdapter.shared`. T.2a
    ///     ships an explicit `BackendNotReadyError` from both
    ///     `ensureModel()` and `runVerificationFixture()`; the adapter
    ///     wires real HF download + MLX inference in T.2b.
    ///   - any other id → throws "this model installs via the SenkaniApp
    ///     or MCP server" so operators don't think the CLI is broken.
    static func installCLIHandlers() async throws {
        let mgr = ModelManager.shared
        mgr.registerDownloadHandler { modelId in
            switch modelId {
            case PIIClassifierAdapter.modelId:
                try await PIIClassifierAdapter.shared.ensureModel()
            default:
                throw NSError(
                    domain: "dev.senkani.CLI.Models",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "\(modelId) installs via SenkaniApp or the MCP server (CLI download not wired). Use the app's Models pane, or run senkani-mcp."
                    ]
                )
            }
        }
        mgr.registerVerificationHandler { modelId in
            switch modelId {
            case PIIClassifierAdapter.modelId:
                try await PIIClassifierAdapter.shared.runVerificationFixture()
            default:
                // For non-PII models the integrity-only default is fine —
                // re-throw a sentinel so verify(modelId:) skips us and
                // falls back to the default. ModelManager.verify catches
                // and only marks .broken when a registered handler
                // throws, so the cleanest signal is "verification handler
                // not applicable for this id" via NSError.
                throw NSError(
                    domain: "dev.senkani.CLI.Models",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "\(modelId) verifies via SenkaniApp or the MCP server (CLI verify not wired). Use the app's Models pane, or run senkani-mcp."
                    ]
                )
            }
        }
    }
}
