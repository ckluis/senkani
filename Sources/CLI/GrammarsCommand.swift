import ArgumentParser
import Foundation
import Indexer

struct Grammars: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "grammars",
        abstract: "Manage vendored tree-sitter grammars.",
        subcommands: [List.self, Check.self],
        defaultSubcommand: List.self
    )

    // MARK: - list

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List all vendored tree-sitter grammars."
        )

        func run() throws {
            let grammars = GrammarManifest.sorted

            print("Vendored Grammars")
            print("=================")
            print("")

            for info in grammars {
                print("  \(info.language)")
                print("    version:  \(info.version)")
                print("    repo:     https://github.com/\(info.repo)")
                print("    vendored: \(info.vendoredDate)")
                print("    target:   \(info.targetName)")
                print("")
            }

            print("\(grammars.count) grammar(s) vendored")
        }
    }

    // MARK: - check

    struct Check: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "check",
            abstract: "Check for newer grammar versions on GitHub."
        )

        @Flag(name: .long, help: "Ignore cache and re-check all grammars.")
        var refresh = false

        func run() throws {
            print("Checking grammar versions...")
            print("")

            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var results: [GrammarCheckResult] = []
            Task {
                results = await GrammarVersionChecker.checkAll(forceRefresh: refresh)
                semaphore.signal()
            }
            semaphore.wait()

            var outdatedCount = 0
            for result in results {
                let status: String
                if let error = result.error {
                    status = "? \(result.grammar.language) v\(result.grammar.version) — \(error)"
                } else if result.isOutdated {
                    status = "! \(result.grammar.language) v\(result.grammar.version) -> v\(result.latestVersion ?? "?")"
                    outdatedCount += 1
                } else {
                    status = "\u{2713} \(result.grammar.language) v\(result.grammar.version) (up to date)"
                }
                print("  \(status)")
            }

            print("")
            if outdatedCount > 0 {
                print("\(outdatedCount) grammar(s) have newer versions available.")
                print("To update, re-vendor the grammar and update GrammarManifest.")
            } else {
                print("All grammars are up to date.")
            }
        }
    }
}
