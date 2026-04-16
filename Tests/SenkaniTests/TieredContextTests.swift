import Testing
import Foundation
@testable import MCPServer
@testable import Core

// MARK: - Helpers

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-tc-db-\(UUID().uuidString).sqlite"
    let db = SessionDatabase(path: path)
    return (db, path)
}

private func cleanupDB(_ path: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: path)
    try? fm.removeItem(atPath: path + "-wal")
    try? fm.removeItem(atPath: path + "-shm")
}

// MARK: - Suite 1: ReadCache — Pinning

@Suite("ReadCache — Pinning")
struct ReadCachePinningTests {

    @Test func pinnedEntrySurvivesLRUEviction() throws {
        let cache = ReadCache()
        let fm = FileManager.default

        // Real file so lookup can verify mtime
        let pinnedPath = "/tmp/senkani-pin-\(UUID().uuidString)"
        fm.createFile(atPath: pinnedPath, contents: "pinned".data(using: .utf8))
        defer { try? fm.removeItem(atPath: pinnedPath) }
        let mtime = (try? fm.attributesOfItem(atPath: pinnedPath))?[.modificationDate] as? Date ?? Date()

        // Pin and store first (oldest lastAccess)
        cache.pin(pinnedPath)
        cache.store(path: pinnedPath, mtime: mtime, content: "pinned", rawBytes: 6)

        // Fill to maxEntries (500 total)
        for i in 1..<500 {
            cache.store(path: "/tmp/ephem-pin-\(i)", mtime: Date(), content: "x", rawBytes: 1)
        }
        // 501st entry triggers eviction — oldest non-pinned should be removed
        cache.store(path: "/tmp/ephem-pin-trigger", mtime: Date(), content: "y", rawBytes: 1)

        #expect(cache.lookup(path: pinnedPath) != nil, "Pinned entry must survive LRU eviction")
    }

    @Test func unpinnedEntryIsEvicted() throws {
        let cache = ReadCache()
        let fm = FileManager.default

        let targetPath = "/tmp/senkani-evict-\(UUID().uuidString)"
        fm.createFile(atPath: targetPath, contents: "target".data(using: .utf8))
        defer { try? fm.removeItem(atPath: targetPath) }
        let mtime = (try? fm.attributesOfItem(atPath: targetPath))?[.modificationDate] as? Date ?? Date()

        // Store target first (oldest lastAccess, not pinned)
        cache.store(path: targetPath, mtime: mtime, content: "target", rawBytes: 6)

        for i in 1..<500 {
            cache.store(path: "/tmp/ephem-npin-\(i)", mtime: Date(), content: "x", rawBytes: 1)
        }
        cache.store(path: "/tmp/ephem-npin-trigger", mtime: Date(), content: "y", rawBytes: 1)

        // Oldest non-pinned entry must have been evicted — lookup returns nil
        #expect(cache.lookup(path: targetPath) == nil, "Oldest unpinned entry must be evicted")
    }

    @Test func clearAlsoClearsPins() throws {
        let cache = ReadCache()
        let fm = FileManager.default

        let path = "/tmp/senkani-clr-\(UUID().uuidString)"
        fm.createFile(atPath: path, contents: "cleartest".data(using: .utf8))
        defer { try? fm.removeItem(atPath: path) }
        let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? Date()

        cache.pin(path)
        cache.store(path: path, mtime: mtime, content: "cleartest", rawBytes: 9)
        cache.clear()

        // Entry is gone after clear
        #expect(cache.lookup(path: path) == nil, "Entry must be nil after clear")

        // Re-store the same path without pin — if pins were cleared, this entry is now evictable
        cache.store(path: path, mtime: mtime, content: "cleartest", rawBytes: 9)
        for i in 1..<500 {
            cache.store(path: "/tmp/ephem-clr-\(i)", mtime: Date(), content: "x", rawBytes: 1)
        }
        cache.store(path: "/tmp/ephem-clr-trigger", mtime: Date(), content: "y", rawBytes: 1)

        // path was stored first (oldest lastAccess), no pin after clear → must be evicted
        #expect(cache.lookup(path: path) == nil, "Entry stored without pin after clear must be evictable")
    }
}

// MARK: - Suite 2: SessionDatabase — hotFiles

@Suite("SessionDatabase — hotFiles")
struct SessionDatabaseHotFilesTests {

    private func insertEvent(
        db: SessionDatabase, projectRoot: String, toolName: String, command: String
    ) {
        db.recordTokenEvent(
            sessionId: "test", paneId: nil, projectRoot: projectRoot,
            source: "mcp_tool", toolName: toolName, model: nil,
            inputTokens: 1, outputTokens: 0, savedTokens: 0, costCents: 0,
            feature: nil, command: command
        )
        _ = db.tokenStatsAllProjects()  // flush async queue via sync barrier
    }

    @Test func hotFilesExcludesExecToolEvents() {
        let (db, dbPath) = makeTempDB()
        defer { cleanupDB(dbPath) }
        let root = "/tmp/hotfiles-exc-\(UUID().uuidString)"
        let fakeFile = "/fake/exec/script.sh"

        for _ in 0..<5 {
            insertEvent(db: db, projectRoot: root, toolName: "exec", command: fakeFile)
        }

        let hot = db.hotFiles(projectRoot: root, limit: 10)
        #expect(!hot.contains(where: { $0.path == fakeFile }),
            "exec-tool events must not appear as hot files")
    }

    @Test func hotFilesIncludesOutlineReadEvents() {
        let (db, dbPath) = makeTempDB()
        defer { cleanupDB(dbPath) }
        let root = "/tmp/hotfiles-inc-\(UUID().uuidString)"
        let fakeFile = "/fake/outline/Module.swift"

        insertEvent(db: db, projectRoot: root, toolName: "outline_read", command: fakeFile)

        let hot = db.hotFiles(projectRoot: root, limit: 10)
        #expect(hot.contains(where: { $0.path == fakeFile }),
            "outline_read events must appear as hot files")
    }

    @Test func hotFilesRankedByFrequency() {
        let (db, dbPath) = makeTempDB()
        defer { cleanupDB(dbPath) }
        let root = "/tmp/hotfiles-rank-\(UUID().uuidString)"
        let pathA = "/fake/frequent/A.swift"
        let pathB = "/fake/less/B.swift"

        for _ in 0..<5 { insertEvent(db: db, projectRoot: root, toolName: "read", command: pathA) }
        for _ in 0..<3 { insertEvent(db: db, projectRoot: root, toolName: "read", command: pathB) }

        let hot = db.hotFiles(projectRoot: root, limit: 10)
        #expect(hot.first?.path == pathA, "Most-read path must rank first")
        #expect(hot.first?.freq == 5, "Frequency must match insert count")
        #expect(hot.count == 2, "Both paths must be returned")
    }
}
