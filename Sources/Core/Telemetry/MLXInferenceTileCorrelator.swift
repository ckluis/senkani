import Foundation

/// V.19a-4 — pure-Swift correlator that drives the Models/Inference
/// dashboard tile.
///
/// Joins `cache_lifecycle` spans (V.19a-3's
/// `CacheLifecycleSpanRecorder`-emitted `runtime_telemetry_span`
/// rows) against `token_events` cache-column rows (V.19a-2's
/// `cached_prompt_tokens` / `cache_origin` / etc.) on
/// `session_id`. The JOIN shape mirrors V.18a-7's
/// `TimelineTelemetryCorrelator` — pre-fetched inputs, pure
/// computation, no I/O. The dashboard view does the SQL fetch and
/// passes results to `build(inputs:)`.
///
/// ### Privacy invariant (Russell, V.18 metadata-only default)
///
/// `Snapshot` exposes only scalar counts, enum states, and tier
/// strings. There is no `attributesJson` field, no `body`, no
/// prompt content. The struct shape enforces this at compile time —
/// a future maintainer cannot leak prompt content through this
/// surface without changing the public API.
///
/// ### V.17a separation
///
/// Inputs accept ONLY `cache_lifecycle` spans + token-event cache
/// rows. There is no `ProviderRuntimeEvent` parameter. V.19
/// telemetry stays scoped to the local MLX path; external CLI
/// provider observability remains in V.17a's `provider_runtime_event`
/// spine.
public enum MLXInferenceTileCorrelator {

    /// Cache-state derived from the most recent `cache_lifecycle`
    /// span in the input window. `unloaded` is inferred from
    /// absence of recent activity — `CacheLifecycleSpanRecorder`
    /// does not emit `unload` spans (terminal transition, not
    /// operationally interesting per V.19a-3 EventType rationale).
    public enum CacheState: String, Sendable, Equatable {
        /// No spans in the input window. Cache may not have warmed yet,
        /// or activity has aged out of the window.
        case noActivity
        /// Most recent span is `hit` or `cold_miss`.
        case active
        /// Most recent span is `evict`.
        case evicted
    }

    /// System memory pressure as observed by the caller (the
    /// SwiftUI host probes `MLXInferenceLock` / DispatchSource).
    /// The correlator does not probe — pure input.
    public enum MemoryPressure: String, Sendable, Equatable {
        case normal
        case warning
        case critical
    }

    /// JOIN-mismatch indicator. The acceptance preserves the
    /// V.19 re-audit gap-close requirement: orphans render a
    /// stale badge, not silent dropout.
    public enum StaleReason: String, Sendable, Equatable {
        /// A `cache_lifecycle` span exists for a `session_id` with
        /// no matching `token_events` cache row.
        case orphanSpan
        /// A `token_events` row with `cache_origin != nil` exists
        /// for a `session_id` with no matching `cache_lifecycle`
        /// span.
        case orphanTokenEvent
        /// Both directions of orphan in the input window. Surfaces
        /// when the cache subsystem is fully disconnected from the
        /// accounting path on both legs.
        case bothDirections
    }

    /// Compact, scalar-only payload the tile renders. Privacy
    /// contract: no `attributesJson`, no body, no prompt content.
    public struct Snapshot: Sendable, Equatable {
        /// `hit_count / (hit_count + cold_miss_count)`. Zero when
        /// no hit/cold_miss spans seen in the window.
        public let cacheHitRate: Double
        /// `SUM(token_events.cached_prompt_tokens)` across rows
        /// joined to a `cache_lifecycle` span on `session_id`.
        public let cachedTokens: Int
        /// `token_events.model_tier` from the most recent matched
        /// token-event row (by timestamp). Nil when no matched
        /// rows or no `model_tier` set.
        public let activeModelTier: String?
        /// Caller-supplied memory pressure observation. Pure
        /// passthrough so the tile renders without coupling the
        /// correlator to DispatchSource state.
        public let memoryPressure: MemoryPressure
        /// Most recent span's lifecycle state, mapped to display
        /// state.
        public let cacheState: CacheState
        /// JOIN-mismatch reason. Nil when every span has a
        /// matching token-event row AND vice versa.
        public let staleBadge: StaleReason?

        public init(
            cacheHitRate: Double,
            cachedTokens: Int,
            activeModelTier: String?,
            memoryPressure: MemoryPressure,
            cacheState: CacheState,
            staleBadge: StaleReason?
        ) {
            self.cacheHitRate = cacheHitRate
            self.cachedTokens = cachedTokens
            self.activeModelTier = activeModelTier
            self.memoryPressure = memoryPressure
            self.cacheState = cacheState
            self.staleBadge = staleBadge
        }
    }

    /// Narrow token-event projection — only the columns the tile
    /// needs. Privacy invariant: no `command`, no `feature`, no
    /// `attributes_json`. The caller materializes these from a
    /// SQL query in `SessionDatabase`.
    public struct TokenEventRow: Sendable, Equatable {
        public let sessionId: String
        public let cachedPromptTokens: Int
        public let cacheOrigin: CacheOrigin?
        public let modelTier: String?
        public let timestamp: Date

        public init(
            sessionId: String,
            cachedPromptTokens: Int,
            cacheOrigin: CacheOrigin?,
            modelTier: String?,
            timestamp: Date
        ) {
            self.sessionId = sessionId
            self.cachedPromptTokens = cachedPromptTokens
            self.cacheOrigin = cacheOrigin
            self.modelTier = modelTier
            self.timestamp = timestamp
        }
    }

    /// Pre-fetched inputs the SwiftUI host passes in. Cache spans
    /// MUST be `cache_lifecycle.*` (name-prefix filtered by the
    /// caller's `querySpans` call); the correlator does not
    /// re-filter — but the event-type extraction below drops any
    /// span whose name doesn't carry a known suffix.
    public struct Inputs: Sendable {
        public let cacheSpans: [RuntimeTelemetryStore.SpanResult]
        public let tokenEventRows: [TokenEventRow]
        public let memoryPressure: MemoryPressure

        public init(
            cacheSpans: [RuntimeTelemetryStore.SpanResult],
            tokenEventRows: [TokenEventRow],
            memoryPressure: MemoryPressure
        ) {
            self.cacheSpans = cacheSpans
            self.tokenEventRows = tokenEventRows
            self.memoryPressure = memoryPressure
        }
    }

    /// Build a snapshot from the pre-fetched inputs. Pure: no I/O.
    public static func build(inputs: Inputs) -> Snapshot {
        let (hits, coldMisses, recentEventType, recentSpanSessionTime) = aggregateSpans(inputs.cacheSpans)
        let denom = hits + coldMisses
        let hitRate: Double = denom > 0 ? (Double(hits) / Double(denom)) : 0.0

        let sessionsWithSpan: Set<String> = Set(
            inputs.cacheSpans.compactMap { $0.sessionId }
        )
        let sessionsWithCacheRow: Set<String> = Set(
            inputs.tokenEventRows
                .filter { $0.cacheOrigin != nil || $0.cachedPromptTokens > 0 }
                .map { $0.sessionId }
        )

        let matchedSessions = sessionsWithSpan.intersection(sessionsWithCacheRow)
        let cachedTokens = inputs.tokenEventRows
            .filter { matchedSessions.contains($0.sessionId) }
            .reduce(0) { $0 + $1.cachedPromptTokens }

        let activeModelTier = mostRecentTier(
            tokenEventRows: inputs.tokenEventRows,
            matchedSessions: matchedSessions,
            recentSpanSessionTime: recentSpanSessionTime
        )

        let cacheState: CacheState = {
            guard let evt = recentEventType else { return .noActivity }
            switch evt {
            case .evict: return .evicted
            case .hit, .coldMiss, .corruptionRecovery: return .active
            }
        }()

        let staleBadge = staleReason(
            sessionsWithSpan: sessionsWithSpan,
            sessionsWithCacheRow: sessionsWithCacheRow
        )

        return Snapshot(
            cacheHitRate: hitRate,
            cachedTokens: cachedTokens,
            activeModelTier: activeModelTier,
            memoryPressure: inputs.memoryPressure,
            cacheState: cacheState,
            staleBadge: staleBadge
        )
    }

    // MARK: - Private helpers

    /// Walk spans once. Returns `(hitCount, coldMissCount,
    /// mostRecentEventType, mostRecentSessionTimeMap)`. The session-
    /// time map is `session_id → end_unix_ns` of that session's most
    /// recent span; it tie-breaks `mostRecentTier` against multiple
    /// token-event rows per matched session.
    static func aggregateSpans(
        _ spans: [RuntimeTelemetryStore.SpanResult]
    ) -> (hits: Int, coldMisses: Int, recentEventType: CacheLifecycleSpanRecorder.EventType?, perSessionEndNs: [String: Int64]) {
        var hits = 0
        var coldMisses = 0
        var recentEnd: Int64 = .min
        var recentEventType: CacheLifecycleSpanRecorder.EventType? = nil
        var perSessionEndNs: [String: Int64] = [:]
        for span in spans {
            guard let evt = eventType(from: span.name) else { continue }
            switch evt {
            case .hit: hits += 1
            case .coldMiss: coldMisses += 1
            case .evict, .corruptionRecovery: break
            }
            if span.endUnixNs > recentEnd {
                recentEnd = span.endUnixNs
                recentEventType = evt
            }
            if let sid = span.sessionId,
               span.endUnixNs > (perSessionEndNs[sid] ?? .min) {
                perSessionEndNs[sid] = span.endUnixNs
            }
        }
        return (hits, coldMisses, recentEventType, perSessionEndNs)
    }

    /// Extract `EventType` from a span `name` of shape
    /// `cache_lifecycle.<event_type>`. Returns nil for names that
    /// don't match the prefix — the correlator silently drops
    /// non-cache_lifecycle spans rather than fail the build.
    static func eventType(from name: String) -> CacheLifecycleSpanRecorder.EventType? {
        let prefix = CacheLifecycleSpanRecorder.spanNamePrefix + "."
        guard name.hasPrefix(prefix) else { return nil }
        let suffix = String(name.dropFirst(prefix.count))
        return CacheLifecycleSpanRecorder.EventType(rawValue: suffix)
    }

    /// Pick the model tier from the most recent matched token-event
    /// row. "Most recent" is by `timestamp` across all matched rows;
    /// when timestamps tie, the row with the largest paired
    /// span-end-ns wins.
    static func mostRecentTier(
        tokenEventRows: [TokenEventRow],
        matchedSessions: Set<String>,
        recentSpanSessionTime: [String: Int64]
    ) -> String? {
        let matched = tokenEventRows.filter { matchedSessions.contains($0.sessionId) }
        guard !matched.isEmpty else { return nil }
        let sorted = matched.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp > rhs.timestamp
            }
            let lEnd = recentSpanSessionTime[lhs.sessionId] ?? .min
            let rEnd = recentSpanSessionTime[rhs.sessionId] ?? .min
            return lEnd > rEnd
        }
        return sorted.first?.modelTier
    }

    /// Compute the stale-badge reason from the two session sets.
    /// `nil` when both directions match cleanly OR both sets are
    /// empty (no JOIN to verify).
    static func staleReason(
        sessionsWithSpan: Set<String>,
        sessionsWithCacheRow: Set<String>
    ) -> StaleReason? {
        let orphanSpans = !sessionsWithSpan.subtracting(sessionsWithCacheRow).isEmpty
        let orphanRows = !sessionsWithCacheRow.subtracting(sessionsWithSpan).isEmpty
        switch (orphanSpans, orphanRows) {
        case (false, false): return nil
        case (true, false): return .orphanSpan
        case (false, true): return .orphanTokenEvent
        case (true, true): return .bothDirections
        }
    }
}
