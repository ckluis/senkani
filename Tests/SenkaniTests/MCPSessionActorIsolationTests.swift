import Testing
import Foundation
@testable import MCPServer

/// Phase A guard against regressions in MCPSession's actor isolation.
///
/// Before Phase A `MCPSession` was a `final class @unchecked Sendable` with
/// an internal `NSLock`. The conversion to `actor` is the load-bearing
/// change: if a future refactor accidentally rolls back to `class` (or
/// inserts an unsynchronised mutable property), this suite races a few
/// mutating methods concurrently and asserts (a) we don't crash on a data
/// race and (b) every observable counter ends up consistent.
///
/// Smoke-level by design — exhaustive multi-connection behaviour is the
/// territory of Phase B's registry + per-connection metrics tests.
@Suite("MCPSession — actor isolation (Phase A)")
struct MCPSessionActorIsolationTests {

    private func makeSession() -> MCPSession {
        MCPSession(
            projectRoot: "/tmp/senkani-actor-iso-\(UUID().uuidString)",
            filterEnabled: false,
            secretsEnabled: false,
            indexerEnabled: false,
            cacheEnabled: false,
            terseEnabled: false
        )
    }

    /// Race recordMetrics + updateConfig + noteDeprecation on one session and
    /// confirm the published counters land on exact expected totals — proving
    /// the actor's mutually-exclusive isolation holds across mixed mutators.
    @Test func concurrentMutatorsConverge() async {
        let session = makeSession()

        let totalCalls = 200
        let bytesPerCall = 1_000

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<totalCalls {
                group.addTask {
                    await session.recordMetrics(
                        rawBytes: bytesPerCall,
                        compressedBytes: 100,
                        feature: "race"
                    )
                    if i % 5 == 0 {
                        await session.updateConfig(filter: i.isMultiple(of: 2))
                    }
                    if i % 7 == 0 {
                        _ = await session.noteDeprecation("race.\(i % 3)")
                    }
                }
            }
        }

        let raw = await session.totalRawBytes
        let comp = await session.totalCompressedBytes
        let calls = await session.toolCallCount
        let perFeature = await session.perFeatureSaved

        #expect(calls == totalCalls,
                "toolCallCount must equal the number of recordMetrics calls — got \(calls), want \(totalCalls)")
        #expect(raw == totalCalls * bytesPerCall,
                "totalRawBytes must equal calls × bytesPerCall — got \(raw), want \(totalCalls * bytesPerCall)")
        #expect(comp == totalCalls * 100,
                "totalCompressedBytes must equal calls × 100 — got \(comp)")
        #expect(perFeature["race"] == totalCalls * (bytesPerCall - 100),
                "per-feature savings for 'race' must equal calls × delta — got \(perFeature["race"] ?? -1)")
    }

    /// Hammer noteDeprecation with the same key from many concurrent tasks.
    /// Exactly ONE task must observe `true`; the rest must observe `false`.
    /// A regression to lock-free mutation would either let two tasks see
    /// `true` (set-insertion race) or trip Swift's runtime concurrency guard.
    @Test func noteDeprecationFiresExactlyOnceUnderRace() async {
        let session = makeSession()

        let key = "knowledge.detail"
        let workerCount = 50

        let firstSightCount = await withTaskGroup(of: Bool.self) { group -> Int in
            for _ in 0..<workerCount {
                group.addTask {
                    await session.noteDeprecation(key)
                }
            }
            var trues = 0
            for await result in group where result {
                trues += 1
            }
            return trues
        }

        #expect(firstSightCount == 1,
                "noteDeprecation must report first-sight exactly once across \(workerCount) tasks — got \(firstSightCount)")
    }

    /// `nonisolated let` reads (the four KB-bridge fields) must remain
    /// synchronously callable from outside the actor — that's the load-
    /// bearing assertion behind keeping `KBReader` sync. If Phase B (or any
    /// future change) reverts these to actor-isolated, KBReader's
    /// SenkaniApp consumers would need `await` and break the build. This
    /// test compiles ⇒ guarantee holds.
    @Test func nonisolatedLetFieldsRemainSyncReadable() {
        let session = makeSession()

        // No `await` on any of these accesses — must compile in a sync context.
        let _ = session.projectRoot
        let _ = session.knowledgeStore
        let _ = session.entityTracker
        let _ = session.knowledgeLayer
        let _ = session.readCache
        let _ = session.pipeline
        let _ = session.validatorRegistry
        let _ = session.metricsFilePath
        let _ = session.sessionId
        let _ = session.paneId
        let _ = session.agentType
        let _ = session.treeCache
        let _ = session.pinnedContextStore

        #expect(true, "compilation in a sync test body proves these reads stayed nonisolated")
    }
}
