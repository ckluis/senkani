import Foundation

/// A single pinned context entry — compressed outline of a named entity
/// prepended to subsequent tool call results until TTL expires.
public struct PinnedEntry: Sendable {
    public let name: String
    /// Compressed outline, ≤320 chars (~80 tokens). Truncated at storage time.
    public let outline: String
    public let pinnedAt: Date
    /// Decremented on each drain; entry evicted when it reaches 0.
    public internal(set) var callsRemaining: Int
    /// TTL at pin time (for display in the status block).
    public let maxCalls: Int

    public init(name: String, outline: String, ttl: Int = PinnedContextStore.defaultTTL) {
        let clampedTTL = max(PinnedContextStore.minTTL, min(PinnedContextStore.maxTTL, ttl))
        self.name = name
        self.outline = String(outline.prefix(PinnedContextStore.maxEntryChars))
        self.pinnedAt = Date()
        self.callsRemaining = clampedTTL
        self.maxCalls = clampedTTL
    }
}

/// Thread-safe in-process store for @-mention pinned context entries.
///
/// Mirrors the `staleNotices: [String]` + drain pattern in MCPSession.
///
/// Hard limits (Carmack/Jobs synthesis — not configurable):
/// - Max 5 simultaneous pinned entries (oldest evicted when full)
/// - Max 1600 chars (~400 tokens) total prepended per tool call
/// - Max 320 chars (~80 tokens) per entry — truncated at storage time
/// - TTL 1–50 tool calls, default 20
public final class PinnedContextStore: @unchecked Sendable {
    public static let maxEntries    = 5
    public static let maxTotalChars = 1600   // ~400 tokens across all entries
    public static let maxEntryChars = 320    // ~80 tokens per entry
    public static let defaultTTL    = 20
    public static let maxTTL        = 50
    public static let minTTL        = 1

    private var entries: [String: PinnedEntry] = [:]   // name → entry, upsert semantics
    private let lock = NSLock()

    public init() {}

    /// Pin an entity. Upserts by name — resets TTL if already pinned.
    /// Evicts the oldest entry when at capacity (maxEntries).
    @discardableResult
    public func pin(_ entry: PinnedEntry) -> PinnedEntry {
        lock.lock()
        defer { lock.unlock() }
        entries[entry.name] = entry
        if entries.count > Self.maxEntries {
            let evictCount = entries.count - Self.maxEntries
            let oldest = entries.values
                .sorted { $0.pinnedAt < $1.pinnedAt }
                .prefix(evictCount)
            for e in oldest { entries.removeValue(forKey: e.name) }
        }
        return entries[entry.name]!
    }

    /// Remove a pinned entry by name (case-insensitive).
    public func unpin(name: String) {
        lock.lock()
        defer { lock.unlock() }
        let key = entries.keys.first {
            $0.caseInsensitiveCompare(name) == .orderedSame
        } ?? name
        entries.removeValue(forKey: key)
    }

    /// Snapshot of all current pinned entries, oldest first.
    public func all() -> [PinnedEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.sorted { $0.pinnedAt < $1.pinnedAt }
    }

    /// True when no entries are pinned.
    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.isEmpty
    }

    /// Drain pinned context for prepending to a tool call result.
    ///
    /// For each entry: decrement callsRemaining; expire at zero.
    /// Returns:
    ///   - `context`: formatted block ≤1600 chars, or nil if nothing active
    ///   - `expiryNotices`: one-line notices for entries that just expired
    public func drain() -> (context: String?, expiryNotices: [String]) {
        lock.lock()
        defer { lock.unlock() }
        guard !entries.isEmpty else { return (nil, []) }

        var contextBlocks: [String] = []
        var expiredNames:  [String] = []
        var totalChars = 0

        // Process in pin order (oldest first) for stable output
        let sortedKeys = entries.keys.sorted {
            entries[$0]!.pinnedAt < entries[$1]!.pinnedAt
        }
        for name in sortedKeys {
            guard var entry = entries[name] else { continue }
            entry.callsRemaining -= 1
            if entry.callsRemaining <= 0 {
                expiredNames.append(entry.name)
                entries.removeValue(forKey: name)
            } else {
                entries[name] = entry
                let block = formatBlock(entry)
                if totalChars + block.count <= Self.maxTotalChars {
                    contextBlocks.append(block)
                    totalChars += block.count
                }
            }
        }

        let context: String? = contextBlocks.isEmpty ? nil
            : contextBlocks.joined(separator: "\n")
        let expiry = expiredNames.map {
            "[pin expired: \($0) — re-pin: senkani_session action='pin' name='\($0)']"
        }
        return (context, expiry)
    }

    // MARK: - Private

    private func formatBlock(_ entry: PinnedEntry) -> String {
        "--- @\(entry.name) (\(entry.callsRemaining) calls remaining) ---\n\(entry.outline)\n---"
    }
}
