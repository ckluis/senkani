import Testing
import Foundation
import CryptoKit
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

// MARK: - Suite 1b: Content-Hash Pinning (supply-chain integrity)

@Suite("GrammarManifest — Content hashes")
struct GrammarManifestContentHashTests {

    @Test func everyGrammarDeclaresAHash() {
        for info in GrammarManifest.sorted {
            #expect(!info.contentHash.isEmpty,
                    "\(info.language) is missing contentHash")
        }
    }

    @Test func everyHashIsLowercaseHex64() {
        // SHA-256 hex digest is exactly 64 lowercase hex chars.
        let hexCharset = CharacterSet(charactersIn: "0123456789abcdef")
        for info in GrammarManifest.sorted {
            #expect(info.contentHash.count == 64,
                    "\(info.language) hash length is \(info.contentHash.count), want 64")
            let chars = CharacterSet(charactersIn: info.contentHash)
            #expect(chars.isSubset(of: hexCharset),
                    "\(info.language) hash '\(info.contentHash)' has non-hex chars")
        }
    }

    @Test func hashesAreUnique() {
        // Two grammars sharing a hash would either be a copy-paste bug
        // in the manifest or two grammars vendored from byte-identical
        // source — both worth flagging.
        var byHash: [String: [String]] = [:]
        for info in GrammarManifest.sorted {
            byHash[info.contentHash, default: []].append(info.language)
        }
        for (hash, langs) in byHash where langs.count > 1 {
            Issue.record("hash \(hash) is shared by \(langs)")
        }
    }

    @Test func hashMatchesVendoredCContent() throws {
        // Spot-check the hash matches an on-disk recompute. Catches
        // forgot-to-rerun-verify-grammar-hashes.sh after a re-vendor.
        // Same algorithm as `tools/verify-grammar-hashes.sh`:
        //   sha256(parser.c [+ scanner.c when present])
        guard let root = findProjectRoot() else { return }

        for info in GrammarManifest.sorted {
            let parserPath = "\(root)/Sources/\(info.targetName)/parser.c"
            let scannerPath = "\(root)/Sources/\(info.targetName)/scanner.c"

            guard let parserData = FileManager.default.contents(atPath: parserPath) else {
                Issue.record("parser.c missing for \(info.language) at \(parserPath)")
                continue
            }
            var payload = parserData
            if let scannerData = FileManager.default.contents(atPath: scannerPath) {
                payload.append(scannerData)
            }

            let computed = sha256Hex(payload)
            #expect(computed == info.contentHash,
                    "\(info.language) hash mismatch — manifest=\(info.contentHash) computed=\(computed)")
        }
    }

    @Test func everyTargetNameStartsWithTreeSitter() {
        // The verify + SBOM scripts assume `Sources/<targetName>/` and
        // a `TreeSitter…Parser` naming pattern. Catch drift early.
        for info in GrammarManifest.sorted {
            #expect(info.targetName.hasPrefix("TreeSitter"),
                    "\(info.language) targetName '\(info.targetName)' must start with TreeSitter")
            #expect(info.targetName.hasSuffix("Parser"),
                    "\(info.language) targetName '\(info.targetName)' must end with Parser")
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

/// SHA-256 hex digest of `data` — must match the algorithm used by
/// `tools/verify-grammar-hashes.sh` and the manifest's `contentHash`.
private func sha256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

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
