import Foundation
import Testing
@testable import Indexer

/// Tests for `IndexStore.save`'s projectRoot-existence guard. The guard
/// makes the save a silent no-op when `projectRoot` no longer exists,
/// avoiding the `createDirectory(withIntermediateDirectories: true)`
/// side effect of resurrecting a vanished root. Pairs with
/// `mcp-session-warmindex-detached-task-races-test-cleanup-2026-05-18`
/// (closed 2026-05-19): `MCPSession.warmIndex`'s detached Task can
/// outlive a test's `defer cleanup(dir)` and recreate the deleted
/// `/tmp/senkani-outline-test-<UUID>` directory; the guard closes that.
@Suite("IndexStore.save — projectRoot existence guard")
struct IndexStoreSaveGuardTests {

    private func makeTempDir() -> String {
        let path = "/tmp/senkani-indexstore-guard-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test("save silently returns when projectRoot has been deleted")
    func saveSilentlyReturnsWhenProjectRootMissing() throws {
        let dir = makeTempDir()
        // Delete it BEFORE save fires — mimics the warmIndex race where
        // the detached Task lands after the test's defer cleanup.
        try FileManager.default.removeItem(atPath: dir)
        #expect(!FileManager.default.fileExists(atPath: dir))

        var index = SymbolIndex()
        index.projectRoot = dir

        // Must not throw — and must not recreate the projectRoot or
        // the .senkani/ subdir as a side effect of createDirectory.
        try IndexStore.save(index, projectRoot: dir)

        #expect(!FileManager.default.fileExists(atPath: dir),
                "projectRoot must not be resurrected by save()")
        #expect(!FileManager.default.fileExists(atPath: dir + "/.senkani"),
                ".senkani subdir must not be created when projectRoot is missing")
    }

    @Test("save succeeds when projectRoot exists (regression guard)")
    func saveWorksWhenProjectRootExists() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        var index = SymbolIndex()
        index.projectRoot = dir
        index.symbols = [
            IndexEntry(name: "Foo", kind: .struct, file: "Foo.swift",
                       startLine: 1, endLine: 1, engine: "regex")
        ]

        try IndexStore.save(index, projectRoot: dir)

        #expect(FileManager.default.fileExists(atPath: dir + "/.senkani/index.json"),
                "save should write index.json when projectRoot exists")
    }
}
