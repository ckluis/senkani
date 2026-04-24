import Foundation

/// Processing mode that affects the stored content in `ReadCache`.
/// Two entries for the same file+mtime with different modes are NOT
/// interchangeable — serving a `secrets=false` entry to a `secrets=true`
/// caller would leak previously-unredacted content after the caller
/// enabled redaction. The mode is part of the cache key.
struct ReadProcessingMode: Hashable, Sendable {
    let filter: Bool
    let secrets: Bool
    let terse: Bool

    /// Compact string representation used in the cache key.
    var tag: String {
        "f\(filter ? 1 : 0)s\(secrets ? 1 : 0)t\(terse ? 1 : 0)"
    }
}

/// LRU file read cache. Keyed by absolute path + file modification time +
/// processing mode. Thread-safe via NSLock — safe for concurrent access
/// from multiple connections.
// TODO: Phase 5 — For multi-project socket server, consider whether a single
// shared cache is appropriate or if per-project-root partitioning is needed
// to prevent one project's cache from evicting another's entries.
final class ReadCache: @unchecked Sendable {
    struct Entry {
        let path: String
        let mtime: Date
        let mode: ReadProcessingMode
        let content: String
        let rawBytes: Int
        let compressedBytes: Int
        var lastAccess: Date
    }

    private var entries: [String: Entry] = [:]
    private var pinnedPaths: Set<String> = []
    private let lock = NSLock()
    private let maxEntries = 500
    private let maxBytes = 50_000_000  // 50MB

    private var hits = 0
    private var misses = 0

    /// Compose the storage key from path + mode. Stable across versions.
    private static func key(path: String, mode: ReadProcessingMode) -> String {
        path + "\0" + mode.tag
    }

    /// Thread-safe hit rate. Acquires lock to read counters.
    var hitRate: Double {
        lock.lock()
        let h = hits
        let m = misses
        lock.unlock()
        let total = h + m
        guard total > 0 else { return 0 }
        return Double(h) / Double(total)
    }

    var totalCachedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return cachedBytesUnsafe
    }

    /// Unsafe: only call while lock is already held.
    private var cachedBytesUnsafe: Int {
        entries.values.reduce(0) { $0 + $1.compressedBytes }
    }

    /// Mode-aware lookup. Returns nil if no entry exists for the given
    /// (path, mode) pair — even if a different-mode entry for the same
    /// path is present. Entries for any mode are purged when the file's
    /// mtime no longer matches, because a stale entry is stale regardless
    /// of mode.
    func lookup(path: String, mode: ReadProcessingMode) -> Entry? {
        lock.lock()
        defer { lock.unlock() }

        let k = Self.key(path: path, mode: mode)
        guard var entry = entries[k] else {
            misses += 1
            return nil
        }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let currentMtime = attrs[.modificationDate] as? Date,
              currentMtime == entry.mtime else {
            // Purge every mode-variant for this path — the file on disk
            // changed, so none of the cached outputs reflect reality anymore.
            for key in entries.keys where key.hasPrefix(path + "\0") {
                entries.removeValue(forKey: key)
            }
            misses += 1
            return nil
        }

        entry.lastAccess = Date()
        entries[k] = entry
        hits += 1
        return entry
    }

    func store(path: String, mtime: Date, mode: ReadProcessingMode, content: String, rawBytes: Int) {
        let compressedBytes = content.utf8.count
        let entry = Entry(
            path: path, mtime: mtime, mode: mode, content: content,
            rawBytes: rawBytes, compressedBytes: compressedBytes,
            lastAccess: Date()
        )

        lock.lock()
        let k = Self.key(path: path, mode: mode)
        entries[k] = entry
        evictIfNeeded()
        lock.unlock()
    }

    /// Pin by path so every mode-variant for that path survives LRU eviction.
    func pin(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        pinnedPaths.insert(path)
    }

    /// Is any entry for `path` (any mode) pinned? Used by the eviction loop.
    private func isPinned(key: String) -> Bool {
        guard let nul = key.firstIndex(of: "\0") else {
            return pinnedPaths.contains(key)
        }
        let p = String(key[..<nul])
        return pinnedPaths.contains(p)
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        pinnedPaths.removeAll()
        hits = 0
        misses = 0
        lock.unlock()
    }

    /// Only called while lock is held. Uses cachedBytesUnsafe (no re-lock).
    /// Pinned paths (L0) are excluded from eviction candidates — every
    /// mode-variant of a pinned path survives LRU.
    private func evictIfNeeded() {
        while entries.count > maxEntries {
            if let oldest = entries
                .filter({ !isPinned(key: $0.key) })
                .min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
                entries.removeValue(forKey: oldest.key)
            } else { break }
        }
        while cachedBytesUnsafe > maxBytes && !entries.isEmpty {
            if let oldest = entries
                .filter({ !isPinned(key: $0.key) })
                .min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
                entries.removeValue(forKey: oldest.key)
            } else { break }
        }
    }
}
