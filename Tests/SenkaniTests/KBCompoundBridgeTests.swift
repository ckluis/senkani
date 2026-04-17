import Testing
import Foundation
@testable import Core

private let fixedDate = Date(timeIntervalSince1970: 1_713_360_000)

@Suite("KBCompoundBridge — confidence boost (F+5 Round 8)")
struct KBBoostTests {

    @Test func noBoostWhenNoMentions() {
        let r = KBCompoundBridge.boostConfidence(raw: 0.5, kbMentionCount: 0)
        #expect(r.boost == 0)
        #expect(r.result == 0.5)
    }

    @Test func boostScalesWithLogMentions() {
        // log1p(1) ≈ 0.693 → boost ≈ 0.035
        let r1 = KBCompoundBridge.boostConfidence(raw: 0.5, kbMentionCount: 1)
        let r10 = KBCompoundBridge.boostConfidence(raw: 0.5, kbMentionCount: 10)
        let r100 = KBCompoundBridge.boostConfidence(raw: 0.5, kbMentionCount: 100)
        #expect(r1.boost > 0)
        #expect(r10.boost > r1.boost,
            "more mentions produce larger boost")
        #expect(r100.boost > r10.boost,
            "boost grows with mention count (bounded by log)")
    }

    @Test func boostCappedAtOne() {
        let r = KBCompoundBridge.boostConfidence(raw: 0.99, kbMentionCount: 1000)
        #expect(r.result <= 1.0)
    }

    @Test func boostNeverNegative() {
        let r = KBCompoundBridge.boostConfidence(raw: 0.0, kbMentionCount: 5)
        #expect(r.result >= 0.0)
    }
}

@Suite("KBCompoundBridge — seed + invalidate (F+5 Round 8)", .serialized)
struct KBBridgeLifecycleTests {

    private func makeStore() -> (KnowledgeStore, String) {
        let root = NSTemporaryDirectory() + "senkani-f5-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: root + "/.senkani", withIntermediateDirectories: true)
        return (KnowledgeStore(projectRoot: root), root)
    }

    @Test func seedCreatesEntityWhenAbsent() {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let doc = LearnedContextDoc(
            id: "d1", title: "sources-core-filterpipeline-swift",
            body: "x", sources: [], confidence: 0.9,
            status: .applied, createdAt: fixedDate,
            sessionCount: 3
        )
        let created = KBCompoundBridge.seedKBEntity(for: doc, store: store)
        #expect(created)
        #expect(store.entity(named: "SourcesCoreFilterpipelineSwift") != nil)
    }

    @Test func seedIsIdempotent() {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let doc = LearnedContextDoc(
            id: "d2", title: "sources-core-filterpipeline-swift",
            body: "x", sources: [], confidence: 0.9,
            status: .applied, createdAt: fixedDate
        )
        let firstCall = KBCompoundBridge.seedKBEntity(for: doc, store: store)
        let secondCall = KBCompoundBridge.seedKBEntity(for: doc, store: store)
        #expect(firstCall == true)
        #expect(secondCall == false, "second call is a no-op")
        // Still only one entity.
        #expect(store.allEntities().filter {
            $0.name == "SourcesCoreFilterpipelineSwift"
        }.count == 1)
    }

    @Test func invalidateMovesAppliedDocsBackToRecurring() throws {
        let temp = NSTemporaryDirectory() + "senkani-f5-inval-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        try LearnedRulesStore.withPath(temp) {
            let doc = LearnedContextDoc(
                id: "d3", title: "sessiondatabase-swift",
                body: "x", sources: ["s"], confidence: 0.9,
                status: .applied, createdAt: fixedDate)
            try LearnedRulesStore.save(LearnedRulesFile(
                version: 5, artifacts: [.contextDoc(doc)]))
            LearnedRulesStore.reload()

            let count = KBCompoundBridge.invalidateDerivedContext(
                entityName: "SessionDatabase",
                entitySourcePath: "Sources/Core/SessionDatabase.swift")
            #expect(count >= 1)

            LearnedRulesStore.reload()
            let reloaded = LearnedRulesStore.shared.contextDocs.first
            #expect(reloaded?.status == .recurring)
        }
    }
}

@Suite("KBCompoundBridge — helpers")
struct KBBridgeHelperTests {

    @Test func camelCaseFromSlug() {
        #expect(KBCompoundBridge.camelCase(from: "sources-foo-bar") == "SourcesFooBar")
        #expect(KBCompoundBridge.camelCase(from: "session-database") == "SessionDatabase")
        #expect(KBCompoundBridge.camelCase(from: "x") == "X")
    }
}
