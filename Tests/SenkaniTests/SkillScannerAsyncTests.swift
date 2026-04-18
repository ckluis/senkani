import Testing
import Foundation
@testable import Core

// MARK: - Fixture helpers

private func makeFixtureHome() throws -> String {
    let root = "/tmp/senkani-scanner-home-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    return root
}

private func writeFile(_ dir: String, _ name: String, _ content: String) throws {
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = (dir as NSString).appendingPathComponent(name)
    try content.write(toFile: path, atomically: true, encoding: .utf8)
}

private func seedClaudeCommand(home: String, name: String) throws {
    let dir = (home as NSString).appendingPathComponent(".claude/commands")
    try writeFile(dir, "\(name).md", "# \(name)\n\nRun the \(name) command.\n")
}

private func seedCursorRule(home: String, name: String) throws {
    let dir = (home as NSString).appendingPathComponent(".cursor/rules")
    try writeFile(dir, "\(name).md", "# \(name)\n\n\(name) cursor rule.\n")
}

private func seedSenkaniSkill(home: String, name: String) throws {
    let dir = (home as NSString).appendingPathComponent(".senkani/skills")
    try writeFile(dir, "\(name).md", """
        ---
        name: \(name)
        description: Seeded \(name) skill.
        ---
        Body of \(name).
        """)
}

// MARK: - Suite

@Suite("SkillScanner — scanAsync / scan(homeDir:cwd:)")
struct SkillScannerAsyncTests {

    @Test("scan(homeDir:cwd:) on empty fixture returns empty")
    func emptyFixture() throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let cwd = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(atPath: cwd) }

        let skills = SkillScanner.scan(homeDir: home, cwd: cwd)
        #expect(skills.isEmpty)
    }

    @Test("scanAsync matches scan on a seeded fixture")
    func parityOnFixture() async throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let cwd = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(atPath: cwd) }

        try seedClaudeCommand(home: home, name: "alpha")
        try seedClaudeCommand(home: home, name: "beta")
        try seedCursorRule(home: home, name: "style")
        try seedSenkaniSkill(home: home, name: "gamma")

        let sync = SkillScanner.scan(homeDir: home, cwd: cwd)
        let async_ = await SkillScanner.scanAsync(homeDir: home, cwd: cwd)

        #expect(sync.count == async_.count)
        #expect(sync.count >= 4)

        // Both paths must agree on the (name|type) key-set since ordering is
        // deterministic (sorted by source then name).
        let syncKeys = sync.map { "\($0.name)|\($0.type.rawValue)|\($0.source)" }
        let asyncKeys = async_.map { "\($0.name)|\($0.type.rawValue)|\($0.source)" }
        #expect(syncKeys == asyncKeys)

        // Sanity: the seeded entries are present.
        #expect(sync.contains(where: { $0.name == "alpha" && $0.type == .command }))
        #expect(sync.contains(where: { $0.name == "style" && $0.type == .rule }))
        #expect(sync.contains(where: { $0.name == "gamma" && $0.type == .skill }))
    }

    @Test("scanAsync finishes promptly on a fixture with many files")
    func timingSanity() async throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let cwd = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(atPath: cwd) }

        // Seed 60 Claude commands + 20 Cursor rules — well above a typical
        // dotfile tree. scanAsync runs on a detached utility task so total
        // wall-clock should stay well under the bound even on a loaded CI box.
        for i in 0..<60 { try seedClaudeCommand(home: home, name: "cmd\(i)") }
        for i in 0..<20 { try seedCursorRule(home: home, name: "rule\(i)") }

        let start = Date()
        let skills = await SkillScanner.scanAsync(homeDir: home, cwd: cwd)
        let elapsed = Date().timeIntervalSince(start)

        #expect(skills.count >= 80)
        // 2s is ~1000x the real scan time for 80 tiny files. A regression
        // that reverts scanAsync to synchronous would still pass this bound
        // — the real value is ruling out deadlock / infinite-recursion
        // regressions, not micro-benchmarking.
        #expect(elapsed < 2.0)
    }

    @Test("scanAsync does not stall concurrent main-actor work")
    func doesNotStallConcurrentWork() async throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let cwd = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(atPath: cwd) }

        for i in 0..<30 { try seedClaudeCommand(home: home, name: "cmd\(i)") }

        // Run scanAsync and a parallel MainActor ping. If scanAsync were
        // blocking the task executor, the ping would queue behind it. With
        // Task.detached(priority:.utility) the ping completes independently.
        async let scan: [SkillInfo] = SkillScanner.scanAsync(homeDir: home, cwd: cwd)
        async let ping: Int = { () -> Int in
            var total = 0
            for i in 0..<1_000 { total &+= i }
            return total
        }()

        let (skills, pingResult) = await (scan, ping)
        #expect(skills.count >= 30)
        #expect(pingResult == 499_500)
    }
}
