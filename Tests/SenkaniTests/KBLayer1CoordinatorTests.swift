import Testing
import Foundation
@testable import Core

@Suite("KBLayer1Coordinator (F+1 Round 4)")
struct KBLayer1CoordinatorTests {

    private func makeRoot() -> String {
        let root = NSTemporaryDirectory() + "senkani-kbl1-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: root + "/.senkani/knowledge",
            withIntermediateDirectories: true)
        return root
    }

    private func cleanup(_ root: String) {
        try? FileManager.default.removeItem(atPath: root)
    }

    @Test func noRebuildWhenDirectoryEmpty() {
        let root = makeRoot(); defer { cleanup(root) }
        let decision = KBLayer1Coordinator.decideRebuild(projectRoot: root)
        #expect(decision == .noRebuildNeeded)
    }

    @Test func rebuildStaleWhenDbAbsentButMdPresent() throws {
        let root = makeRoot(); defer { cleanup(root) }
        let path = root + "/.senkani/knowledge/Foo.md"
        try "# Foo\n".write(toFile: path, atomically: true, encoding: .utf8)

        let decision = KBLayer1Coordinator.decideRebuild(projectRoot: root)
        guard case .rebuildStale(_, let dbMtime) = decision else {
            Issue.record("expected rebuildStale when DB is absent, got \(decision)"); return
        }
        #expect(dbMtime == nil, "absent DB yields nil dbModifiedAt")
    }

    @Test func rebuildCorruptWhenDbTooSmall() throws {
        let root = makeRoot(); defer { cleanup(root) }
        let mdPath = root + "/.senkani/knowledge/Foo.md"
        try "# Foo\n".write(toFile: mdPath, atomically: true, encoding: .utf8)
        let dbPath = root + "/.senkani/knowledge/knowledge.db"
        // Truncated DB file — below the 100-byte SQLite header.
        try "corrupt".write(toFile: dbPath, atomically: true, encoding: .utf8)

        let decision = KBLayer1Coordinator.decideRebuild(projectRoot: root)
        #expect(decision == .rebuildCorrupt,
            "a tiny DB file looks corrupt — rebuild required")
    }

    @Test func noRebuildWhenDbNewerThanMd() throws {
        let root = makeRoot(); defer { cleanup(root) }
        let mdPath = root + "/.senkani/knowledge/Foo.md"
        let dbPath = root + "/.senkani/knowledge/knowledge.db"
        try "# Foo\n".write(toFile: mdPath, atomically: true, encoding: .utf8)
        // Write a valid-enough DB file (100+ bytes so size check passes).
        try String(repeating: "x", count: 200).write(
            toFile: dbPath, atomically: true, encoding: .utf8)
        // Force DB mtime to be in the future relative to the .md.
        let future = Date().addingTimeInterval(3600)
        try FileManager.default.setAttributes(
            [.modificationDate: future], ofItemAtPath: dbPath)

        let decision = KBLayer1Coordinator.decideRebuild(projectRoot: root)
        #expect(decision == .noRebuildNeeded)
    }

    @Test func rebuildWhenMdNewerThanDb() throws {
        let root = makeRoot(); defer { cleanup(root) }
        let mdPath = root + "/.senkani/knowledge/Foo.md"
        let dbPath = root + "/.senkani/knowledge/knowledge.db"
        try String(repeating: "x", count: 200).write(
            toFile: dbPath, atomically: true, encoding: .utf8)
        // Force DB mtime to be old.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)],
            ofItemAtPath: dbPath)
        // Write .md now (fresh mtime).
        try "# Foo\n".write(toFile: mdPath, atomically: true, encoding: .utf8)

        let decision = KBLayer1Coordinator.decideRebuild(projectRoot: root)
        guard case .rebuildStale = decision else {
            Issue.record("expected rebuildStale, got \(decision)"); return
        }
    }
}
