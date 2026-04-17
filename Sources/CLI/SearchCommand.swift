import ArgumentParser
import Foundation
import Indexer

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search the symbol index."
    )

    @Argument(help: "Symbol name to search for (substring match).")
    var query: String

    @Option(name: .long, help: "Filter by symbol kind (function, class, struct, enum, protocol, method).")
    var kind: String?

    @Option(name: .long, help: "Filter by file path (substring match).")
    var file: String?

    @Option(name: .long, help: "Filter by container/enclosing type (substring match).")
    var container: String?

    @Option(name: .long, help: "Project root directory.")
    var root: String?

    func run() throws {
        let projectRoot = root ?? FileManager.default.currentDirectoryPath
        guard let index = IndexStore.load(projectRoot: projectRoot) else {
            print("No index found. Run `senkani index` first.")
            throw ExitCode.failure
        }

        let symbolKind: SymbolKind? = kind.flatMap { SymbolKind(rawValue: $0) }

        let results = index.search(
            name: query,
            kind: symbolKind,
            file: file,
            container: container
        )

        guard !results.isEmpty else {
            print("No symbols matching \"\(query)\"")
            return
        }

        print("")
        print("Found \(results.count) symbol\(results.count == 1 ? "" : "s") matching \"\(query)\":")
        print("")

        for (i, entry) in results.prefix(30).enumerated() {
            let kindStr = String(describing: entry.kind).padding(toLength: 10, withPad: " ", startingAt: 0)
            let location = "\(entry.file):\(entry.startLine)"
            let containerStr = entry.container.map { " (\($0))" } ?? ""
            print("  \(i + 1). \(entry.name.padding(toLength: 24, withPad: " ", startingAt: 0))\(kindStr) \(location)\(containerStr)")
        }

        if results.count > 30 {
            print("  ... and \(results.count - 30) more")
        }

        print("")
        print("Use `senkani fetch <name>` to read a symbol's source.")
    }
}
