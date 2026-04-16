import Testing
import Foundation
@testable import Core
@testable import Bench

private func makeEvalRoot() -> (KnowledgeStore, String) {
    let root = "/tmp/senkani-eval-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: root + "/.senkani",
                                              withIntermediateDirectories: true)
    return (KnowledgeStore(projectRoot: root), root)
}
private func cleanup(_ root: String) { try? FileManager.default.removeItem(atPath: root) }

@Suite("KBEval")
struct KBEvalTests {

    // 1. No DB file → vacuous pass (threshold=0, actual=0)
    @Test func testNoDBIsVacuousPass() {
        let root = "/tmp/senkani-eval-noexist-\(UUID().uuidString)"
        let gates = KBGateComputer.computeGates(projectRoot: root)
        #expect(gates.allSatisfy { $0.passed })
    }

    // 2. Populated gate fails when store has 0 entities
    @Test func testPopulatedGateFailsEmpty() {
        let (_, root) = makeEvalRoot(); defer { cleanup(root) }
        let gates = KBGateComputer.computeGates(projectRoot: root)
        let populated = gates.first { $0.name == "kb.populated" }
        #expect(populated?.passed == false)
    }

    // 3. Populated gate passes when ≥1 entity
    @Test func testPopulatedGatePasses() {
        let (store, root) = makeEvalRoot(); defer { cleanup(root) }
        store.upsertEntity(KnowledgeEntity(name: "A", entityType: "class", markdownPath: "a.md"))
        let gates = KBGateComputer.computeGates(projectRoot: root)
        let populated = gates.first { $0.name == "kb.populated" }
        #expect(populated?.passed == true)
    }

    // 4. Freshness gate: entities with default stalenessScore (0.0 < 0.3) → PASS
    @Test func testFreshnessGateAllFresh() {
        let (store, root) = makeEvalRoot(); defer { cleanup(root) }
        store.upsertEntity(KnowledgeEntity(name: "A", entityType: "class", markdownPath: "a.md"))
        store.upsertEntity(KnowledgeEntity(name: "B", entityType: "class", markdownPath: "b.md"))
        let gates = KBGateComputer.computeGates(projectRoot: root)
        let freshness = gates.first { $0.name == "kb.freshness" }
        #expect(freshness?.passed == true)
    }

    // 5. Enrichment gate: vacuous pass when no entity has mentionCount≥3
    @Test func testEnrichmentGateVacuousPass() {
        let (store, root) = makeEvalRoot(); defer { cleanup(root) }
        // Default mentionCount is 0 — no candidates → threshold=0, actual=0 → PASS
        store.upsertEntity(KnowledgeEntity(name: "A", entityType: "class", markdownPath: "a.md"))
        let gates = KBGateComputer.computeGates(projectRoot: root)
        let enrichment = gates.first { $0.name == "kb.enrichment" }
        #expect(enrichment?.passed == true)
    }
}
