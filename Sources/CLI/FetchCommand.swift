import ArgumentParser
import Foundation
import Indexer

struct Fetch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fetch",
        abstract: "Fetch a symbol's source code (reads only the relevant lines)."
    )

    @Argument(help: "Symbol name to fetch.")
    var name: String

    @Option(name: .long, help: "Project root directory.")
    var root: String?

    func run() throws {
        let projectRoot = root ?? FileManager.default.currentDirectoryPath
        guard let index = IndexStore.load(projectRoot: projectRoot) else {
            print("No index found. Run `senkani index` first.")
            throw ExitCode.failure
        }

        guard let entry = index.find(name: name) else {
            // Try fuzzy search
            let candidates = index.search(name: name).prefix(5)
            if candidates.isEmpty {
                print("Symbol \"\(name)\" not found in index.")
            } else {
                print("Symbol \"\(name)\" not found. Did you mean:")
                for c in candidates {
                    print("  - \(c.name) (\(c.kind)) at \(c.file):\(c.startLine)")
                }
            }
            throw ExitCode.failure
        }

        let fullPath = projectRoot + "/" + entry.file
        guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else {
            print("Could not read \(entry.file)")
            throw ExitCode.failure
        }

        let lines = content.components(separatedBy: "\n")
        let start = max(0, entry.startLine - 1)  // 0-based
        let end = min(lines.count, (entry.endLine ?? (entry.startLine + 19)))  // default 20 lines
        let slice = lines[start..<end]

        // Print header
        let wholFileBytes = content.utf8.count
        let sliceText = slice.joined(separator: "\n")
        let sliceBytes = sliceText.utf8.count

        print("// \(entry.name) (\(entry.kind)) — \(entry.file):\(entry.startLine)-\(end)")
        if let sig = entry.signature {
            print("// \(sig)")
        }
        print("// \(sliceBytes) bytes fetched (whole file: \(wholFileBytes) bytes, \(String(format: "%.0f", Double(wholFileBytes - sliceBytes) / Double(max(1, wholFileBytes)) * 100))% saved)")
        print("")

        // Print with line numbers
        for (i, line) in slice.enumerated() {
            let lineNum = start + i + 1
            print("\(String(lineNum).padding(toLength: 5, withPad: " ", startingAt: 0))│ \(line)")
        }
    }
}
