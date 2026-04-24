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

    // MARK: - Build/test input coverage

    @Test func tracksSwiftPackageManifest() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try "// swift-tools-version: 6.0\n".write(
            toFile: dir + "/Package.swift", atomically: true, encoding: .utf8)
        #expect(ProjectFingerprint.maxSourceMtime(projectRoot: dir) != nil)
    }

    @Test func tracksLockfiles() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try "{}\n".write(toFile: dir + "/package-lock.json", atomically: true, encoding: .utf8)
        #expect(ProjectFingerprint.maxSourceMtime(projectRoot: dir) != nil)

        try? FileManager.default.removeItem(atPath: dir + "/package-lock.json")

        try "\n".write(toFile: dir + "/Cargo.lock", atomically: true, encoding: .utf8)
        #expect(ProjectFingerprint.maxSourceMtime(projectRoot: dir) != nil)

        try? FileManager.default.removeItem(atPath: dir + "/Cargo.lock")

        try "\n".write(toFile: dir + "/go.sum", atomically: true, encoding: .utf8)
        #expect(ProjectFingerprint.maxSourceMtime(projectRoot: dir) != nil)
    }

    @Test func tracksTsconfigAndViteConfig() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try "{}\n".write(toFile: dir + "/tsconfig.json", atomically: true, encoding: .utf8)
        #expect(ProjectFingerprint.maxSourceMtime(projectRoot: dir) != nil)
    }

    @Test func tracksMakefileAndDockerfile() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try "all:\n\techo hi\n".write(
            toFile: dir + "/Makefile", atomically: true, encoding: .utf8)
        #expect(ProjectFingerprint.maxSourceMtime(projectRoot: dir) != nil)

        try? FileManager.default.removeItem(atPath: dir + "/Makefile")

        try "FROM alpine\n".write(
            toFile: dir + "/Dockerfile", atomically: true, encoding: .utf8)
        #expect(ProjectFingerprint.maxSourceMtime(projectRoot: dir) != nil)
    }

    @Test func tracksCIWorkflows() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try FileManager.default.createDirectory(
            atPath: dir + "/.github/workflows", withIntermediateDirectories: true)
        try "name: ci\non: push\n".write(
            toFile: dir + "/.github/workflows/ci.yml", atomically: true, encoding: .utf8)
        #expect(ProjectFingerprint.maxSourceMtime(projectRoot: dir) != nil,
                "GitHub Actions workflow changes must invalidate replay")
    }

    @Test func doesNotTrackDotEnv() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // .env commonly holds secrets. Tracking it would pull secret mtimes
        // into the fingerprint, which is a small information leak (via
        // timing) and makes replay thrash on every `source .env`.
        try "API_KEY=secret\n".write(
            toFile: dir + "/.env", atomically: true, encoding: .utf8)
        #expect(ProjectFingerprint.maxSourceMtime(projectRoot: dir) == nil,
                ".env must not contribute to the fingerprint by default")
    }

    @Test func doesNotTrackReadme() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try "# hi\n".write(toFile: dir + "/README.md", atomically: true, encoding: .utf8)
        try "{}\n".write(toFile: dir + "/unknown.xyz", atomically: true, encoding: .utf8)
        #expect(ProjectFingerprint.maxSourceMtime(projectRoot: dir) == nil,
                "documentation and unknown-extension files must not invalidate replay")
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
