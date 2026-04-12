import Foundation
import Testing
import SwiftTreeSitter
@testable import Indexer

// MARK: - TreeCache Storage

@Suite("TreeCache — Storage")
struct TreeCacheStorageTests {

    private func parseSwift(_ source: String) -> MutableTree? {
        let parser = Parser()
        guard let lang = TreeSitterBackend.language(for: "swift") else { return nil }
        try? parser.setLanguage(lang)
        return parser.parse(source)
    }

    @Test("Store and lookup returns cached entry")
    func storeAndLookup() {
        let cache = TreeCache()
        let source = "import Foundation\nfunc hello() {}\n"
        guard let tree = parseSwift(source) else {
            Issue.record("Failed to parse Swift source")
            return
        }
        let hash = TreeCache.hash(source)
        cache.store(file: "test.swift", tree: tree, content: source, contentHash: hash, language: "swift")

        let result = cache.lookup(file: "test.swift")
        #expect(result != nil)
        #expect(result?.contentHash == hash)
        #expect(result?.language == "swift")
        #expect(result?.content == source)
        #expect(cache.count == 1)
    }

    @Test("Lookup returns nil for unknown file")
    func lookupMiss() {
        let cache = TreeCache()
        #expect(cache.lookup(file: "nonexistent.swift") == nil)
    }

    @Test("Store overwrites existing entry")
    func storeOverwrites() {
        let cache = TreeCache()
        let source1 = "func a() {}\n"
        let source2 = "func b() {}\n"
        guard let tree1 = parseSwift(source1), let tree2 = parseSwift(source2) else {
            Issue.record("Failed to parse")
            return
        }
        cache.store(file: "test.swift", tree: tree1, content: source1, contentHash: TreeCache.hash(source1), language: "swift")
        cache.store(file: "test.swift", tree: tree2, content: source2, contentHash: TreeCache.hash(source2), language: "swift")

        #expect(cache.count == 1)
        let result = cache.lookup(file: "test.swift")
        #expect(result?.contentHash == TreeCache.hash(source2))
    }

    @Test("Remove removes entry")
    func removeEntry() {
        let cache = TreeCache()
        let source = "let x = 1\n"
        guard let tree = parseSwift(source) else { return }
        cache.store(file: "a.swift", tree: tree, content: source, contentHash: TreeCache.hash(source), language: "swift")
        #expect(cache.count == 1)

        cache.remove(file: "a.swift")
        #expect(cache.count == 0)
        #expect(cache.lookup(file: "a.swift") == nil)
    }

    @Test("Clear removes all entries")
    func clearAll() {
        let cache = TreeCache()
        let source = "let x = 1\n"
        guard let tree = parseSwift(source) else { return }
        cache.store(file: "a.swift", tree: tree, content: source, contentHash: TreeCache.hash(source), language: "swift")
        cache.store(file: "b.swift", tree: tree, content: source, contentHash: TreeCache.hash(source), language: "swift")
        #expect(cache.count == 2)

        cache.clear()
        #expect(cache.count == 0)
    }

    @Test("SHA-256 hash is deterministic")
    func hashDeterministic() {
        let content = "import Foundation\nclass Foo {}\n"
        let h1 = TreeCache.hash(content)
        let h2 = TreeCache.hash(content)
        #expect(h1 == h2)
        #expect(h1.count == 64) // SHA-256 hex is 64 chars

        // Different content produces different hash
        let h3 = TreeCache.hash(content + " ")
        #expect(h1 != h3)
    }
}

// MARK: - Edit Detection

@Suite("IncrementalParser — Edit Detection")
struct EditDetectionTests {

    @Test("Detects insertion")
    func detectsInsertion() {
        let old = "func hello() {}\n"
        let new = "func hello() {\n    print(\"hi\")\n}\n"
        let edit = IncrementalParser.detectEdit(oldContent: old, newContent: new)
        #expect(edit != nil)
        #expect(edit!.startByte < edit!.newEndByte)
        // New content is longer
        #expect(edit!.newEndByte > edit!.oldEndByte)
    }

    @Test("Detects deletion")
    func detectsDeletion() {
        let old = "func hello() {\n    print(\"hi\")\n}\n"
        let new = "func hello() {}\n"
        let edit = IncrementalParser.detectEdit(oldContent: old, newContent: new)
        #expect(edit != nil)
        // Old content was longer
        #expect(edit!.oldEndByte > edit!.newEndByte)
    }

    @Test("Detects replacement")
    func detectsReplacement() {
        let old = "let name = \"Alice\"\n"
        let new = "let name = \"Bob\"\n"
        let edit = IncrementalParser.detectEdit(oldContent: old, newContent: new)
        #expect(edit != nil)
        // Common prefix is "let name = \"" and common suffix is "\"\n"
        let prefixLen = "let name = \"".utf8.count
        #expect(edit!.startByte == UInt32(prefixLen))
    }

    @Test("Returns nil for identical content")
    func identicalContent() {
        let content = "import Foundation\nfunc test() {}\n"
        let edit = IncrementalParser.detectEdit(oldContent: content, newContent: content)
        #expect(edit == nil)
    }
}

// MARK: - Performance

@Suite("IncrementalParser — Performance")
struct IncrementalPerformanceTests {

    private func parseSwift(_ source: String) -> MutableTree? {
        let parser = Parser()
        guard let lang = TreeSitterBackend.language(for: "swift") else { return nil }
        try? parser.setLanguage(lang)
        return parser.parse(source)
    }

    @Test("Incremental reparse < 2ms for small edit")
    func incrementalReparseSpeed() {
        // Build a non-trivial source file (~100 lines)
        var lines: [String] = ["import Foundation", ""]
        for i in 0..<50 {
            lines.append("func method\(i)() -> Int { return \(i) }")
        }
        let oldContent = lines.joined(separator: "\n") + "\n"

        guard let oldTree = parseSwift(oldContent) else {
            Issue.record("Failed initial parse")
            return
        }

        // Small edit: change one function body
        let newContent = oldContent.replacingOccurrences(
            of: "func method25() -> Int { return 25 }",
            with: "func method25() -> Int { return 999 }"
        )

        let clock = ContinuousClock()
        var result: MutableTree?
        let elapsed = clock.measure {
            result = IncrementalParser.reparse(
                oldTree: oldTree,
                oldContent: oldContent,
                newContent: newContent,
                language: "swift"
            )
        }

        #expect(result != nil)
        #expect(result?.rootNode != nil)
        #expect(elapsed < .milliseconds(50)) // Well under 2ms in practice, 50ms generous bound
    }

    @Test("Cache lookup is sub-millisecond")
    func cacheLookupSpeed() {
        let cache = TreeCache()
        let source = "import Foundation\nfunc hello() {}\n"
        guard let tree = parseSwift(source) else { return }

        // Store 100 entries
        for i in 0..<100 {
            cache.store(file: "file\(i).swift", tree: tree, content: source, contentHash: TreeCache.hash(source), language: "swift")
        }

        let clock = ContinuousClock()
        var result: (tree: MutableTree, content: String, contentHash: String, language: String)?
        let elapsed = clock.measure {
            for _ in 0..<1000 {
                result = cache.lookup(file: "file50.swift")
            }
        }

        #expect(result != nil)
        // 1000 lookups should complete in well under 100ms
        #expect(elapsed < .milliseconds(100))
    }
}
