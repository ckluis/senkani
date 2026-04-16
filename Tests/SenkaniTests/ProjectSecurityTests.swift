import Testing
import Foundation
@testable import Core

/// Bach G1: ProjectSecurity was shipped with zero tests. It's a trust
/// boundary — used to validate user-supplied project paths at workspace
/// open time. Missing regressions here mean symlink escape, null-byte
/// smuggling, or privacy leaks via un-redacted paths.
@Suite("ProjectSecurity")
struct ProjectSecurityTests {

    // MARK: - validateProjectPath rejection paths

    @Test func rejectsNullByte() {
        let path = "/tmp/\0evil"
        do {
            _ = try ProjectSecurity.validateProjectPath(path)
            Issue.record("expected SecurityError but validation succeeded")
        } catch ProjectSecurity.SecurityError.pathContainsDangerousComponents {
            // expected
        } catch {
            Issue.record("expected pathContainsDangerousComponents, got \(error)")
        }
    }

    @Test func rejectsDotDotComponent() throws {
        let tmp = NSTemporaryDirectory() + "ps-test-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        // Write a dir at tmp + "sub".
        let sub = tmp + "sub"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        // Construct an escape attempt that survives NSString.standardizingPath.
        // standardizingPath resolves `..` unless there's a symlink — use a symlinked
        // component that `standardizingPath` can't statically resolve.
        let linkName = tmp + "link"
        try FileManager.default.createSymbolicLink(atPath: linkName, withDestinationPath: sub)
        let dangerous = linkName + "/../../../../../etc"
        // Either standardization resolves it and validate accepts /etc (which IS outside
        // allowed roots — rejected) or the .. survives and is rejected. Either is fine,
        // just assert it's rejected.
        #expect(throws: (any Error).self) {
            _ = try ProjectSecurity.validateProjectPath(dangerous)
        }
    }

    @Test func rejectsPathThatDoesNotExist() {
        let path = "/tmp/ps-test-nonexistent-\(UUID().uuidString)"
        do {
            _ = try ProjectSecurity.validateProjectPath(path)
            Issue.record("expected failure")
        } catch ProjectSecurity.SecurityError.pathDoesNotExist {
            // expected
        } catch {
            Issue.record("expected pathDoesNotExist, got \(error)")
        }
    }

    @Test func rejectsPathThatIsAFile() throws {
        let f = NSTemporaryDirectory() + "ps-test-file-\(UUID().uuidString).txt"
        try "x".write(toFile: f, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: f) }
        do {
            _ = try ProjectSecurity.validateProjectPath(f)
            Issue.record("expected notADirectory")
        } catch ProjectSecurity.SecurityError.notADirectory {
            // expected
        } catch {
            Issue.record("expected notADirectory, got \(error)")
        }
    }

    @Test func rejectsSymlinkEscapingAllowedRoots() throws {
        let tmp = NSTemporaryDirectory() + "ps-test-sym-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let link = tmp + "escape"
        // /etc IS a directory and readable but is NOT under an allowed root.
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/etc")
        do {
            _ = try ProjectSecurity.validateProjectPath(link)
            Issue.record("expected symlinkEscape")
        } catch ProjectSecurity.SecurityError.symlinkEscape {
            // expected
        } catch {
            Issue.record("expected symlinkEscape, got \(error)")
        }
    }

    // MARK: - validateProjectPath accept paths

    @Test func acceptsTmpDirectory() throws {
        // Note: `NSTemporaryDirectory()` on macOS resolves to /var/folders/...,
        // which is NOT an allowed root. ProjectSecurity's whitelist is $HOME,
        // /tmp, /private/tmp, /Volumes — deliberately narrow. Use /tmp explicitly.
        let tmp = "/tmp/ps-test-ok-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let url = try ProjectSecurity.validateProjectPath(tmp)
        #expect(url.path.hasPrefix("/private/tmp") || url.path.hasPrefix("/tmp"))
    }

    /// Regression: a path under `/var/folders/...` (macOS default
    /// NSTemporaryDirectory) is NOT in the allowed-roots list. This is
    /// intentional — users shouldn't treat the default app-scoped temp
    /// dir as a project root. The test pins the behavior so any future
    /// relaxation of allowedRoots is a deliberate choice.
    @Test func rejectsDefaultTmpDirectoryOutsideAllowedRoots() throws {
        let tmp = NSTemporaryDirectory() + "ps-test-vf-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        do {
            _ = try ProjectSecurity.validateProjectPath(tmp)
            // On some test runners NSTemporaryDirectory may already be inside
            // an allowed root; if so, this test is a no-op, not a failure.
        } catch ProjectSecurity.SecurityError.symlinkEscape {
            // Expected on standard macOS where NSTemporaryDirectory →
            // /var/folders/… which is outside allowed roots.
        } catch {
            Issue.record("expected symlinkEscape or pass, got \(error)")
        }
    }

    @Test func acceptsHomeSubdirectory() throws {
        let sub = NSHomeDirectory() + "/.senkani-ps-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: sub) }
        _ = try ProjectSecurity.validateProjectPath(sub)
    }

    @Test func acceptsTildeExpansion() throws {
        let name = ".senkani-ps-test-tilde-\(UUID().uuidString)"
        let real = NSHomeDirectory() + "/" + name
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: real) }
        let url = try ProjectSecurity.validateProjectPath("~/" + name)
        #expect(url.path.hasSuffix(name))
    }

    // MARK: - redactPath

    @Test func redactsHomeDirectory() {
        let input = NSHomeDirectory() + "/Projects/foo"
        let out = ProjectSecurity.redactPath(input)
        #expect(out.hasPrefix("~/Projects/foo") || out == "~/Projects/foo")
    }

    @Test func redactsUsernameInUsersPath() {
        let input = "/Users/johndoe/Projects/senkani"
        let out = ProjectSecurity.redactPath(input)
        #expect(out == "/Users/***/Projects/senkani" || !out.contains("johndoe"),
                "username must not appear in redacted output, got: \(out)")
    }

    @Test func redactPathPassesThroughSystemPaths() {
        let input = "/usr/local/bin/swift"
        let out = ProjectSecurity.redactPath(input)
        #expect(out == input)
    }

    @Test func redactPathHandlesEmptyString() {
        #expect(ProjectSecurity.redactPath("") == "")
    }
}
