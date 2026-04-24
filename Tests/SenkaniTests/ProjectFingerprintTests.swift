import Testing
import Foundation
@testable import Core

@Suite("ProjectFingerprint")
struct ProjectFingerprintTests {

    private func makeTempDir() -> String {
        let raw = "/tmp/senkani-fp-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        return raw
    }

    @Test func emptyDirectoryReturnsNil() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(ProjectFingerprint.maxSourceMtime(projectRoot: dir) == nil)
    }

    @Test func findsTopLevelSourceFile() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try "let x = 1\n".write(toFile: dir + "/a.swift", atomically: true, encoding: .utf8)
        let m = ProjectFingerprint.maxSourceMtime(projectRoot: dir)
        #expect(m != nil, "should find a.swift")
    }

    @Test func findsNestedSourceFile() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try FileManager.default.createDirectory(atPath: dir + "/src/sub", withIntermediateDirectories: true)
        try "let x = 1\n".write(toFile: dir + "/src/sub/deep.swift", atomically: true, encoding: .utf8)

        let m = ProjectFingerprint.maxSourceMtime(projectRoot: dir)
        #expect(m != nil, "should find nested deep.swift")
    }

    @Test func ignoresSkipDirs() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try FileManager.default.createDirectory(atPath: dir + "/node_modules", withIntermediateDirectories: true)
        try "junk\n".write(toFile: dir + "/node_modules/x.swift", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: dir + "/.git", withIntermediateDirectories: true)
        try "junk\n".write(toFile: dir + "/.git/HEAD.swift", atomically: true, encoding: .utf8)

        #expect(ProjectFingerprint.maxSourceMtime(projectRoot: dir) == nil,
                "skip-dir source files must not contribute")
    }

    @Test func ignoresUntrackedExtensions() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try "binary\n".write(toFile: dir + "/image.png", atomically: true, encoding: .utf8)
        try "data\n".write(toFile: dir + "/README.md", atomically: true, encoding: .utf8)

        #expect(ProjectFingerprint.maxSourceMtime(projectRoot: dir) == nil)
    }

    @Test func detectsMtimeAfterThreshold() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let file = dir + "/a.swift"
        try "let x = 1\n".write(toFile: file, atomically: true, encoding: .utf8)

        let past = Date().addingTimeInterval(-600)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: file)

        let after = Date()
        guard let m = ProjectFingerprint.maxSourceMtime(projectRoot: dir) else {
            Issue.record("expected a date")
            return
        }
        // The set-back mtime should be reported, not something in the future.
        #expect(m < after, "fingerprint must reflect the backdated mtime")
    }
}
