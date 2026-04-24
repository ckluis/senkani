import Testing
import Foundation
@testable import MCPServer
@testable import Core
import MCP

/// Cache semantics for `senkani_read`.
///
/// The spec says cached reads return the *cached content*, not a placeholder —
/// especially important after context compaction when the agent re-calls
/// `senkani_read` to recover a file it no longer has in-context. Prior to this
/// fix, the tool returned `"// senkani: cached ... [unchanged since last read]"`
/// with no content, which satisfied the "0 token" savings metric but broke the
/// actual recovery use case.
@Suite("ReadTool — cache semantics")
struct ReadToolCacheTests {

    private func makeSession(projectRoot: String) -> MCPSession {
        MCPSession(
            projectRoot: projectRoot,
            filterEnabled: false,
            secretsEnabled: false,
            indexerEnabled: false,
            cacheEnabled: true,
            terseEnabled: false
        )
    }

    private func makeTempDir() -> String {
        let raw = "/tmp/senkani-readtool-cache-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
    }

    private func textOf(_ result: CallTool.Result) -> String {
        result.content.first.flatMap {
            if case .text(let t, _, _) = $0 { return t } else { return nil }
        } ?? ""
    }

    @Test func secondFullReadReturnsCachedContent() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let source = "public func greet() { print(\"hi\") }\n"
        try source.write(toFile: dir + "/Greet.swift", atomically: true, encoding: .utf8)

        let session = makeSession(projectRoot: dir)

        // First read: populates the cache with the processed output.
        let first = ReadTool.handle(
            arguments: ["path": .string("Greet.swift"), "full": .bool(true)],
            session: session
        )
        let firstText = textOf(first)
        #expect(firstText.contains("greet"), "first read should include file content, got: \(firstText.prefix(120))")

        // Second read: must return the same content from cache. The header
        // changes (cached hint), but the file body must be present.
        let second = ReadTool.handle(
            arguments: ["path": .string("Greet.swift"), "full": .bool(true)],
            session: session
        )
        let secondText = textOf(second)
        #expect(secondText.contains("cached"), "second read should announce cache hit, got: \(secondText.prefix(120))")
        #expect(secondText.contains("greet"), "cached read must return cached content, not a placeholder, got: \(secondText.prefix(200))")
        #expect(!secondText.contains("[unchanged since last read]"),
                "old placeholder header must not leak into cached output: \(secondText.prefix(200))")
    }

    @Test func rangeReadIsNotServedFromFullCache() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let source = (1...10).map { "line\($0)" }.joined(separator: "\n") + "\n"
        try source.write(toFile: dir + "/lines.txt", atomically: true, encoding: .utf8)

        let session = makeSession(projectRoot: dir)

        // Prime the cache with a full read.
        _ = ReadTool.handle(
            arguments: ["path": .string("lines.txt"), "full": .bool(true)],
            session: session
        )

        // Range read must re-slice from source, not reuse the full cached entry
        // (which would ignore the offset/limit window).
        let ranged = ReadTool.handle(
            arguments: [
                "path": .string("lines.txt"),
                "offset": .int(3),
                "limit": .int(2),
            ],
            session: session
        )
        let text = textOf(ranged)
        #expect(text.contains("line3"), "range read should include line3")
        #expect(text.contains("line4"), "range read should include line4")
        #expect(!text.contains("line9"), "range read should not return full file")
        #expect(!text.contains("cached"),
                "range read must not be served from the full-content cache, got: \(text.prefix(200))")
    }

    @Test func cacheInvalidatedOnMtimeChange() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let filePath = dir + "/volatile.swift"
        try "let v = 1\n".write(toFile: filePath, atomically: true, encoding: .utf8)

        let session = makeSession(projectRoot: dir)

        _ = ReadTool.handle(
            arguments: ["path": .string("volatile.swift"), "full": .bool(true)],
            session: session
        )

        // Bump mtime so ReadCache.lookup invalidates.
        let future = Date().addingTimeInterval(10)
        try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: filePath)
        try "let v = 2\n".write(toFile: filePath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: filePath)

        let second = ReadTool.handle(
            arguments: ["path": .string("volatile.swift"), "full": .bool(true)],
            session: session
        )
        let text = textOf(second)
        #expect(text.contains("let v = 2"), "changed file should bypass cache")
        #expect(!text.contains("cached"), "changed file must not report a cache hit")
    }

    @Test func outOfRootAbsolutePathRejected() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let session = makeSession(projectRoot: dir)

        let result = ReadTool.handle(
            arguments: ["path": .string("/etc/hosts"), "full": .bool(true)],
            session: session
        )
        #expect(result.isError == true, "absolute path outside root must be rejected")
    }

    @Test func dotDotEscapeRejected() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let session = makeSession(projectRoot: dir)

        let result = ReadTool.handle(
            arguments: ["path": .string("../etc/hosts"), "full": .bool(true)],
            session: session
        )
        #expect(result.isError == true, "../ escape must be rejected")
    }
}
