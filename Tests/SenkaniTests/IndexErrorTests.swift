import Foundation
import Testing
@testable import Indexer

/// Tests for the typed `IndexError` enum and the failure modes of every
/// public Indexer entry point that now throws instead of silently
/// returning `[]`. Pairs with `luminary-2026-04-24-11-indexer-result-errors`
/// (shipped 2026-04-26) — see `spec/cleanup.md` "Silent error swallowing
/// in Indexer" → ✅ done.
@Suite("IndexError")
struct IndexErrorTests {

    // MARK: - Enum shape

    @Test("Equatable conformance distinguishes cases and payloads")
    func equatableDistinguishesPayloads() {
        #expect(IndexError.binaryMissing("ctags") == .binaryMissing("ctags"))
        #expect(IndexError.binaryMissing("ctags") != .binaryMissing("rg"))
        #expect(IndexError.unsupportedLanguage("brainfuck") == .unsupportedLanguage("brainfuck"))
        #expect(IndexError.unsupportedLanguage("brainfuck") != .unsupportedLanguage("malbolge"))
        #expect(IndexError.parseFailed(file: "a", reason: "x")
                != .parseFailed(file: "a", reason: "y"))
        #expect(IndexError.ioError(file: "a.swift", underlying: "ENOENT")
                == .ioError(file: "a.swift", underlying: "ENOENT"))
        // Cross-case inequality
        #expect(IndexError.binaryMissing("ctags") != .unsupportedLanguage("ctags"))
    }

    @Test("description is non-empty and includes the case name")
    func descriptionIsLegible() {
        #expect(IndexError.binaryMissing("ctags").description.contains("binaryMissing"))
        #expect(IndexError.binaryMissing("ctags").description.contains("ctags"))
        #expect(IndexError.parseFailed(file: "x.swift", reason: "boom").description.contains("parseFailed"))
        #expect(IndexError.unsupportedLanguage("brainfuck").description.contains("brainfuck"))
        #expect(IndexError.ioError(file: "x", underlying: "y").description.contains("ioError"))
    }

    // MARK: - CTagsBackend

    @Test("CTagsBackend.index throws .binaryMissing when ctags is not on PATH")
    func ctagsThrowsBinaryMissing() {
        // Force findBinary() to return nil regardless of host install
        let prior = CTagsBackend._binaryPathOverride
        defer { CTagsBackend._binaryPathOverride = prior }
        CTagsBackend._binaryPathOverride = .some(nil)

        #expect(throws: IndexError.binaryMissing("ctags")) {
            _ = try CTagsBackend.index(projectRoot: NSTemporaryDirectory())
        }
    }

    // MARK: - TreeSitterBackend

    @Test("TreeSitterBackend.index throws .unsupportedLanguage for unknown id")
    func treeSitterThrowsUnsupportedLanguage() {
        #expect(throws: IndexError.unsupportedLanguage("brainfuck")) {
            _ = try TreeSitterBackend.index(files: [], language: "brainfuck", projectRoot: "/tmp")
        }
    }

    @Test("TreeSitterBackend.index succeeds with [] when files is empty for a supported language")
    func treeSitterEmptyFilesSucceeds() throws {
        let entries = try TreeSitterBackend.index(files: [], language: "swift", projectRoot: "/tmp")
        #expect(entries.isEmpty)
    }

    // MARK: - RegexBackend

    @Test("RegexBackend.index throws .unsupportedLanguage for missing patterns")
    func regexThrowsUnsupportedLanguage() {
        #expect(throws: IndexError.unsupportedLanguage("brainfuck")) {
            _ = try RegexBackend.index(files: [], language: "brainfuck", projectRoot: "/tmp")
        }
    }

    @Test("RegexBackend.supports reports patterned languages truthfully")
    func regexSupportsLookup() {
        #expect(RegexBackend.supports("swift"))
        #expect(RegexBackend.supports("python"))
        #expect(!RegexBackend.supports("brainfuck"))
    }

    // MARK: - DependencyExtractor

    @Test("DependencyExtractor.extractImports throws .unsupportedLanguage for unknown id")
    func extractImportsThrowsUnsupportedLanguage() {
        #expect(throws: IndexError.unsupportedLanguage("brainfuck")) {
            _ = try DependencyExtractor.extractImports(source: "anything", language: "brainfuck")
        }
    }

    @Test("DependencyExtractor.extractImports returns [] for known-but-importless languages")
    func extractImportsReturnsEmptyForBash() throws {
        // bash / lua / html / css / dart / toml / graphql are tree-sitter-supported
        // but have no import-extraction logic — should succeed with [], not throw.
        let bash = try DependencyExtractor.extractImports(source: "echo hi", language: "bash")
        #expect(bash.isEmpty)
        let lua = try DependencyExtractor.extractImports(source: "print('hi')", language: "lua")
        #expect(lua.isEmpty)
    }

    @Test("DependencyExtractor.extractAllImports throws .unsupportedLanguage")
    func extractAllImportsThrowsUnsupportedLanguage() {
        #expect(throws: IndexError.unsupportedLanguage("brainfuck")) {
            _ = try DependencyExtractor.extractAllImports(files: [], language: "brainfuck", projectRoot: "/tmp")
        }
    }

    // MARK: - IndexEngine.indexFileIncremental

    @Test("indexFileIncremental throws .ioError when file does not exist")
    func indexFileIncrementalThrowsIoError() {
        let cache = TreeCache()
        let tmpDir = NSTemporaryDirectory() + "senkani-indexerror-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        do {
            _ = try IndexEngine.indexFileIncremental(
                relativePath: "does-not-exist.swift",
                projectRoot: tmpDir,
                treeCache: cache
            )
            Issue.record("expected throw")
        } catch let err as IndexError {
            if case .ioError(let file, _) = err {
                #expect(file == "does-not-exist.swift")
            } else {
                Issue.record("expected .ioError, got \(err)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("indexFileIncremental throws .unsupportedLanguage for unknown extension")
    func indexFileIncrementalThrowsUnsupportedLanguage() throws {
        let cache = TreeCache()
        let tmpDir = NSTemporaryDirectory() + "senkani-indexerror-\(UUID().uuidString)"
        let relPath = "thing.brainfuck"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        try "++++.".write(toFile: tmpDir + "/" + relPath, atomically: true, encoding: .utf8)

        do {
            _ = try IndexEngine.indexFileIncremental(
                relativePath: relPath,
                projectRoot: tmpDir,
                treeCache: cache
            )
            Issue.record("expected throw")
        } catch let err as IndexError {
            if case .unsupportedLanguage = err {
                // ok — message mentions either the extension sentinel or the resolved language
            } else {
                Issue.record("expected .unsupportedLanguage, got \(err)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}
