import ArgumentParser
import Core
import Foundation

/// T.2c-2 — `senkani engagement <start|end|list>`. Operator-facing
/// lifecycle surface for `AnonymizationProxy` engagements. Each
/// engagement gets its own SurrogateVault under
/// `~/.senkani/surrogates/<name>.sqlite` (AES-GCM at rest via
/// `EngagementContextProvider`).
struct Engagement: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "engagement",
        abstract: "Manage AnonymizationProxy engagements (T.2c-2).",
        subcommands: [Start.self, End.self, List.self]
    )

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create or reopen an engagement vault."
        )

        @Argument(help: "Engagement name (used as the vault file basename).")
        var name: String

        func run() async throws {
            try EngagementCLISupport.validateName(name)
            let provider = EngagementContextProvider()
            let result = try await provider.makeContext(
                id: name,
                sensitivityThreshold: PaneMode.general.piiSensitivityThreshold
            )
            let context = result.0
            let keySource = result.1

            // If the vault file already existed AND it's already closed,
            // re-start is a warning (per acceptance: idempotent +
            // warning).
            let fm = FileManager.default
            let vaultExisted = fm.fileExists(atPath: context.vaultPath.path)
                && (try? fm.attributesOfItem(atPath: context.vaultPath.path)[.size] as? Int64) ?? 0 > 0

            let vault = try SurrogateVault(context: context, keySource: keySource)
            if vaultExisted {
                FileHandle.standardError.write(Data(
                    "engagement: '\(name)' already exists — no-op.\n".utf8
                ))
            } else {
                print("engagement: '\(name)' started (key_source=\(keySource.rawValue), vault=\(context.vaultPath.path))")
            }
            // Touch the vault to confirm it's writable; no rows yet.
            _ = try await vault.count()
        }
    }

    struct End: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Mark an engagement closed (disables rewrite-back)."
        )

        @Argument(help: "Engagement name.")
        var name: String

        func run() async throws {
            try EngagementCLISupport.validateName(name)
            let provider = EngagementContextProvider()
            let result = try await provider.makeContext(
                id: name,
                sensitivityThreshold: PaneMode.general.piiSensitivityThreshold
            )
            let context = result.0
            let keySource = result.1
            let vault = try SurrogateVault(context: context, keySource: keySource)
            let stamp = try await vault.markClosed()
            print("engagement: '\(name)' closed at \(stamp)")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List all engagement vaults."
        )

        func run() async throws {
            let root = EngagementContextProvider.defaultRoot
            let fm = FileManager.default
            guard fm.fileExists(atPath: root.path) else {
                print("name | status | vault_bytes | key_source")
                print("(no engagements)")
                return
            }
            let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let vaults = entries.filter { $0.pathExtension == "sqlite" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

            print("name | status | vault_bytes | key_source")
            if vaults.isEmpty {
                print("(no engagements)")
                return
            }
            let provider = EngagementContextProvider()
            for url in vaults {
                let name = url.deletingPathExtension().lastPathComponent
                let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                // Open the vault to read meta (status + key_source).
                // Read-only inspection — no allocations.
                var status = "error"
                var keySource = "?"
                do {
                    let result = try await provider.makeContext(
                        id: name,
                        sensitivityThreshold: PaneMode.general.piiSensitivityThreshold
                    )
                    let vault = try SurrogateVault(context: result.0, keySource: result.1)
                    let closed = try await vault.isClosed()
                    status = closed ? "closed" : "open"
                    keySource = (try await vault.getMeta("key_source")) ?? result.1.rawValue
                } catch {
                    // status/keySource stay at "error"/"?".
                }
                print("\(name) | \(status) | \(size) | \(keySource)")
            }
        }
    }
}

enum EngagementCLISupport {
    /// Names land on disk as the SQLite basename — reject path
    /// separators, NUL bytes, and traversals so a malicious name like
    /// `../foo` cannot escape the surrogates root.
    static func validateName(_ name: String) throws {
        guard !name.isEmpty else {
            throw ValidationError("engagement: name is required")
        }
        for ch in name {
            if ch == "/" || ch == "\\" || ch == "\0" {
                throw ValidationError("engagement: name must not contain path separators or NUL")
            }
        }
        if name == "." || name == ".." || name.hasPrefix(".") {
            throw ValidationError("engagement: name must not start with '.'")
        }
    }
}
