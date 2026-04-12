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
        var allEntries: [IndexEntry] = []
        var treeSitterCount = 0
        var regexCount = 0
        for (language, files) in walk.byLanguage {
            if TreeSitterBackend.supports(language) {
                let entries = TreeSitterBackend.index(files: files, language: language, projectRoot: projectRoot, treeCache: treeCache)
                allEntries.append(contentsOf: entries)
                treeSitterCount += entries.count
            } else {
                let entries = RegexBackend.index(files: files, language: language, projectRoot: projectRoot)
                allEntries.append(contentsOf: entries)
                regexCount += entries.count
            }
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
            // For simplicity, re-run ctags on the whole project and filter to changed files
            let allEntries = CTagsBackend.index(projectRoot: projectRoot)
            let newEntries = allEntries.filter { changedFiles.contains($0.file) }
            let newHashes = currentHashes.filter { changedFiles.contains($0.key) }
            updated.addSymbols(newEntries, hashes: newHashes)
        } else {
            // Tree-sitter for supported languages, regex for everything else
            var newEntries: [IndexEntry] = []
            for (language, files) in walk.byLanguage {
                let changedInLang = files.filter { changedFiles.contains($0) }
                if !changedInLang.isEmpty {
                    if TreeSitterBackend.supports(language) {
                        let entries = TreeSitterBackend.index(files: changedInLang, language: language, projectRoot: projectRoot, treeCache: treeCache)
                        newEntries.append(contentsOf: entries)
                    } else {
                        let entries = RegexBackend.index(files: changedInLang, language: language, projectRoot: projectRoot)
                        newEntries.append(contentsOf: entries)
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
    public static func indexFileIncremental(
        relativePath: String,
        projectRoot: String,
        treeCache: TreeCache
    ) -> [IndexEntry] {
        let fullPath = projectRoot + "/" + relativePath
        guard let newContent = try? String(contentsOfFile: fullPath, encoding: .utf8) else { return [] }
        let newHash = TreeCache.hash(newContent)

        // Determine language from file extension
        let ext = (relativePath as NSString).pathExtension
        guard let language = FileWalker.languageMap[ext],
              TreeSitterBackend.supports(language) else { return [] }

        // Check cache
        if let cached = treeCache.lookup(file: relativePath) {
            if cached.contentHash == newHash {
                // Unchanged — extract symbols from cached tree
                guard let root = cached.tree.rootNode else { return [] }
                return TreeSitterBackend.extractSymbols(from: root, source: newContent, language: language, file: relativePath)
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
                return TreeSitterBackend.extractSymbols(from: root, source: newContent, language: language, file: relativePath)
            }
        }

        // No cache or incremental parse failed — full parse
        guard let tsLanguage = TreeSitterBackend.language(for: language) else { return [] }
        let parser = Parser()
        do { try parser.setLanguage(tsLanguage) } catch { return [] }
        guard let tree = parser.parse(newContent) else { return [] }

        treeCache.store(file: relativePath, tree: tree, content: newContent, contentHash: newHash, language: language)
        guard let root = tree.rootNode else { return [] }
        return TreeSitterBackend.extractSymbols(from: root, source: newContent, language: language, file: relativePath)
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
            // Batch extraction — one parser per language for efficiency
            let fileImports = DependencyExtractor.extractAllImports(
                files: projectFiles, language: language, projectRoot: projectRoot
            )
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
