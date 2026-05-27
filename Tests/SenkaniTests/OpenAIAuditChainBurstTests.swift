import Testing
import Foundation
import SQLite3
@testable import Core

/// V.13e-5 — 100-request audit-chain burst integrity (Schneier P0 guard #3).
///
/// Asserts the T.5 chain integrity model holds with **zero dropped links**
/// under a 100-request burst across mixed surfaces (chat / chat_stream /
/// embeddings / tool_use), for BOTH chains the OpenAI endpoint maintains:
///
///   1. The in-memory `OpenAIAuditChain` (`append`/`verify`) — the hot-path
///      chain shared across `NWConnection` accept callbacks. `verify()` must
///      return `.ok(count: 100)` after the burst.
///   2. The DB-backed `OpenAIRequestLogStore` (V.13e-1) — verified
///      cross-process: a SECOND `SessionDatabase` handle opened at the same
///      path (cold `ChainState` cache, simulating a process restart)
///      re-verifies the persisted chain via
///      `ChainVerifier.verifyOpenAIRequestLog`. Links survive the burst, not
///      just in-memory.
///
/// The burst is driven CONCURRENTLY (`concurrentPerform`) to stress the
/// in-memory chain's `NSLock` and the store's queue-affinity write path —
/// the realistic contention the chain is built for.
@Suite("OpenAIAuditChain burst integrity (V.13e-5)")
struct OpenAIAuditChainBurstTests {

    private static func tempDBPath() -> String {
        let dir = NSTemporaryDirectory() + "senkani-v13e-5-tests/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "openai-burst-\(UUID().uuidString).db"
    }

    /// The four served surfaces, cycled across the burst so every
    /// `OpenAIRequestLogStore.Surface` case is exercised. The in-memory
    /// chain logs the matching `rawValue`, so both chains see the same
    /// surface label per request.
    private static let surfaces: [OpenAIRequestLogStore.Surface] =
        [.chat, .chatStream, .embeddings, .toolUse]

    @Test("100-request burst across mixed surfaces: zero dropped links, in-memory + persisted cross-process")
    func hundredRequestBurstZeroDroppedLinks() {
        let burst = 100
        let chain = OpenAIAuditChain()
        let path = Self.tempDBPath()
        let base = Date(timeIntervalSince1970: 1_900_000_000)

        // --- Handle 1: drive both chains under a concurrent burst. ---
        do {
            let db1 = SessionDatabase(path: path)
            DispatchQueue.concurrentPerform(iterations: burst) { i in
                let surface = Self.surfaces[i % Self.surfaces.count]
                // Mostly 200s with a sprinkling of 429s. Status does not
                // affect chain linkage; mixing it proves the chain is
                // status-agnostic under load.
                let status = (i % 17 == 0) ? 429 : 200
                let keyLabel = "key-\(i % 3)"
                let fields = OpenAIAuditChain.AuditFields(
                    ts: base.addingTimeInterval(Double(i)),
                    keyLabel: keyLabel,
                    surface: surface.rawValue,
                    modelLogged: "gpt-4o-mini",
                    presetUsed: "balanced",
                    resolvedTier: "local",
                    promptTokenCount: 10 + i,
                    completionTokenCount: 20 + i,
                    status: "\(status)"
                )
                chain.append(fields, bodies: nil)
                _ = db1.recordOpenAIRequest(
                    ts: base.addingTimeInterval(Double(i)),
                    surface: surface, status: status, keyLabel: keyLabel)
            }

            // In-memory chain: exactly 100 entries, verify clean — the
            // primary "zero dropped links" guard.
            #expect(chain.count == burst)
            #expect(chain.verify() == .ok(count: burst))

            // Persisted store wrote all 100 rows in the same process.
            // (A short row count would mean a record() returned false.)
            #expect(db1.openAIRequestLogCount() == Int64(burst))
        }

        // --- Handle 2: fresh process, cold ChainState cache, same path. ---
        // The cross-process leg: the chain the previous handle wrote must
        // verify from a handle that never saw the in-process chain state.
        let db2 = SessionDatabase(path: path)
        #expect(db2.openAIRequestLogCount() == Int64(burst))

        let result = ChainVerifier.verifyOpenAIRequestLog(db2)
        switch result {
        case .ok:
            break  // zero dropped links across the persisted burst
        default:
            Issue.record(
                "persisted openai_request_log chain must verify .ok cross-process, got \(result)")
        }

        // Mixed-surface requirement: every surface was actually exercised.
        let recent = db2.recentOpenAIRequests(limit: burst)
        #expect(recent.count == burst)
        let distinctSurfaces = Set(recent.map { $0.surface })
        #expect(distinctSurfaces == Set(Self.surfaces.map { $0.rawValue }))
    }
}
