import Testing
import Foundation
@testable import Core

/// V.19a-4 — MLXInferenceTileCorrelator tests.
///
/// Four acceptance-aligned tests (`tests_target: 4`):
///
/// 1. **JOIN happy path** — paired `cache_lifecycle` spans +
///    `token_events` cache rows on the same `session_id` produce a
///    snapshot with non-zero hit rate, summed cached tokens, the
///    correct active model tier, the cache_state derived from the
///    most recent span, and **no stale badge**. Covers acceptance
///    bullets 1 + 3.
/// 2. **Orphan span → stale badge** — a `cache_lifecycle` span
///    exists for a session with no matching token-event cache row;
///    the snapshot's `staleBadge` is `.orphanSpan`, never silent
///    dropout. Covers acceptance bullet 4 (Majors's V.19 re-audit
///    gap-close requirement).
/// 3. **Orphan token-event row → stale badge** — a token-event
///    row with `cacheOrigin: .prefixCache` exists for a session
///    with no matching `cache_lifecycle` span; `staleBadge` is
///    `.orphanTokenEvent`. Covers acceptance bullet 4.
/// 4. **API shape excludes provider_runtime_event** — `Inputs` and
///    `Snapshot` accept/expose ONLY cache_lifecycle-derived fields.
///    A compile-time check enumerates the public properties so a
///    future maintainer cannot leak V.17a provider rows through
///    this surface. Covers acceptance bullet 5 (V.17a separation)
///    and bullet 2 (V.18 metadata-only privacy invariant).
@Suite("MLXInferenceTileCorrelator (V.19a-4)")
struct MLXInferenceTileCorrelatorTests {

    // MARK: - Fixture helpers

    private static func makeCacheSpan(
        id: Int64,
        sessionId: String,
        eventType: CacheLifecycleSpanRecorder.EventType,
        toolCallId: String? = nil,
        endNs: Int64 = 0
    ) -> RuntimeTelemetryStore.SpanResult {
        let actualEnd = endNs == 0 ? id * 1_000_000_000 : endNs
        let name = "\(CacheLifecycleSpanRecorder.spanNamePrefix).\(eventType.rawValue)"
        return RuntimeTelemetryStore.SpanResult(
            id: id,
            datasetId: 1,
            traceId: "trace-\(id)",
            spanId: "\(eventType.rawValue)-\(id)",
            parentSpanId: nil,
            name: name,
            startUnixNs: actualEnd - 1_000,
            endUnixNs: actualEnd,
            attributesJson: nil,
            statusCode: 1,
            sessionId: sessionId,
            toolCallId: toolCallId,
            validationRunId: nil
        )
    }

    private static func makeTokenEventRow(
        sessionId: String,
        cachedPromptTokens: Int,
        cacheOrigin: CacheOrigin?,
        modelTier: String?,
        timestampSecondsSinceEpoch: Double
    ) -> MLXInferenceTileCorrelator.TokenEventRow {
        return MLXInferenceTileCorrelator.TokenEventRow(
            sessionId: sessionId,
            cachedPromptTokens: cachedPromptTokens,
            cacheOrigin: cacheOrigin,
            modelTier: modelTier,
            timestamp: Date(timeIntervalSince1970: timestampSecondsSinceEpoch)
        )
    }

    // MARK: - Test 1 — JOIN happy path

    @Test("JOIN happy path: paired spans + token_events produce hit rate + cached tokens + tier + no stale badge")
    func joinHappyPath() throws {
        let session = "11111111-2222-3333-4444-555555555555"
        // 3 hits, 1 cold_miss → 75% hit rate. Most recent is hit (largest endNs).
        let spans = [
            Self.makeCacheSpan(id: 1, sessionId: session, eventType: .coldMiss, endNs: 1_000_000_000),
            Self.makeCacheSpan(id: 2, sessionId: session, eventType: .hit, endNs: 2_000_000_000),
            Self.makeCacheSpan(id: 3, sessionId: session, eventType: .hit, endNs: 3_000_000_000),
            Self.makeCacheSpan(id: 4, sessionId: session, eventType: .hit, endNs: 4_000_000_000),
        ]
        let tokenRows = [
            Self.makeTokenEventRow(
                sessionId: session,
                cachedPromptTokens: 1024,
                cacheOrigin: .prefixCache,
                modelTier: "medium",
                timestampSecondsSinceEpoch: 1_000
            ),
            Self.makeTokenEventRow(
                sessionId: session,
                cachedPromptTokens: 2048,
                cacheOrigin: .prefixCache,
                modelTier: "large",
                timestampSecondsSinceEpoch: 2_000  // more recent → active tier
            ),
        ]
        let inputs = MLXInferenceTileCorrelator.Inputs(
            cacheSpans: spans,
            tokenEventRows: tokenRows,
            memoryPressure: .normal
        )
        let snapshot = MLXInferenceTileCorrelator.build(inputs: inputs)
        #expect(snapshot.cacheHitRate == 0.75)
        #expect(snapshot.cachedTokens == 1024 + 2048)
        #expect(snapshot.activeModelTier == "large")
        #expect(snapshot.cacheState == .active)
        #expect(snapshot.memoryPressure == .normal)
        #expect(snapshot.staleBadge == nil)
    }

    // MARK: - Test 2 — Orphan span surfaces stale badge

    @Test("orphan cache_lifecycle span (no matching token_events row) surfaces .orphanSpan badge")
    func orphanSpanSurfacesStaleBadge() throws {
        let sessionWithSpanOnly = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let spans = [
            Self.makeCacheSpan(id: 1, sessionId: sessionWithSpanOnly, eventType: .hit),
            Self.makeCacheSpan(id: 2, sessionId: sessionWithSpanOnly, eventType: .evict, endNs: 5_000_000_000),
        ]
        // No token-event rows for this session at all.
        let tokenRows: [MLXInferenceTileCorrelator.TokenEventRow] = []
        let inputs = MLXInferenceTileCorrelator.Inputs(
            cacheSpans: spans,
            tokenEventRows: tokenRows,
            memoryPressure: .normal
        )
        let snapshot = MLXInferenceTileCorrelator.build(inputs: inputs)
        #expect(snapshot.staleBadge == .orphanSpan)
        // Cached-tokens sum is zero (no matched rows) — NOT silent
        // dropout; the badge surfaces the mismatch.
        #expect(snapshot.cachedTokens == 0)
        // Cache state still reflects most-recent span (evict).
        #expect(snapshot.cacheState == .evicted)
        // Active model tier nil — no matched token-event row to read it from.
        #expect(snapshot.activeModelTier == nil)
    }

    // MARK: - Test 3 — Orphan token_event row surfaces stale badge

    @Test("orphan token_events row (cacheOrigin set, no matching cache_lifecycle span) surfaces .orphanTokenEvent badge")
    func orphanTokenEventSurfacesStaleBadge() throws {
        let sessionWithRowOnly = "ffffffff-0000-1111-2222-333333333333"
        let spans: [RuntimeTelemetryStore.SpanResult] = []
        let tokenRows = [
            Self.makeTokenEventRow(
                sessionId: sessionWithRowOnly,
                cachedPromptTokens: 512,
                cacheOrigin: .prefixCache,
                modelTier: "small",
                timestampSecondsSinceEpoch: 1_000
            ),
        ]
        let inputs = MLXInferenceTileCorrelator.Inputs(
            cacheSpans: spans,
            tokenEventRows: tokenRows,
            memoryPressure: .warning
        )
        let snapshot = MLXInferenceTileCorrelator.build(inputs: inputs)
        #expect(snapshot.staleBadge == .orphanTokenEvent)
        // No spans → hit rate = 0 (no hits or cold misses observed).
        #expect(snapshot.cacheHitRate == 0)
        #expect(snapshot.cacheState == .noActivity)
        // Cached-tokens sum is 0 (the row is unmatched — not counted),
        // NOT silently rolled up. The badge is the only signal of
        // disconnection.
        #expect(snapshot.cachedTokens == 0)
        #expect(snapshot.activeModelTier == nil)
        #expect(snapshot.memoryPressure == .warning)
    }

    // MARK: - Test 4 — API shape excludes provider_runtime_event (V.17a)

    @Test("API shape: Inputs/Snapshot expose only cache_lifecycle + token_events fields; no provider_runtime_event surface")
    func apiShapeExcludesProviderRuntimeEvent() throws {
        // Reflection enumeration of `Inputs` and `Snapshot` public
        // fields. If a future maintainer adds a `providerRuntimeEvent`
        // (or any field whose label mentions `provider`), this test
        // fails — keeping V.19's local-MLX surface separate from
        // V.17a's external-CLI-provider spine.
        //
        // We also assert the privacy-shape invariant: no field is named
        // `body`, `payload`, `attributesJson`, `command`, or `prompt`.
        let session = "ffffeeee-dddd-cccc-bbbb-aaaaaaaaaaaa"
        let inputs = MLXInferenceTileCorrelator.Inputs(
            cacheSpans: [Self.makeCacheSpan(id: 1, sessionId: session, eventType: .hit)],
            tokenEventRows: [
                Self.makeTokenEventRow(
                    sessionId: session,
                    cachedPromptTokens: 100,
                    cacheOrigin: .prefixCache,
                    modelTier: "medium",
                    timestampSecondsSinceEpoch: 1_000
                ),
            ],
            memoryPressure: .normal
        )
        let snapshot = MLXInferenceTileCorrelator.build(inputs: inputs)

        let disallowedFragments = ["provider", "body", "payload", "attributesjson", "command", "prompt"]

        let inputsMirror = Mirror(reflecting: inputs)
        for child in inputsMirror.children {
            guard let label = child.label?.lowercased() else { continue }
            for frag in disallowedFragments {
                #expect(!label.contains(frag),
                        "Inputs field '\(child.label ?? "?")' contains disallowed fragment '\(frag)' — would leak V.17a or privacy-restricted content")
            }
        }
        let snapshotMirror = Mirror(reflecting: snapshot)
        for child in snapshotMirror.children {
            guard let label = child.label?.lowercased() else { continue }
            for frag in disallowedFragments {
                #expect(!label.contains(frag),
                        "Snapshot field '\(child.label ?? "?")' contains disallowed fragment '\(frag)'")
            }
        }
        // Also assert the snapshot built fine with normal inputs.
        #expect(snapshot.staleBadge == nil)
        #expect(snapshot.cacheHitRate == 1.0)
        #expect(snapshot.cachedTokens == 100)
    }
}
