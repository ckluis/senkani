import Testing
import Foundation
@testable import Core

// MARK: - Helpers

private func makeTempSkillsDir() -> String {
    let dir = "/tmp/senkani-skills-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func writeSkill(dir: String, name: String, content: String) {
    let path = (dir as NSString).appendingPathComponent("\(name).md")
    try? content.write(toFile: path, atomically: true, encoding: .utf8)
}

// MARK: - Suite

@Suite("SkillScanner — WARP.md Loading")
struct SkillsLoaderTests {

    @Test("project-local skills discovered")
    func projectLocalSkillsDiscovered() throws {
        let skillsDir = makeTempSkillsDir()
        defer { try? FileManager.default.removeItem(atPath: skillsDir) }

        // .senkani/skills/ is inside a fake project root
        let projectRoot = "/tmp/senkani-proj-\(UUID().uuidString)"
        let localSkillsDir = (projectRoot as NSString).appendingPathComponent(".senkani/skills")
        try FileManager.default.createDirectory(atPath: localSkillsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: projectRoot) }

        writeSkill(dir: localSkillsDir, name: "test-skill", content: """
            ---
            name: test-skill
            description: A test skill
            ---
            Do something useful.
            """)

        let skills = SkillScanner.scanSenkaniSkills(projectRoot: projectRoot)
        #expect(skills.contains(where: { $0.name == "test-skill" }))
    }

    @Test("prompt contains skill content")
    func promptContainsSkillContent() throws {
        let projectRoot = "/tmp/senkani-proj-\(UUID().uuidString)"
        let localSkillsDir = (projectRoot as NSString).appendingPathComponent(".senkani/skills")
        try FileManager.default.createDirectory(atPath: localSkillsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: projectRoot) }

        writeSkill(dir: localSkillsDir, name: "my-skill", content: """
            ---
            name: my-skill
            description: Does things
            ---
            Always use snake_case for variable names.
            """)

        let prompt = SkillScanner.buildSkillsPrompt(projectRoot: projectRoot)
        #expect(prompt.contains("snake_case"))
        #expect(prompt.contains("## Active WARP Skills"))
    }

    @Test("large file triggers truncation notice")
    func byteCapsWithTruncationNotice() throws {
        let projectRoot = "/tmp/senkani-proj-\(UUID().uuidString)"
        let localSkillsDir = (projectRoot as NSString).appendingPathComponent(".senkani/skills")
        try FileManager.default.createDirectory(atPath: localSkillsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: projectRoot) }

        // Write a skill larger than maxFileBytes (2000 bytes)
        let bigContent = String(repeating: "x", count: 3000)
        writeSkill(dir: localSkillsDir, name: "big-skill", content: bigContent)

        let skills = SkillScanner.scanSenkaniSkills(projectRoot: projectRoot)
        let prompt = SkillScanner.buildSkillsPrompt(skills: skills, maxTotalBytes: 8_000, maxFileBytes: 2_000)
        #expect(prompt.contains("Truncated"))
        #expect(prompt.contains("senkani_read"))
    }

    @Test("binary file does not crash")
    func binaryFileSkippedGracefully() throws {
        let projectRoot = "/tmp/senkani-proj-\(UUID().uuidString)"
        let localSkillsDir = (projectRoot as NSString).appendingPathComponent(".senkani/skills")
        try FileManager.default.createDirectory(atPath: localSkillsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: projectRoot) }

        // Write a "binary" file — bytes that aren't valid UTF-8
        let binaryPath = (localSkillsDir as NSString).appendingPathComponent("bad.md")
        let bytes: [UInt8] = [0xFF, 0xFE, 0x00, 0x01, 0x80, 0x81]
        FileManager.default.createFile(atPath: binaryPath, contents: Data(bytes))

        // Should not crash; returns either empty or gracefully skips the file
        let prompt = SkillScanner.buildSkillsPrompt(projectRoot: projectRoot)
        #expect(prompt.isEmpty || !prompt.contains("Fatal"))
    }

    @Test("empty skills directory returns empty prompt")
    func emptyDirReturnsEmptyPrompt() throws {
        let projectRoot = "/tmp/senkani-proj-\(UUID().uuidString)"
        let localSkillsDir = (projectRoot as NSString).appendingPathComponent(".senkani/skills")
        try FileManager.default.createDirectory(atPath: localSkillsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: projectRoot) }

        let prompt = SkillScanner.buildSkillsPrompt(projectRoot: projectRoot)
        #expect(prompt.isEmpty)
    }

    @Test("missing skills directory returns empty prompt")
    func noDirReturnsEmptyPrompt() {
        let projectRoot = "/tmp/senkani-proj-nonexistent-\(UUID().uuidString)"
        let prompt = SkillScanner.buildSkillsPrompt(projectRoot: projectRoot)
        #expect(prompt.isEmpty)
    }
}
