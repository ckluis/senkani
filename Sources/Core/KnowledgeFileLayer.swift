import Foundation
import CoreServices

// MARK: - Errors

public enum KBError: Error, Sendable {
    case directoryCreationFailed(String)
    case fileReadFailed(String)
    case fileWriteFailed(String)
    case parseError(String)
    case pathTraversal(String)
    case invalidEntityName(String)
    case noStagedFile(String)
    case historyNotFound(String, Date)
}

// MARK: - KnowledgeFileLayer

/// FS coordination layer for `.senkani/knowledge/*.md` files.
/// Reads/writes/watches the knowledge directory and syncs parsed content into KnowledgeStore.
/// All public methods are thread-safe (serialized through `queue`).
public final class KnowledgeFileLayer: @unchecked Sendable {

    public let knowledgeDir: String   // <root>/.senkani/knowledge
    public let stagedDir:    String   // <root>/.senkani/knowledge/.staged
    public let historyDir:   String   // <root>/.senkani/knowledge/.history

    private let queue = DispatchQueue(label: "com.senkani.kbfiles", qos: .utility)
    private let store: KnowledgeStore
    private let fm = FileManager.default

    // FSEvents state — protected by watchLock
    private let watchLock = NSLock()
    private var watchStream: FSEventStreamRef?
    private var watchQueue: DispatchQueue?
    private var pendingChanges: Set<String> = []
    private var debounceWork: DispatchWorkItem?
    private var onChangeHandler: (([String]) -> Void)?

    // MARK: Init

    public init(projectRoot: String, store: KnowledgeStore) throws {
        self.store = store
        let base = projectRoot + "/.senkani/knowledge"
        knowledgeDir = base
        stagedDir    = base + "/.staged"
        historyDir   = base + "/.history"

        for dir in [knowledgeDir, stagedDir, historyDir] {
            do {
                try FileManager.default.createDirectory(
                    atPath: dir, withIntermediateDirectories: true, attributes: nil)
            } catch {
                throw KBError.directoryCreationFailed(dir)
            }
        }
    }

    deinit { stopWatching() }

    // MARK: Read / Write

    public func allMarkdownFiles() -> [URL] {
        queue.sync {
            let base = URL(fileURLWithPath: knowledgeDir)
            guard let enumerator = fm.enumerator(
                at: base,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }

            var results: [URL] = []
            for case let url as URL in enumerator {
                guard url.pathExtension == "md" else { continue }
                // Skip .staged/ and .history/ subdirectories
                let p = url.path
                if p.contains("/.staged/") || p.contains("/.history/") { continue }
                results.append(url)
            }
            return results
        }
    }

    /// Read and parse an entity from its canonical .md file.
    /// Returns the parsed KBContent and the SHA-256 content hash.
    public func readEntity(name: String) throws -> (content: KBContent, hash: String) {
        try validateEntityName(name)
        let url = liveURL(for: name)
        return try queue.sync {
            guard fm.fileExists(atPath: url.path) else {
                throw KBError.fileReadFailed(url.path)
            }
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch { throw KBError.fileReadFailed(url.path) }

            guard data.count <= 1_048_576 else {
                throw KBError.parseError("\(name): file exceeds 1MB limit")
            }

            let raw = String(decoding: data, as: UTF8.self)
            guard let content = KnowledgeParser.parse(raw) else {
                throw KBError.parseError(name)
            }
            let hash = KnowledgeParser.sha256(data)
            return (content, hash)
        }
    }

    /// Write (or overwrite) an entity's live .md file atomically.
    /// Syncs to KnowledgeStore after writing.
    public func writeEntity(name: String, content: KBContent) throws {
        try validateEntityName(name)
        let url = liveURL(for: name)
        let markdown = KnowledgeParser.serialize(content, entityName: name)
        try queue.sync {
            try atomicWrite(markdown, to: url)
        }
        syncEntityToStore(name: name)
    }

    // MARK: Staging Lifecycle

    /// Stage a proposal for an entity. Returns the URL of the staged file.
    @discardableResult
    public func stageProposal(for entityName: String, content: String) throws -> URL {
        try validateEntityName(entityName)
        let url = stagedURL(for: entityName)
        try queue.sync {
            try atomicWrite(content, to: url)
        }
        return url
    }

    /// Commit the staged proposal for an entity:
    ///   1. Archive current live file to .history/<name>/<timestamp>.md
    ///   2. Prune history to 10 most recent entries
    ///   3. Move staged → live (atomic)
    ///   4. Sync to KnowledgeStore
    public func commitProposal(for entityName: String) throws {
        try validateEntityName(entityName)
        let staged = stagedURL(for: entityName)
        let live   = liveURL(for: entityName)

        try queue.sync {
            guard fm.fileExists(atPath: staged.path) else {
                throw KBError.noStagedFile(entityName)
            }

            // Archive current live version (if it exists)
            if fm.fileExists(atPath: live.path) {
                let archiveDir = historyURL(for: entityName)
                try fm.createDirectory(atPath: archiveDir.path,
                                       withIntermediateDirectories: true)
                let ts = KnowledgeParser.isoFull.string(from: Date())
                    .replacingOccurrences(of: ":", with: "-") // colon-safe for filenames
                // Guard against same-second collisions (e.g. rapid commits in tests)
                var archiveFile = archiveDir.appendingPathComponent("\(ts).md")
                var collisionIdx = 0
                while fm.fileExists(atPath: archiveFile.path) {
                    collisionIdx += 1
                    archiveFile = archiveDir.appendingPathComponent("\(ts)-\(collisionIdx).md")
                }
                try fm.copyItem(at: live, to: archiveFile)
                pruneHistory(entityName: entityName, keepLast: 10)
            }

            // Atomic move: staged → live
            let stagedData: Data
            do { stagedData = try Data(contentsOf: staged) }
            catch { throw KBError.fileReadFailed(staged.path) }

            let stagedStr = String(decoding: stagedData, as: UTF8.self)
            try atomicWrite(stagedStr, to: live)
            try? fm.removeItem(at: staged)
        }

        syncEntityToStore(name: entityName)
    }

    /// Read the staged proposal markdown for an entity. Returns nil if no staged file exists.
    public func readStagedProposal(for entityName: String) -> String? {
        do { try validateEntityName(entityName) } catch { return nil }
        let url = stagedURL(for: entityName)
        return queue.sync {
            guard fm.fileExists(atPath: url.path) else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }

    /// Discard the staged proposal for an entity. No-op if no staged file exists.
    public func discardStagedProposal(for entityName: String) throws {
        try validateEntityName(entityName)
        let url = stagedURL(for: entityName)
        try queue.sync {
            guard fm.fileExists(atPath: url.path) else { return }
            try fm.removeItem(at: url)
        }
    }

    /// Roll back an entity's live file to the history version closest to `date`.
    public func rollback(entityName: String, to date: Date) throws {
        try validateEntityName(entityName)
        let archiveDir = historyURL(for: entityName)
        let live = liveURL(for: entityName)

        try queue.sync {
            guard fm.fileExists(atPath: archiveDir.path) else {
                throw KBError.historyNotFound(entityName, date)
            }
            let files = (try? fm.contentsOfDirectory(atPath: archiveDir.path)) ?? []
            let mdFiles = files.filter { $0.hasSuffix(".md") }.sorted()
            guard !mdFiles.isEmpty else { throw KBError.historyNotFound(entityName, date) }

            // Find the file whose timestamp is closest to and ≤ the requested date
            // Filename format: "YYYY-MM-DDTHH-MM-SSZ.md" (colons replaced with dashes)
            var best: String? = nil
            var bestDiff: TimeInterval = .infinity
            for fname in mdFiles {
                // Filename format: "YYYY-MM-DDTHH-MM-SSZ.md" (colons in time replaced with -)
                // Restore colons at positions 13 and 16 of the stem to get ISO8601.
                var stem = String(fname.dropLast(3)) // drop ".md"
                if stem.count >= 20 {
                    var chars = Array(stem)
                    if chars[13] == "-" { chars[13] = ":" }
                    if chars[16] == "-" { chars[16] = ":" }
                    stem = String(chars)
                }
                guard let fileDate = KnowledgeParser.isoFull.date(from: stem) else { continue }
                let diff = abs(fileDate.timeIntervalSince(date))
                if diff < bestDiff {
                    bestDiff = diff
                    best = fname
                }
            }
            guard let chosen = best else { throw KBError.historyNotFound(entityName, date) }

            let src = archiveDir.appendingPathComponent(chosen)
            let data: Data
            do { data = try Data(contentsOf: src) }
            catch { throw KBError.fileReadFailed(src.path) }
            let content = String(decoding: data, as: UTF8.self)
            try atomicWrite(content, to: live)
        }

        syncEntityToStore(name: entityName)
    }

    // MARK: Watching

    /// Start FSEvents watching on the knowledge directory.
    /// `onChange` is called on the watcher's dispatch queue with absolute paths of changed .md files.
    public func startWatching(onChange: @escaping ([String]) -> Void) {
        watchLock.lock()
        defer { watchLock.unlock() }
        guard watchStream == nil else { return }

        onChangeHandler = onChange
        let wq = DispatchQueue(label: "com.senkani.kbwatcher", qos: .utility)
        watchQueue = wq

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagNoDefer
        )

        // Resolve symlinks for consistent path prefix matching
        let watchPath: String
        if let resolved = realpath(knowledgeDir, nil) {
            watchPath = String(cString: resolved)
            free(resolved)
        } else {
            watchPath = knowledgeDir
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (_, info, numEvents, eventPaths, eventFlags, _) in
                guard let info else { return }
                let layer = Unmanaged<KnowledgeFileLayer>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as! [String]
                let flagsArr = Array(UnsafeBufferPointer(start: eventFlags, count: numEvents))
                layer.handleWatchEvents(paths: paths, flags: flagsArr)
            },
            &context,
            [watchPath] as CFArray,
            UInt64(kFSEventStreamEventIdSinceNow),
            0.05,
            flags
        ) else {
            fputs("[KnowledgeFileLayer] FSEventStreamCreate failed\n", stderr)
            return
        }

        FSEventStreamSetDispatchQueue(stream, wq)
        FSEventStreamStart(stream)
        watchStream = stream
    }

    public func stopWatching() {
        watchLock.lock()
        defer { watchLock.unlock() }
        guard let stream = watchStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        watchStream = nil
        debounceWork?.cancel()
        debounceWork = nil
        pendingChanges.removeAll()
        onChangeHandler = nil
    }

    // MARK: Template

    public static func template(for entityType: String, name: String,
                                 sourcePath: String? = nil) -> String {
        let fm = KBFrontmatter(entityType: entityType, sourcePath: sourcePath)
        let content = KBContent(frontmatter: fm, entityName: name)
        return KnowledgeParser.serialize(content, entityName: name)
    }

    // MARK: Bulk Sync

    /// Populate KnowledgeStore from all live .md files. Call once at startup.
    public func syncAllToStore() throws {
        let files = allMarkdownFiles()
        for url in files {
            let name = url.deletingPathExtension().lastPathComponent
            syncEntityToStore(name: name)
        }
    }

    // MARK: Private — Path Helpers

    private func liveURL(for name: String) -> URL {
        URL(fileURLWithPath: knowledgeDir).appendingPathComponent(name + ".md")
    }

    private func stagedURL(for name: String) -> URL {
        URL(fileURLWithPath: stagedDir).appendingPathComponent(name + ".md")
    }

    private func historyURL(for name: String) -> URL {
        URL(fileURLWithPath: historyDir).appendingPathComponent(name)
    }

    private func validateEntityName(_ name: String) throws {
        guard !name.isEmpty, name.count <= 200,
              !name.contains("/"), !name.contains("\0") else {
            throw KBError.invalidEntityName(name)
        }
        // Confirm resolved path stays within knowledgeDir (path traversal prevention)
        let resolved = URL(fileURLWithPath: knowledgeDir)
            .appendingPathComponent(name + ".md")
            .standardizedFileURL.path
        guard resolved.hasPrefix(
            URL(fileURLWithPath: knowledgeDir).standardizedFileURL.path
        ) else {
            throw KBError.pathTraversal(name)
        }
    }

    // MARK: Private — Atomic Write

    private func atomicWrite(_ content: String, to url: URL) throws {
        let data = Data(content.utf8)
        let dir  = url.deletingLastPathComponent()
        let tmp  = dir.appendingPathComponent(
            ".\(url.lastPathComponent).tmp.\(ProcessInfo.processInfo.processIdentifier)"
        )
        do { try data.write(to: tmp) }
        catch { throw KBError.fileWriteFailed(url.path) }

        do {
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw KBError.fileWriteFailed(url.path)
        }
    }

    // MARK: Private — History Pruning

    /// Keep only the `keepLast` most recent history files; delete older ones.
    private func pruneHistory(entityName: String, keepLast: Int = 10) {
        let dir = historyURL(for: entityName)
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let sorted = files.filter { $0.hasSuffix(".md") }.sorted() // ISO8601 sorts lexicographically
        let toDelete = sorted.dropLast(keepLast)
        for f in toDelete {
            try? fm.removeItem(at: dir.appendingPathComponent(f))
        }
    }

    // MARK: Private — DB Sync

    // NOTE: Must be called from the CALLER's thread, never from within a queue.sync/async block.
    // readEntity internally dispatches queue.sync — calling this from within the queue deadlocks.
    private func syncEntityToStore(name: String) {
        guard let (content, hash) = try? readEntity(name: name) else { return }

        let relPath = ".senkani/knowledge/\(name).md"
        let entity = content.toKnowledgeEntity(
            name: name, markdownPath: relPath, contentHash: hash
        )
        // Phase V.5 — markdown-vault sync writes have unknown
        // provenance (the file on disk could have been edited by an
        // agent or by the operator). Round 1 lands these rows as
        // `.unset` so the V.5b prompt path can resolve them on next
        // operator interaction. We do NOT silently call them human-
        // or AI-authored — that's the Gebru red flag.
        let entityId = store.upsertEntity(
            entity,
            authorship: AuthorshipTracker.tagForUnknownProvenance()
        )
        guard entityId > 0 else { return }

        // Replace all links (re-parsed on every sync)
        store.deleteLinks(forEntityId: entityId)
        for rel in content.relations {
            store.insertLink(EntityLink(
                sourceId: entityId,
                targetName: rel.targetName,
                relation: rel.relationType,
                lineNumber: rel.lineNumber
            ))
        }
        store.resolveLinks()

        // Insert decisions (INSERT OR IGNORE deduplicates by commit hash or content)
        for dec in content.decisions {
            store.insertDecision(DecisionRecord(
                entityId: entityId,
                entityName: name,
                decision: dec.decision,
                rationale: dec.rationale ?? "",
                source: "annotation"
            ))
        }
    }

    // MARK: Private — FSEvents Handler

    private func handleWatchEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        watchLock.lock()
        defer { watchLock.unlock() }

        for (i, path) in paths.enumerated() {
            let flag = flags[i]
            // Skip directory events
            if flag & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 { continue }
            // Only .md files not in .staged/ or .history/
            guard path.hasSuffix(".md"),
                  !path.contains("/.staged/"),
                  !path.contains("/.history/") else { continue }
            pendingChanges.insert(path)
        }

        guard !pendingChanges.isEmpty else { return }
        scheduleDebouncedFlush()
    }

    private func scheduleDebouncedFlush() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.flushWatchPending()
        }
        debounceWork = work
        (watchQueue ?? .global()).asyncAfter(deadline: .now() + 0.150, execute: work)
    }

    private func flushWatchPending() {
        watchLock.lock()
        let changes = Array(pendingChanges)
        pendingChanges.removeAll()
        debounceWork = nil
        let handler = onChangeHandler
        watchLock.unlock()

        guard !changes.isEmpty, let handler else { return }
        handler(changes)
    }
}

// MARK: - KBContent DB Conversion

extension KBContent {
    func toKnowledgeEntity(name: String, markdownPath: String, contentHash: String) -> KnowledgeEntity {
        KnowledgeEntity(
            name: name,
            entityType: frontmatter.entityType,
            sourcePath: frontmatter.sourcePath,
            markdownPath: markdownPath,
            contentHash: contentHash,
            compiledUnderstanding: compiledUnderstanding,
            lastEnriched: frontmatter.lastEnriched,
            mentionCount: frontmatter.mentionCount
        )
    }
}
