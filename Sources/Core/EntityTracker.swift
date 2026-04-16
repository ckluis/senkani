import Foundation

// MARK: - Config

public struct EntityTrackerConfig: Sendable, Equatable {
    /// Auto-flush to KnowledgeStore every N observations. Default 15.
    public let flushIntervalCalls: Int
    /// Enrichment candidate threshold — entity must reach this many session mentions. Default 5.
    public let mentionThreshold: Int
    /// Maximum bytes of text scanned per observe() call. Prevents regex DoS. Default 4096.
    public let maxObservationBytes: Int

    public static let `default` = EntityTrackerConfig()

    public init(flushIntervalCalls: Int = 15, mentionThreshold: Int = 5,
                maxObservationBytes: Int = 4096) {
        self.flushIntervalCalls  = max(1,   min(200,   flushIntervalCalls))
        self.mentionThreshold    = max(1,   min(50,    mentionThreshold))
        self.maxObservationBytes = max(512, min(65536, maxObservationBytes))
    }
}

// MARK: - EntityTracker

/// Watches tool-call text for entity name mentions and flushes counts to KnowledgeStore.
///
/// Thread-safety: final class @unchecked Sendable + NSLock.
/// NOT an actor — observe() must be synchronous (called from the synchronous hook handler).
///
/// Hot path performance:
///   1. Lock → copy pattern ref → unlock                [<1μs]
///   2. NSRegularExpression.matches(in:) — NO LOCK      [~50μs for 4KB / 100 entities]
///   3. Lock → increment counters → unlock              [<1μs]
///
/// NSRegularExpression is thread-safe for concurrent reads — established by InjectionGuard,
/// SecretDetector, and KnowledgeParser throughout this codebase.
public final class EntityTracker: @unchecked Sendable {

    public let config: EntityTrackerConfig
    private let store: KnowledgeStore
    private let lock = NSLock()

    // Entity registry — rebuilt by reloadEntities(). Protected by lock.
    private var knownNames: [String] = []
    private var matchPattern: NSRegularExpression?

    // In-memory counts — protected by lock
    private var pendingDelta:   [String: Int] = [:]  // since last flush
    private var sessionTotal:   [String: Int] = [:]  // cumulative this session
    private var alreadyTriggered: Set<String> = []   // threshold fired — don't re-fire
    private var enrichmentQueue:  Set<String> = []   // ready for F.7 to consume
    private var callsSinceFlush: Int = 0

    // MARK: Init

    public init(store: KnowledgeStore, config: EntityTrackerConfig = .default) {
        self.store = store
        self.config = config
        reloadEntities()
    }

    // MARK: Core API

    /// Observe text for entity mentions. Returns detected entity names.
    /// Auto-flushes when callsSinceFlush reaches config.flushIntervalCalls.
    /// Safe to call from any thread concurrently.
    @discardableResult
    public func observe(text: String, source: String = "hook") -> Set<String> {
        // 1. Cap text to maxObservationBytes (UTF-8 boundary-safe)
        let prefix: String
        if text.utf8.count <= config.maxObservationBytes {
            prefix = text
        } else {
            var data = Data(text.utf8.prefix(config.maxObservationBytes))
            // Walk back to a valid UTF-8 boundary (any codepoint is at most 4 bytes)
            var trimSteps = 0
            while !data.isEmpty && trimSteps < 4 {
                if String(data: data, encoding: .utf8) != nil { break }
                data.removeLast()
                trimSteps += 1
            }
            prefix = String(data: data, encoding: .utf8) ?? ""
        }
        guard !prefix.isEmpty else { return [] }

        // 2. Grab pattern ref under lock, then release before matching
        lock.lock()
        let pat = matchPattern
        lock.unlock()

        guard let pattern = pat else { return [] }

        // 3. Regex match WITHOUT the lock — NSRegularExpression is thread-safe for reads
        let ns = prefix as NSString
        let matches = pattern.matches(in: prefix, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }

        var detected: Set<String> = []
        for m in matches {
            let nameRange = m.range(at: 1)
            guard nameRange.location != NSNotFound else { continue }
            detected.insert(ns.substring(with: nameRange))
        }

        // 4. Update counters under lock
        var shouldFlush = false
        lock.lock()
        for name in detected {
            pendingDelta[name, default: 0] += 1
            sessionTotal[name, default: 0] += 1
            if sessionTotal[name]! >= config.mentionThreshold
               && !alreadyTriggered.contains(name) {
                alreadyTriggered.insert(name)
                enrichmentQueue.insert(name)
            }
        }
        callsSinceFlush += 1
        shouldFlush = callsSinceFlush >= config.flushIntervalCalls
        lock.unlock()

        // 5. Auto-flush outside the lock (avoids holding lock during DB write)
        if shouldFlush { flush() }

        return detected
    }

    /// Flush pending mention deltas to KnowledgeStore (async DB write).
    /// Resets callsSinceFlush. Safe to call from any thread.
    public func flush() {
        lock.lock()
        guard !pendingDelta.isEmpty else {
            callsSinceFlush = 0
            lock.unlock()
            return
        }
        let delta = pendingDelta
        pendingDelta = [:]
        callsSinceFlush = 0
        lock.unlock()

        store.batchIncrementMentions(delta)
    }

    /// Reset all in-memory session state.
    /// Call at session start — complements KnowledgeStore.resetSessionMentions().
    public func resetSession() {
        lock.lock()
        pendingDelta       = [:]
        sessionTotal       = [:]
        alreadyTriggered   = []
        enrichmentQueue    = []
        callsSinceFlush    = 0
        lock.unlock()
    }

    /// Reload entity registry from KnowledgeStore and rebuild the compiled regex pattern.
    /// Call after new entities are added to the KB (e.g., after KnowledgeFileLayer.commitProposal).
    public func reloadEntities() {
        let entities = store.allEntities()
        let names = entities.map(\.name)

        let newPattern: NSRegularExpression?
        if names.isEmpty {
            newPattern = nil
        } else {
            // Sort by length descending — longer entity names take priority in alternation
            let sorted = names.sorted { $0.count > $1.count }
            // Escape all names — defense in depth against regex metacharacters in entity names
            let escaped = sorted.map { NSRegularExpression.escapedPattern(for: $0) }
            // \b anchors ensure "Session" doesn't match inside "SessionDatabase"
            let patternStr = "\\b(" + escaped.joined(separator: "|") + ")\\b"
            newPattern = try? NSRegularExpression(pattern: patternStr, options: [])
        }

        lock.lock()
        knownNames = names
        matchPattern = newPattern
        lock.unlock()
    }

    /// Drain and return entities that crossed the mention threshold this session.
    /// Idempotent per threshold crossing — alreadyTriggered prevents re-firing.
    public func consumeEnrichmentCandidates() -> Set<String> {
        lock.lock()
        let candidates = enrichmentQueue
        enrichmentQueue = []
        lock.unlock()
        return candidates
    }

    // MARK: Debug / Testing

    public struct State: Sendable {
        public let entityCount: Int
        public let pendingDelta: [String: Int]
        public let sessionTotal: [String: Int]
        public let enrichmentCandidates: Set<String>
        public let callsSinceFlush: Int
    }

    /// Snapshot of current in-memory state. For debugging and tests.
    public func state() -> State {
        lock.lock()
        defer { lock.unlock() }
        return State(
            entityCount:          knownNames.count,
            pendingDelta:         pendingDelta,
            sessionTotal:         sessionTotal,
            enrichmentCandidates: enrichmentQueue,
            callsSinceFlush:      callsSinceFlush
        )
    }
}
