import Testing
import Foundation
@testable import Indexer

@Suite("SymbolIndex — Repo Map Generation")
struct RepoMapTests {

    private func makeIndex(projectRoot: String = "/tmp/test-project", symbols: [IndexEntry]) -> SymbolIndex {
        var idx = SymbolIndex()
        idx.projectRoot = projectRoot
        idx.symbols = symbols
        return idx
    }

    @Test func repoMapContainsFileAndSymbolNames() {
        let idx = makeIndex(symbols: [
            IndexEntry(name: "Foo", kind: .struct, file: "Sources/Models/Foo.swift", startLine: 1, endLine: 20),
            IndexEntry(name: "bar", kind: .method, file: "Sources/Models/Foo.swift", startLine: 5, container: "Foo"),
            IndexEntry(name: "Helper", kind: .class, file: "Sources/Utils/Helper.swift", startLine: 1, endLine: 30),
        ])

        let map = idx.repoMap(maxTokens: 2000)

        #expect(!map.isEmpty, "Repo map should not be empty")
        #expect(map.contains("Foo.swift"), "Map should contain file name")
        #expect(map.contains("Foo"), "Map should contain struct name")
        #expect(map.contains("bar"), "Map should contain method name")
        #expect(map.contains("Helper"), "Map should contain class name")
    }

    @Test func repoMapRespectsTokenCap() {
        // Create a large index that will exceed a tight cap
        var symbols: [IndexEntry] = []
        for i in 0..<100 {
            symbols.append(IndexEntry(
                name: "Function\(i)",
                kind: .function,
                file: "Sources/File\(i).swift",
                startLine: 1,
                endLine: 50
            ))
        }

        let idx = makeIndex(symbols: symbols)
        let map = idx.repoMap(maxTokens: 100)

        #expect(map.count < 500, "Map should be under ~500 chars for 100 token cap, got \(map.count)")
        #expect(map.contains("more files"), "Truncated map should contain 'more files' message")
    }

    @Test func repoMapEmptyForEmptyIndex() {
        let idx = makeIndex(symbols: [])
        let map = idx.repoMap()
        #expect(map.isEmpty, "Empty index should produce empty map")
    }

    @Test func repoMapGroupsByFile() {
        let idx = makeIndex(symbols: [
            IndexEntry(name: "Alpha", kind: .struct, file: "Alpha.swift", startLine: 1),
            IndexEntry(name: "Beta", kind: .struct, file: "Beta.swift", startLine: 1),
            IndexEntry(name: "Gamma", kind: .struct, file: "Gamma.swift", startLine: 1),
        ])

        let map = idx.repoMap()

        #expect(map.contains("Alpha.swift"), "Map should contain Alpha.swift")
        #expect(map.contains("Beta.swift"), "Map should contain Beta.swift")
        #expect(map.contains("Gamma.swift"), "Map should contain Gamma.swift")
        #expect(map.contains("3 files"), "Header should show 3 files")
    }

    @Test func repoMapShowsContainerHierarchy() {
        let idx = makeIndex(symbols: [
            IndexEntry(name: "MyClass", kind: .class, file: "MyClass.swift", startLine: 1, endLine: 50),
            IndexEntry(name: "init", kind: .method, file: "MyClass.swift", startLine: 3, container: "MyClass"),
            IndexEntry(name: "doWork", kind: .method, file: "MyClass.swift", startLine: 10, container: "MyClass"),
        ])

        let map = idx.repoMap()

        #expect(map.contains("MyClass"), "Map should contain class name")
        #expect(map.contains("init"), "Map should contain method name")
        #expect(map.contains("doWork"), "Map should contain method name")

        // Verify indentation — methods should be more indented than the class
        let lines = map.components(separatedBy: "\n")
        let classLine = lines.first { $0.contains("class MyClass") }
        let methodLine = lines.first { $0.contains("method init") || $0.contains("method doWork") }
        #expect(classLine != nil, "Should have a class line")
        #expect(methodLine != nil, "Should have a method line")
        if let cl = classLine, let ml = methodLine {
            let classIndent = cl.prefix(while: { $0 == " " }).count
            let methodIndent = ml.prefix(while: { $0 == " " }).count
            #expect(methodIndent > classIndent, "Methods should be indented deeper than class")
        }
    }

    @Test func repoMapShowsLineNumbers() {
        let idx = makeIndex(symbols: [
            IndexEntry(name: "process", kind: .function, file: "Main.swift", startLine: 42),
        ])

        let map = idx.repoMap()

        #expect(map.contains("L42"), "Map should contain line number L42")
    }
}
