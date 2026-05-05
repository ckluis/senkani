import Testing
import Foundation
@testable import MCPServer

/// Phase B-i: registry-isolation guarantees.
///
/// Two connections targeting **different** project roots must observe
/// distinct `MCPSession` actor instances and distinct in-memory metric
/// counters. This is the registry's load-bearing contract — without
/// it, multi-project daemon mode collapses back into the legacy
/// process-global singleton.
@Suite("MCPSessionRegistry — multi-project isolation (Phase B-i)")
struct MCPSessionRegistryIsolationTests {

    private func makeSession(at root: String) -> MCPSession {
        MCPSession(
            projectRoot: root,
            filterEnabled: false,
            secretsEnabled: false,
            indexerEnabled: false,
            cacheEnabled: false,
            terseEnabled: false
        )
    }

    /// Two acquires for the SAME project root must return the same actor —
    /// the registry's reuse contract. No new session allocated on hit.
    @Test func sameProjectRootReusesSession() {
        let registry = MCPSessionRegistry()
        let root = "/tmp/senkani-registry-reuse-\(UUID().uuidString)"

        let s1 = registry.session(projectRoot: root) { self.makeSession(at: root) }
        let s2 = registry.session(projectRoot: root) { self.makeSession(at: root) }

        #expect(s1 === s2, "same projectRoot must return the same session instance")
        #expect(registry._count == 1, "registry must hold exactly one entry")
    }

    /// Two acquires for DIFFERENT project roots must return distinct actors,
    /// each pinned to its own root. The first-acquired root becomes the
    /// `defaultSession()` (KBReader's bridge for SenkaniApp).
    @Test func differentProjectRootsAllocateDistinctSessions() {
        let registry = MCPSessionRegistry()
        let rootA = "/tmp/senkani-registry-A-\(UUID().uuidString)"
        let rootB = "/tmp/senkani-registry-B-\(UUID().uuidString)"

        let sA = registry.session(projectRoot: rootA) { self.makeSession(at: rootA) }
        let sB = registry.session(projectRoot: rootB) { self.makeSession(at: rootB) }

        #expect(sA !== sB, "distinct project roots must allocate distinct sessions")
        #expect(sA.projectRoot == rootA, "session A's projectRoot must match")
        #expect(sB.projectRoot == rootB, "session B's projectRoot must match")
        #expect(registry._count == 2, "registry must hold exactly two entries")

        // First-acquired wins as the default — that's the SenkaniApp / KBReader
        // bridge. Both root-A and root-B are reachable, but only A surfaces via
        // defaultSession().
        #expect(registry.defaultSession() === sA,
                "first-acquired root must surface via defaultSession()")
    }

    /// Concurrent recordMetrics on two sessions for distinct project roots
    /// must NOT cross-contaminate counters. This is the smoke test that two
    /// connections targeting different project roots accrue metrics
    /// independently — the per-project isolation contract.
    @Test func concurrentRecordMetricsAcrossSessionsDoesNotLeak() async {
        let registry = MCPSessionRegistry()
        let rootA = "/tmp/senkani-registry-iso-A-\(UUID().uuidString)"
        let rootB = "/tmp/senkani-registry-iso-B-\(UUID().uuidString)"

        let sA = registry.session(projectRoot: rootA) { self.makeSession(at: rootA) }
        let sB = registry.session(projectRoot: rootB) { self.makeSession(at: rootB) }

        let callsPerSession = 100

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<callsPerSession {
                let target = i.isMultiple(of: 2) ? sA : sB
                group.addTask {
                    await target.recordMetrics(
                        rawBytes: 1_000,
                        compressedBytes: 100,
                        feature: "registry-iso"
                    )
                }
            }
        }

        let callsA = await sA.toolCallCount
        let callsB = await sB.toolCallCount
        let rawA = await sA.totalRawBytes
        let rawB = await sB.totalRawBytes

        // Half the calls go to each session; the totals must not drift.
        #expect(callsA + callsB == callsPerSession,
                "total calls across both sessions must equal callsPerSession — got A=\(callsA) B=\(callsB)")
        #expect(callsA == callsPerSession / 2 && callsB == callsPerSession / 2,
                "metrics must not cross sessions — A=\(callsA), B=\(callsB)")
        #expect(rawA == (callsPerSession / 2) * 1_000)
        #expect(rawB == (callsPerSession / 2) * 1_000)
    }

    /// `defaultSession()` returns nil before any acquire happens. Cleared
    /// state behaves the same. Only `ensureDefaultSession()` lazily
    /// bootstraps from environment.
    @Test func defaultSessionIsNilBeforeFirstAcquire() {
        let registry = MCPSessionRegistry()
        #expect(registry.defaultSession() == nil,
                "fresh registry must have no default session")
        #expect(registry._count == 0)
    }

    /// `recordMetrics` reads `MCPSession.currentConnectionId` from the
    /// task-local — verifying the dispatch-layer plumbing path.
    /// `ToolRouter.dispatchTool` uses `withValue(...)`; here we drive that
    /// directly to prove the contract.
    @Test func recordMetricsTagsConnectionIdFromTaskLocal() async throws {
        let tmpDir = NSTemporaryDirectory() + "senkani-conn-id-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        let metricsPath = tmpDir + "/metrics.jsonl"

        let session = MCPSession(
            projectRoot: tmpDir,
            filterEnabled: false,
            secretsEnabled: false,
            indexerEnabled: false,
            cacheEnabled: false,
            terseEnabled: false,
            metricsFilePath: metricsPath
        )

        let connectionId = "conn-42"
        await MCPSession.$currentConnectionId.withValue(connectionId) {
            await session.recordMetrics(
                rawBytes: 500,
                compressedBytes: 50,
                feature: "task-local-tag"
            )
        }

        // Read the JSONL row back and verify the connectionId is on it.
        let raw = try String(contentsOfFile: metricsPath, encoding: .utf8)
        let line = raw.split(separator: "\n").first.map(String.init) ?? ""
        #expect(line.contains("\"connectionId\":\"\(connectionId)\""),
                "JSONL row must carry the task-local connectionId — got: \(line)")
    }
}
