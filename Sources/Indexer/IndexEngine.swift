import Foundation
import SwiftTreeSitter

/// Orchestrates symbol indexing across multiple backends.
/// Tries sourcekit-lsp first, then ctags, then regex.
public enum IndexEngine {
    /// Index an entire project, using the best available backend.
    /// When a `treeCache` is provided, parsed trees are stored for later incremental re-parsing.
    public static func index(projectRoot: String, treeCache: TreeCache? = nil) -> SymbolIndex {
        let walk = FileWalker.walk(projectRoot: projectRoot)
        var idx = SymbolIndex()
        idx.projectRoot = projectRoot
        idx.generated = Date()

        // Determine available backends
        _ = CTagsBackend.isAvailable()
        let usedEngine: String

        // Use tree-sitter for supported languages, regex for everything else.
        // Per-language backend errors (unsupportedLanguage, parser setup
        // failures) are logged + skipped here — this is the explicit
        // "we know what we're swallowing" point. Per-file failures
        // inside the batch are still skipped silently inside the
        // backends, which is the right behavior for batch indexing.
        var allEntries: [IndexEntry] = []
        var treeSitterCount = 0
        var regexCount = 0
        for (language, files) in walk.byLanguage {
            if TreeSitterBackend.supports(language) {
                do {
                    let entries = try TreeSitterBackend.index(files: files, language: language, projectRoot: projectRoot, treeCache: treeCache)
                    allEntries.append(contentsOf: entries)
                    treeSitterCount += entries.count
                } catch {
                    fputs("senkani: tree-sitter index skipped for \(language): \(error)\n", stderr)
                }
            } else if RegexBackend.supports(language) {
                do {
                    let entries = try RegexBackend.index(files: files, language: language, projectRoot: projectRoot)
                    allEntries.append(contentsOf: entries)
                    regexCount += entries.count
                } catch {
                    fputs("senkani: regex index skipped for \(language): \(error)\n", stderr)
                }
            }
            // else: language has neither backend — legitimately nothing to do
        }
        idx.symbols = allEntries
        usedEngine = treeSitterCount > 0 ? "tree-sitter+regex" : "regex"
        fputs("senkani: indexed \(allEntries.count) symbols (\(treeSitterCount) tree-sitter, \(regexCount) regex, \(walk.byLanguage.count) languages)\n", stderr)

        idx.engine = usedEngine

        // Compute file hashes for incremental updates
        idx.fileHashes = computeHashes(files: walk.files, projectRoot: projectRoot)

        return idx
    }

    /// Incrementally update an existing index, re-indexing only changed files.
    /// When a `treeCache` is provided, parsed trees are stored for later incremental re-parsing.
    public static func incrementalUpdate(existing: SymbolIndex, projectRoot: String, treeCache: TreeCache? = nil) -> SymbolIndex {
        let walk = FileWalker.walk(projectRoot: projectRoot)
        let currentHashes = computeHashes(files: walk.files, projectRoot: projectRoot)

        // Find changed, added, and deleted files
        var changedFiles: Set<String> = []
        for (file, hash) in currentHashes {
            if existing.fileHashes[file] != hash {
                changedFiles.insert(file)
            }
        }
        let deletedFiles = Set(existing.fileHashes.keys).subtracting(Set(currentHashes.keys))

        if changedFiles.isEmpty && deletedFiles.isEmpty {
            fputs("senkani: index up to date (no changes detected)\n", stderr)
            return existing
        }

        // If too many files changed, full re-index is faster
        if changedFiles.count > 50 {
            fputs("senkani: \(changedFiles.count) files changed, full re-index\n", stderr)
            return index(projectRoot: projectRoot)
        }

        fputs("senkani: \(changedFiles.count) changed, \(deletedFiles.count) deleted, incremental update\n", stderr)

        var updated = existing
        updated.removeSymbols(forFiles: changedFiles.union(deletedFiles))

        // Re-index only changed files
        let hasCTags = CTagsBackend.isAvailable()

        if hasCTags {
            // ctags on specific files
            // For simplicity, re-run ctags on the whole project and filter to changed files.
            // ctags failure here (binary disappeared between isAvailable() and index)
            // is logged + treated as "no incremental update from ctags this round."
            do {
                let allEntries = try CTagsBackend.index(projectRoot: projectRoot)
                let newEntries = allEntries.filter { changedFiles.contains($0.file) }
                let newHashes = currentHashes.filter { changedFiles.contains($0.key) }
                updated.addSymbols(newEntries, hashes: newHashes)
            } catch {
                fputs("senkani: ctags incremental skipped: \(error)\n", stderr)
            }
        } else {
            // Tree-sitter for supported languages, regex for everything else
            var newEntries: [IndexEntry] = []
            for (language, files) in walk.byLanguage {
                let changedInLang = files.filter { changedFiles.contains($0) }
                guard !changedInLang.isEmpty else { continue }
                if TreeSitterBackend.supports(language) {
                    do {
                        let entries = try TreeSitterBackend.index(files: changedInLang, language: language, projectRoot: projectRoot, treeCache: treeCache)
                        newEntries.append(contentsOf: entries)
                    } catch {
                        fputs("senkani: tree-sitter incremental skipped for \(language): \(error)\n", stderr)
                    }
                } else if RegexBackend.supports(language) {
                    do {
                        let entries = try RegexBackend.index(files: changedInLang, language: language, projectRoot: projectRoot)
                        newEntries.append(contentsOf: entries)
                    } catch {
                        fputs("senkani: regex incremental skipped for \(language): \(error)\n", stderr)
                    }
                }
            }
            let newHashes = currentHashes.filter { changedFiles.contains($0.key) }
            updated.addSymbols(newEntries, hashes: newHashes)
        }

        updated.generated = Date()
        return updated
    }

    /// Incrementally re-index a single file using a cached tree.
    /// If the file content hasn't changed (same hash), returns symbols from the cached tree.
    /// If changed, performs incremental re-parse via tree-sitter's Tree.edit() mechanism.
    /// Falls back to full parse when no cache entry exists or incremental parse fails.
    ///
    /// Throws `IndexError.ioError(...)` if the file cannot be read,
    /// `IndexError.unsupportedLanguage(...)` if the extension does not
    /// map to a tree-sitter-backed language, and `IndexError.parseFailed(...)`
    /// if parser setup or parsing itself fails. Empty `[]` returns
    /// only when extraction succeeded but the file genuinely has no
    /// symbols (e.g., an empty `tree.rootNode`).
    public static func indexFileIncremental(
        relativePath: String,
        projectRoot: String,
        treeCache: TreeCache
    ) throws -> [IndexEntry] {
        let fullPath = projectRoot + "/" + relativePath
        let newContent: String
        do {
            newContent = try String(contentsOfFile: fullPath, encoding: .utf8)
        } catch {
            throw IndexError.ioError(file: relativePath, underlying: "\(error)")
        }
        let newHash = TreeCache.hash(newContent)

        // Determine language from file extension
        let ext = (relativePath as NSString).pathExtension
        guard let language = FileWalker.languageMap[ext] else {
            throw IndexError.unsupportedLanguage("(extension: \(ext))")
        }
        guard TreeSitterBackend.supports(language) else {
            throw IndexError.unsupportedLanguage(language)
        }

        // Check cache
        if let cached = treeCache.lookup(file: relativePath) {
            if cached.contentHash == newHash {
                // Unchanged — extract symbols from cached tree
                guard let root = cached.tree.rootNode else { return [] }
                return try TreeSitterBackend.extractSymbols(from: root, source: newContent, language: language, file: relativePath)
            }

            // Content changed — incremental re-parse
            if let newTree = IncrementalParser.reparse(
                oldTree: cached.tree,
                oldContent: cached.content,
                newContent: newContent,
                language: language
            ) {
                treeCache.store(file: relativePath, tree: newTree, content: newContent, contentHash: newHash, language: language)
                guard let root = newTree.rootNode else { return [] }
                return try TreeSitterBackend.extractSymbols(from: root, source: newContent, language: language, file: relativePath)
            }
        }

        // No cache or incremental parse failed — full parse
        guard let tsLanguage = TreeSitterBackend.language(for: language) else {
            throw IndexError.unsupportedLanguage(language)
        }
        let parser = Parser()
        do {
            try parser.setLanguage(tsLanguage)
        } catch {
            throw IndexError.parseFailed(file: relativePath, reason: "setLanguage(\(language)) failed: \(error)")
        }
        guard let tree = parser.parse(newContent) else {
            throw IndexError.parseFailed(file: relativePath, reason: "parser.parse returned nil")
        }

        treeCache.store(file: relativePath, tree: tree, content: newContent, contentHash: newHash, language: language)
        guard let root = tree.rootNode else { return [] }
        return try TreeSitterBackend.extractSymbols(from: root, source: newContent, language: language, file: relativePath)
    }

    /// Build the dependency graph by extracting imports from all source files.
    public static func buildDependencyGraph(projectRoot: String) -> DependencyGraph {
        let walk = FileWalker.walk(projectRoot: projectRoot)
        var imports: [String: [String]] = [:]
        var importedBy: [String: [String]] = [:]

        for (language, files) in walk.byLanguage where TreeSitterBackend.supports(language) {
            // Skip vendored grammar parser files (generated code, not project source)
            let projectFiles = files.filter { !$0.contains("TreeSitter") }
            guard !projectFiles.isEmpty else { continue }
            // Batch extraction — one parser per language for efficiency.
            // Setup-level errors (unsupportedLanguage, parser setup failures)
            // are logged + skipped here.
            let fileImports: [String: [String]]
            do {
                fileImports = try DependencyExtractor.extractAllImports(
                    files: projectFiles, language: language, projectRoot: projectRoot
                )
            } catch {
                fputs("senkani: dependency extraction skipped for \(language): \(error)\n", stderr)
                continue
            }
            for (relativePath, modules) in fileImports {
                imports[relativePath] = modules
                for module in modules {
                    importedBy[module, default: []].append(relativePath)
                }
            }
        }

        return DependencyGraph(
            imports: imports,
            importedBy: importedBy,
            projectRoot: projectRoot,
            generated: Date()
        )
    }

    /// Compute git blob hashes for files (or fallback to file size).
    private static func computeHashes(files: [String], projectRoot: String) -> [String: String] {
        var hashes: [String: String] = [:]
        for file in files {
            let fullPath = projectRoot + "/" + file
            if let hash = gitBlobHash(fullPath) {
                hashes[file] = hash
            } else if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
                      let size = attrs[.size] as? Int,
                      let mtime = attrs[.modificationDate] as? Date {
                hashes[file] = "\(size)-\(Int(mtime.timeIntervalSince1970))"
            }
        }
        return hashes
    }

    private static func gitBlobHash(_ path: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["hash-object", path]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
