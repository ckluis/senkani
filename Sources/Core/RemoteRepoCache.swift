import Foundation

// MARK: - RemoteRepoCache
//
// In-memory TTL cache for `RemoteRepoClient` responses. Scoped to a
// single MCPSession — evicts on session end. GitHub rate limits
// anonymous requests at 60/hour so caching isn't optional; it's
// required for the tool to be usable.
//
// Not thread-safe on its own — wrapped in an `actor` here so every
// access serializes. Hot path is a Swift Dictionary lookup + time
// compare, well under 1 μs.

public actor RemoteRepoCache {

    public struct Entry: Sendable {
        public let body: String
        public let storedAt: Date
    }

    public let ttl: TimeInterval
    public let maxEntries: Int
    private var entries: [String: Entry] = [:]
    private var insertionOrder: [String] = []

    public init(ttl: TimeInterval = 15 * 60, maxEntries: Int = 128) {
        self.ttl = ttl
        self.maxEntries = maxEntries
    }

    /// Cache key. Caller decides — typically
    /// `"\(action):\(repo):\(path):\(ref ?? ""):\(query ?? "")"`.
    public func get(_ key: String, now: Date = Date()) -> String? {
        guard let entry = entries[key] else { return nil }
        if now.timeIntervalSince(entry.storedAt) > ttl {
            entries[key] = nil
            insertionOrder.removeAll { $0 == key }
            return nil
        }
        return entry.body
    }

    public func put(_ key: String, body: String, now: Date = Date()) {
        if entries[key] == nil {
            insertionOrder.append(key)
        }
        entries[key] = Entry(body: body, storedAt: now)

        // LRU-by-insertion eviction.
        while insertionOrder.count > maxEntries {
            let evicted = insertionOrder.removeFirst()
            entries[evicted] = nil
        }
    }

    public func clear() {
        entries = [:]
        insertionOrder = []
    }

    public func count() -> Int { entries.count }
}
