import Foundation

/// Session DB façade for the OpenAI-endpoint request log (Phase V.13e-1).
/// Mirrors `SessionDatabase+EvalResultsAPI` shape. The v13e-2 doctor
/// check and v13e-5 burst-integrity test read trailing-24h telemetry
/// via these methods; `RetentionScheduler` (or a maintenance pass) calls
/// `pruneOpenAIRequestLog`.
extension SessionDatabase {

    /// Record one served OpenAI-endpoint request. Best-effort: a SQLite
    /// write failure does not propagate — the listener must keep serving
    /// even if the audit DB is offline. The raw API key is never written;
    /// pass only `keyLabel`. Returns `true` on a successful chained insert.
    ///
    /// The four producer-metadata params (`modelLogged`, `resolvedTier`,
    /// `inputTokens`, `outputTokens`) ride the Migration v42 columns.
    /// Default to nil so legacy callers (V.13e-5 burst integrity,
    /// `OpenAIChatRoutingAuditTests`) continue to compile; the success
    /// path threads through `OpenAIServedRequestSink.record` which
    /// applies regex sanitization before this hop. The refusal path
    /// passes `modelLogged: "<refused>"` + nil for the other three.
    @discardableResult
    public func recordOpenAIRequest(
        ts: Date = Date(),
        surface: OpenAIRequestLogStore.Surface,
        status: Int,
        keyLabel: String?,
        modelLogged: String? = nil,
        resolvedTier: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        upstreamResponseId: String? = nil
    ) -> Bool {
        openAIRequestLogStore.record(
            ts: ts, surface: surface, status: status, keyLabel: keyLabel,
            modelLogged: modelLogged, resolvedTier: resolvedTier,
            inputTokens: inputTokens, outputTokens: outputTokens,
            upstreamResponseId: upstreamResponseId
        )
    }

    /// Trailing-24h request count + 429-rate, computed cross-process from
    /// the persisted rows.
    public func openAIRequestTrailing24hStats(
        now: Date = Date()
    ) -> OpenAIRequestLogStore.TrailingStats {
        openAIRequestLogStore.trailing24hStats(now: now)
    }

    /// Prune request-log rows older than `retentionDays` (default 30).
    /// Returns the number of rows deleted.
    @discardableResult
    public func pruneOpenAIRequestLog(
        retentionDays: Int = 30,
        now: Date = Date()
    ) -> Int {
        openAIRequestLogStore.prune(retentionDays: retentionDays, now: now)
    }

    /// Most recent request-log rows in descending id order.
    public func recentOpenAIRequests(limit: Int = 100) -> [OpenAIRequestLogStore.Row] {
        openAIRequestLogStore.recent(limit: limit)
    }

    /// Total request-log row count.
    public func openAIRequestLogCount() -> Int64 {
        openAIRequestLogStore.count()
    }

    /// Drop the chain cache after a `--repair-chain`.
    func invalidateOpenAIRequestLogChainCache() {
        queue.sync {
            openAIRequestLogStore.invalidateChainCache()
        }
    }
}
