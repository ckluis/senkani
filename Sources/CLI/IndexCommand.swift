import ArgumentParser
import Foundation
import Indexer

struct Index: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build or refresh the symbol index for the current project."
    )

    @Flag(name: .long, help: "Force full re-index (ignore cached index).")
    var force = false

    @Option(name: .long, help: "Project root directory (defaults to current directory).")
    var root: String?

    func run() throws {
        let projectRoot = root ?? FileManager.default.currentDirectoryPath
        let start = Date()

        let index = IndexStore.buildOrUpdate(projectRoot: projectRoot, force: force)

        try IndexStore.save(index, projectRoot: projectRoot)

        let elapsed = Date().timeIntervalSince(start)
        let fileCount = Set(index.symbols.map(\.file)).count

        print("")
        print("Index built (\(String(format: "%.1f", elapsed))s)")
        print("  Engine:  \(index.engine)")
        print("  Symbols: \(index.symbols.count)")
        print("  Files:   \(fileCount)")
        print("  Stored:  .senkani/index.json")

        // Show language breakdown
        let byLang = Dictionary(grouping: index.symbols) { entry -> String in
            let ext = (entry.file as NSString).pathExtension
            return FileWalker.languageMap[ext] ?? ext
        }
        if !byLang.isEmpty {
            print("  Languages:")
            for (lang, symbols) in byLang.sorted(by: { $0.value.count > $1.value.count }) {
                print("    \(lang.padding(toLength: 14, withPad: " ", startingAt: 0))\(symbols.count) symbols")
            }
        }
        print("")
    }
}
