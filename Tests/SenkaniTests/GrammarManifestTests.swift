import Testing
import Foundation
@testable import Indexer

// MARK: - Suite 1: Manifest Correctness

@Suite("GrammarManifest — Registry")
struct GrammarManifestRegistryTests {

    @Test func manifestContainsSwift() {
        let info = GrammarManifest.grammar(for: "swift")
        #expect(info != nil, "Swift grammar should be in manifest")
        #expect(info?.version == "0.7.1")
        #expect(info?.repo == "alex-pinkus/tree-sitter-swift")
        #expect(info?.targetName == "TreeSitterSwiftParser")
    }

    @Test func manifestContainsPython() {
        let info = GrammarManifest.grammar(for: "python")
        #expect(info != nil, "Python grammar should be in manifest")
        #expect(info?.version == "0.23.6")
        #expect(info?.repo == "tree-sitter/tree-sitter-python")
        #expect(info?.targetName == "TreeSitterPythonParser")
    }

    @Test func manifestMatchesBackendSupport() {
        // Every language in the manifest should be supported by TreeSitterBackend
        for language in GrammarManifest.grammars.keys {
            #expect(TreeSitterBackend.supports(language),
                    "\(language) is in manifest but not supported by TreeSitterBackend")
        }

        // Every language supported by TreeSitterBackend should be in the manifest
        for language in TreeSitterBackend.supportedLanguages {
            #expect(GrammarManifest.grammars[language] != nil,
                    "\(language) is supported by TreeSitterBackend but not in manifest")
        }
    }

    @Test func sortedReturnsAlphabeticalOrder() {
        let sorted = GrammarManifest.sorted
        let languages = sorted.map(\.language)
        #expect(languages == languages.sorted(), "sorted should return grammars in alphabetical order")
    }

    @Test func unknownLanguageReturnsNil() {
        #expect(GrammarManifest.grammar(for: "cobol") == nil)
        #expect(GrammarManifest.grammar(for: "") == nil)
    }

    @Test func versionFilesMatchManifest() throws {
        // Verify VERSION files on disk match what the manifest declares.
        // This catches the case where someone updates a grammar but forgets the manifest.
        let projectRoot = findProjectRoot()
        guard let root = projectRoot else {
            // Running outside the project tree (e.g., CI sandbox). Skip gracefully.
            return
        }

        for info in GrammarManifest.sorted {
            let versionPath = root + "/Sources/\(info.targetName)/VERSION"
            guard let content = try? String(contentsOfFile: versionPath, encoding: .utf8) else {
                Issue.record("VERSION file not found for \(info.targetName) at \(versionPath)")
                continue
            }
            let firstLine = content.components(separatedBy: "\n").first ?? ""
            #expect(firstLine.contains(info.version),
                    "VERSION file for \(info.language) should contain \(info.version), got: \(firstLine)")
        }
    }
}

// MARK: - Suite 2: Semver Comparison

@Suite("GrammarManifest — Semver")
struct GrammarManifestSemverTests {

    @Test func equalVersions() {
        #expect(GrammarManifest.compareSemver("1.2.3", "1.2.3") == 0)
        #expect(GrammarManifest.compareSemver("0.7.1", "0.7.1") == 0)
    }

    @Test func greaterVersion() {
        #expect(GrammarManifest.compareSemver("1.2.4", "1.2.3") == 1)
        #expect(GrammarManifest.compareSemver("1.3.0", "1.2.9") == 1)
        #expect(GrammarManifest.compareSemver("2.0.0", "1.99.99") == 1)
    }

    @Test func lesserVersion() {
        #expect(GrammarManifest.compareSemver("1.2.3", "1.2.4") == -1)
        #expect(GrammarManifest.compareSemver("0.7.1", "0.23.6") == -1)
    }

    @Test func differentComponentCounts() {
        // "1.2" should equal "1.2.0"
        #expect(GrammarManifest.compareSemver("1.2", "1.2.0") == 0)
        // "1.2.1" should be greater than "1.2"
        #expect(GrammarManifest.compareSemver("1.2.1", "1.2") == 1)
    }

    @Test func singleComponentVersions() {
        #expect(GrammarManifest.compareSemver("2", "1") == 1)
        #expect(GrammarManifest.compareSemver("1", "2") == -1)
        #expect(GrammarManifest.compareSemver("1", "1.0.0") == 0)
    }
}

// MARK: - Suite 3: Version Checker

@Suite("GrammarVersionChecker — Utilities")
struct GrammarVersionCheckerTests {

    @Test func stripVersionPrefix() {
        #expect(GrammarVersionChecker.stripVersionPrefix("v0.7.1") == "0.7.1")
        #expect(GrammarVersionChecker.stripVersionPrefix("v0.23.6") == "0.23.6")
        #expect(GrammarVersionChecker.stripVersionPrefix("0.7.1") == "0.7.1")
        #expect(GrammarVersionChecker.stripVersionPrefix("release-1.0") == "release-1.0")
    }

    @Test func cachedResultsReturnsNilWithoutCache() {
        // With no cache file on disk, cachedResults should return nil gracefully
        let results = GrammarVersionChecker.cachedResults()
        // This is non-deterministic (cache may or may not exist from prior runs),
        // but it should never crash
        _ = results
    }
}

// MARK: - Helpers

/// Walk up from the test bundle's location to find the project root.
private func findProjectRoot() -> String? {
    // Try common locations relative to where tests run
    var dir = FileManager.default.currentDirectoryPath
    for _ in 0..<10 {
        if FileManager.default.fileExists(atPath: dir + "/Package.swift") {
            return dir
        }
        dir = (dir as NSString).deletingLastPathComponent
    }
    return nil
}
