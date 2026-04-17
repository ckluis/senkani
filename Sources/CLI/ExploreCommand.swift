import ArgumentParser
import Foundation
import Indexer

struct Explore: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "explore",
        abstract: "Show the project's symbol tree."
    )

    @Argument(help: "Scope to a subdirectory (optional).")
    var path: String?

    @Option(name: .long, help: "Project root directory.")
    var root: String?

    func run() throws {
        let projectRoot = root ?? FileManager.default.currentDirectoryPath
        guard let index = IndexStore.load(projectRoot: projectRoot) else {
            print("No index found. Run `senkani index` first.")
            throw ExitCode.failure
        }

        let grouped = index.groupedByFile(under: path)
        guard !grouped.isEmpty else {
            if let p = path {
                print("No symbols found under \"\(p)\"")
            } else {
                print("Index is empty.")
            }
            return
        }

        let totalSymbols = grouped.reduce(0) { $0 + $1.symbols.count }
        print("")
        print("\(totalSymbols) symbols across \(grouped.count) files")
        if let p = path { print("(scoped to \(p))") }
        print("")

        for (file, symbols) in grouped {
            print("  \(file)")

            // Group by container for nicer display
            var topLevel: [IndexEntry] = []
            var contained: [String: [IndexEntry]] = [:]

            for sym in symbols {
                if let c = sym.container {
                    contained[c, default: []].append(sym)
                } else {
                    topLevel.append(sym)
                }
            }

            for sym in topLevel {
                let kindStr = String(describing: sym.kind)
                print("    \(kindStr) \(sym.name)")

                // Show contained members
                if let members = contained[sym.name] {
                    for member in members {
                        let mKind = String(describing: member.kind)
                        print("      \(mKind) \(member.name)")
                    }
                }
            }

            // Show orphaned contained symbols (container not in top-level)
            let topNames = Set(topLevel.map(\.name))
            for (container, members) in contained where !topNames.contains(container) {
                print("    [\(container)]")
                for member in members {
                    let mKind = String(describing: member.kind)
                    print("      \(mKind) \(member.name)")
                }
            }
        }
        print("")
    }
}
