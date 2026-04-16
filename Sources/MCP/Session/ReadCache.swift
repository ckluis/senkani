import Foundation

/// LRU file read cache. Keyed by absolute path + file modification time.
/// Thread-safe via NSLock — safe for concurrent access from multiple connections.
// TODO: Phase 5 — For multi-project socket server, consider whether a single
// shared cache is appropriate or if per-project-root partitioning is needed
// to prevent one project's cache from evicting another's entries.
final class ReadCache: @unchecked Sendable {
    struct Entry {
        let path: String
        let mtime: Date
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

    func lookup(path: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }

        guard var entry = entries[path] else {
            misses += 1
            return nil
        }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let currentMtime = attrs[.modificationDate] as? Date,
              currentMtime == entry.mtime else {
            entries.removeValue(forKey: path)
            misses += 1
            return nil
        }

        entry.lastAccess = Date()
        entries[path] = entry
        hits += 1
        return entry
    }

    func store(path: String, mtime: Date, content: String, rawBytes: Int) {
        let compressedBytes = content.utf8.count
        let entry = Entry(
            path: path, mtime: mtime, content: content,
            rawBytes: rawBytes, compressedBytes: compressedBytes,
            lastAccess: Date()
        )

        lock.lock()
        entries[path] = entry
        evictIfNeeded()
        lock.unlock()
    }

    func pin(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        pinnedPaths.insert(path)
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
    /// Pinned entries (L0) are excluded from eviction candidates.
    private func evictIfNeeded() {
        while entries.count > maxEntries {
            if let oldest = entries
                .filter({ !pinnedPaths.contains($0.key) })
                .min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
                entries.removeValue(forKey: oldest.key)
            } else { break }
        }
        while cachedBytesUnsafe > maxBytes && !entries.isEmpty {
            if let oldest = entries
                .filter({ !pinnedPaths.contains($0.key) })
                .min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
                entries.removeValue(forKey: oldest.key)
            } else { break }
        }
    }
}
