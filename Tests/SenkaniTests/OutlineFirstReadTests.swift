import Testing
import Foundation
@testable import MCPServer
@testable import Indexer
import MCP

/// Helper to create a minimal MCPSession with a pre-populated symbol index.
private func makeSession(projectRoot: String, indexerEnabled: Bool = true) -> MCPSession {
    MCPSession(
        projectRoot: projectRoot,
        filterEnabled: false,
        secretsEnabled: false,
        indexerEnabled: indexerEnabled,
        cacheEnabled: false,
        terseEnabled: false
    )
}

/// Inject a pre-built SymbolIndex directly into the session.
/// Uses `_setIndexForTesting` (an internal test seam on MCPSession) to
/// bypass disk I/O and the file walker — both of which resolve `/tmp`
/// to `/private/tmp` differently across macOS versions, leaving the
/// injected symbols invisible to outline lookup on some CI runners.
private func injectIndex(_ session: MCPSession, symbols: [IndexEntry]) {
    var idx = SymbolIndex()
    idx.projectRoot = session.projectRoot
    idx.symbols = symbols
    session._setIndexForTesting(idx)
}

private func makeTempDir() -> String {
    let path = "/tmp/senkani-outline-test-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

private func cleanup(_ path: String) {
    try? FileManager.default.removeItem(atPath: path)
}

@Suite("ReadTool — Outline-First Read")
struct OutlineFirstReadTests {

    @Test func defaultReadReturnsOutlineWhenIndexAvailable() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        // Write a Swift file
        let code = """
        struct Foo {
            func bar() {}
            func baz() {}
        }
        """
        try code.write(toFile: dir + "/Foo.swift", atomically: true, encoding: .utf8)

        let session = makeSession(projectRoot: dir)
        injectIndex(session, symbols: [
            IndexEntry(name: "Foo", kind: .struct, file: "Foo.swift", startLine: 1, endLine: 4, engine: "regex"),
            IndexEntry(name: "bar", kind: .method, file: "Foo.swift", startLine: 2, endLine: 2, container: "Foo", engine: "regex"),
            IndexEntry(name: "baz", kind: .method, file: "Foo.swift", startLine: 3, endLine: 3, container: "Foo", engine: "regex"),
        ])

        let result = ReadTool.handle(
            arguments: ["path": .string("Foo.swift")],
            session: session
        )

        let text = result.content.first.flatMap {
            if case .text(let t, _, _) = $0 { return t } else { return nil }
        } ?? ""

        // Should be an outline, not the full file content
        #expect(text.contains("outline"), "Default read should return outline, got: \(text.prefix(200))")
        #expect(text.contains("Foo"), "Outline should contain struct name")
        #expect(text.contains("bar"), "Outline should contain method name")
        #expect(text.contains("baz"), "Outline should contain method name")
        #expect(!text.contains("func bar()"), "Outline should NOT contain full source code")
        #expect(text.contains("full: true"), "Outline should hint about full read opt-in")
    }

    @Test func fullTrueReturnsFull() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let code = "struct Foo {\n    func bar() {}\n}\n"
        try code.write(toFile: dir + "/Foo.swift", atomically: true, encoding: .utf8)

        let session = makeSession(projectRoot: dir)
        injectIndex(session, symbols: [
            IndexEntry(name: "Foo", kind: .struct, file: "Foo.swift", startLine: 1, endLine: 3, engine: "regex"),
        ])

        let result = ReadTool.handle(
            arguments: ["path": .string("Foo.swift"), "full": .bool(true)],
            session: session
        )

        let text = result.content.first.flatMap {
            if case .text(let t, _, _) = $0 { return t } else { return nil }
        } ?? ""

        // Should contain the actual code
        #expect(text.contains("func bar()"), "full: true should return complete file content")
        #expect(!text.contains("outline"), "full: true should not say 'outline'")
    }

    @Test func offsetLimitImpliesFullRead() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let code = "line1\nline2\nline3\nline4\nline5\n"
        try code.write(toFile: dir + "/test.txt", atomically: true, encoding: .utf8)

        let session = makeSession(projectRoot: dir)
        // Even with index symbols, offset/limit should force full read
        injectIndex(session, symbols: [
            IndexEntry(name: "something", kind: .function, file: "test.txt", startLine: 1, engine: "regex"),
        ])

        let result = ReadTool.handle(
            arguments: [
                "path": .string("test.txt"),
                "offset": .int(2),
                "limit": .int(2),
            ],
            session: session
        )

        let text = result.content.first.flatMap {
            if case .text(let t, _, _) = $0 { return t } else { return nil }
        } ?? ""

        #expect(text.contains("line2"), "offset/limit should return actual lines")
        #expect(text.contains("line3"), "offset/limit should return actual lines")
        #expect(!text.contains("outline"), "offset/limit should not return outline")
    }

    @Test func fallsBackToFullReadWhenNoIndex() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let code = "let x = 42\n"
        try code.write(toFile: dir + "/simple.swift", atomically: true, encoding: .utf8)

        // Session with indexer enabled but no index populated (no warmIndex call)
        let session = MCPSession(
            projectRoot: dir,
            filterEnabled: false,
            secretsEnabled: false,
            indexerEnabled: true,
            cacheEnabled: false,
            terseEnabled: false
        )
        // Don't inject any index — indexIfReady() will return nil

        let result = ReadTool.handle(
            arguments: ["path": .string("simple.swift")],
            session: session
        )

        let text = result.content.first.flatMap {
            if case .text(let t, _, _) = $0 { return t } else { return nil }
        } ?? ""

        // Should fall back to full content
        #expect(text.contains("let x = 42"), "Without index, should fall back to full read")
    }

    @Test func fallsBackToFullReadWhenIndexerDisabled() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let code = "let y = 99\n"
        try code.write(toFile: dir + "/disabled.swift", atomically: true, encoding: .utf8)

        let session = makeSession(projectRoot: dir, indexerEnabled: false)

        let result = ReadTool.handle(
            arguments: ["path": .string("disabled.swift")],
            session: session
        )

        let text = result.content.first.flatMap {
            if case .text(let t, _, _) = $0 { return t } else { return nil }
        } ?? ""

        #expect(text.contains("let y = 99"), "With indexer disabled, should return full content")
    }
}
