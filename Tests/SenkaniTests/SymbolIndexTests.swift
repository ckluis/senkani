import Testing
import Foundation
@testable import Indexer

@Suite("SymbolIndex")
struct SymbolIndexTests {
    @Test func searchByName() {
        var index = SymbolIndex()
        index.symbols = [
            IndexEntry(name: "FilterEngine", kind: .class, file: "Filter.swift", startLine: 1),
            IndexEntry(name: "filterOutput", kind: .function, file: "Filter.swift", startLine: 10),
            IndexEntry(name: "SecretDetector", kind: .enum, file: "Secret.swift", startLine: 1),
        ]

        let results = index.search(name: "filter")
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.name.lowercased().contains("filter") })
    }

    @Test func searchByKind() {
        var index = SymbolIndex()
        index.symbols = [
            IndexEntry(name: "Foo", kind: .class, file: "a.swift", startLine: 1),
            IndexEntry(name: "bar", kind: .function, file: "a.swift", startLine: 10),
            IndexEntry(name: "Baz", kind: .class, file: "b.swift", startLine: 1),
        ]

        let results = index.search(kind: .class)
        #expect(results.count == 2)
    }

    @Test func searchByFile() {
        var index = SymbolIndex()
        index.symbols = [
            IndexEntry(name: "A", kind: .function, file: "Sources/Core/a.swift", startLine: 1),
            IndexEntry(name: "B", kind: .function, file: "Sources/CLI/b.swift", startLine: 1),
        ]

        let results = index.search(file: "Core")
        #expect(results.count == 1)
        #expect(results.first?.name == "A")
    }

    @Test func findExact() {
        var index = SymbolIndex()
        index.symbols = [
            IndexEntry(name: "FilterEngine", kind: .class, file: "a.swift", startLine: 1),
            IndexEntry(name: "filterSomething", kind: .function, file: "a.swift", startLine: 10),
        ]

        let found = index.find(name: "FilterEngine")
        #expect(found?.name == "FilterEngine")
    }

    @Test func findCaseInsensitive() {
        var index = SymbolIndex()
        index.symbols = [
            IndexEntry(name: "FilterEngine", kind: .class, file: "a.swift", startLine: 1),
        ]

        let found = index.find(name: "filterengine")
        #expect(found?.name == "FilterEngine")
    }

    @Test func removeAndAddSymbols() {
        var index = SymbolIndex()
        index.symbols = [
            IndexEntry(name: "A", kind: .function, file: "a.swift", startLine: 1),
            IndexEntry(name: "B", kind: .function, file: "b.swift", startLine: 1),
        ]
        index.fileHashes = ["a.swift": "abc", "b.swift": "def"]

        index.removeSymbols(forFiles: Set(["a.swift"]))
        #expect(index.symbols.count == 1)
        #expect(index.symbols.first?.name == "B")
        #expect(index.fileHashes["a.swift"] == nil)

        index.addSymbols(
            [IndexEntry(name: "A2", kind: .function, file: "a.swift", startLine: 1)],
            hashes: ["a.swift": "xyz"]
        )
        #expect(index.symbols.count == 2)
        #expect(index.fileHashes["a.swift"] == "xyz")
    }

    @Test func groupedByFile() {
        var index = SymbolIndex()
        index.symbols = [
            IndexEntry(name: "A", kind: .function, file: "src/a.swift", startLine: 10),
            IndexEntry(name: "B", kind: .function, file: "src/a.swift", startLine: 1),
            IndexEntry(name: "C", kind: .function, file: "src/b.swift", startLine: 1),
        ]

        let grouped = index.groupedByFile()
        #expect(grouped.count == 2)
        #expect(grouped.first?.file == "src/a.swift")
        #expect(grouped.first?.symbols.first?.name == "B") // sorted by startLine
    }

    @Test func jsonRoundTrip() throws {
        var index = SymbolIndex()
        index.symbols = [
            IndexEntry(name: "test", kind: .function, file: "t.swift", startLine: 1,
                       endLine: 10, signature: "func test()", container: "MyClass", engine: "regex"),
        ]
        index.fileHashes = ["t.swift": "abc123"]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(index)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SymbolIndex.self, from: data)

        #expect(decoded.symbols.count == 1)
        #expect(decoded.symbols.first?.name == "test")
        #expect(decoded.symbols.first?.container == "MyClass")
        #expect(decoded.fileHashes["t.swift"] == "abc123")
    }
}
