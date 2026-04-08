import Foundation

/// Orchestrates symbol indexing across multiple backends.
/// Tries sourcekit-lsp first, then ctags, then regex.
public enum IndexEngine {
    /// Index an entire project, using the best available backend.
    public static func index(projectRoot: String) -> SymbolIndex {
        let walk = FileWalker.walk(projectRoot: projectRoot)
        var idx = SymbolIndex()
        idx.projectRoot = projectRoot
        idx.generated = Date()

        // Determine available backends
        _ = CTagsBackend.isAvailable()
        let usedEngine: String

        // Use regex for all languages (most reliable, always available).
        // ctags can be added as a preference later once Swift support is verified.
        var allEntries: [IndexEntry] = []
        for (language, files) in walk.byLanguage {
            let entries = RegexBackend.index(files: files, language: language, projectRoot: projectRoot)
            allEntries.append(contentsOf: entries)
        }
        idx.symbols = allEntries
        usedEngine = "regex"
        fputs("senkani: indexed \(allEntries.count) symbols via regex (\(walk.byLanguage.count) languages)\n", stderr)

        idx.engine = usedEngine

        // Compute file hashes for incremental updates
        idx.fileHashes = computeHashes(files: walk.files, projectRoot: projectRoot)

        return idx
    }

    /// Incrementally update an existing index, re-indexing only changed files.
    public static func incrementalUpdate(existing: SymbolIndex, projectRoot: String) -> SymbolIndex {
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
            // Regex on changed files, grouped by language
            var newEntries: [IndexEntry] = []
            for (language, files) in walk.byLanguage {
                let changedInLang = files.filter { changedFiles.contains($0) }
                if !changedInLang.isEmpty {
                    let entries = RegexBackend.index(files: changedInLang, language: language, projectRoot: projectRoot)
                    newEntries.append(contentsOf: entries)
                }
            }
            let newHashes = currentHashes.filter { changedFiles.contains($0.key) }
            updated.addSymbols(newEntries, hashes: newHashes)
        }

        updated.generated = Date()
        return updated
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
