import Testing
import Foundation
@testable import Core

// MARK: - ContextDocStore tests

private let fixedDate = Date(timeIntervalSince1970: 1_713_360_000)

private func makeDoc(
    id: String = UUID().uuidString,
    title: String = "build-pipeline",
    body: String = "Notes about the build pipeline.",
    sources: [String] = ["s-1"],
    status: LearnedRuleStatus = .recurring
) -> LearnedContextDoc {
    LearnedContextDoc(
        id: id, title: title, body: body, sources: sources,
        confidence: 0.85, status: status, createdAt: fixedDate
    )
}

@Suite("ContextDocStore lifecycle", .serialized)
struct ContextDocStoreTests {

    private func withTempStore(_ body: () throws -> Void) rethrows {
        let temp = NSTemporaryDirectory() + "senkani-cds-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        try LearnedRulesStore.withPath(temp, body)
    }

    @Test func observeAppendsNewDocAsRecurring() throws {
        try withTempStore {
            try LearnedRulesStore.observeContextDoc(makeDoc(id: "d-1"))
            let docs = LearnedRulesStore.load()!.contextDocs
            #expect(docs.count == 1)
            #expect(docs[0].status == .recurring)
        }
    }

    @Test func observeMergesByTitleAndBumpsRecurrence() throws {
        try withTempStore {
            try LearnedRulesStore.observeContextDoc(makeDoc(id: "d-1", sources: ["s-1"]))
            try LearnedRulesStore.observeContextDoc(makeDoc(id: "d-2", sources: ["s-2"]))
            let docs = LearnedRulesStore.load()!.contextDocs
            #expect(docs.count == 1, "same title → merged")
            #expect(docs[0].recurrenceCount == 2)
            #expect(docs[0].sources.contains("s-2"))
        }
    }

    @Test func observeRespectsRejectedStickiness() throws {
        try withTempStore {
            try LearnedRulesStore.observeContextDoc(makeDoc(id: "d-1"))
            let id = LearnedRulesStore.load()!.contextDocs[0].id
            try LearnedRulesStore.rejectContextDoc(id: id)
            try LearnedRulesStore.observeContextDoc(makeDoc(id: "d-2"))
            let docs = LearnedRulesStore.load()!.contextDocs
            #expect(docs.count == 1)
            #expect(docs[0].status == .rejected)
            #expect(docs[0].recurrenceCount == 1)
        }
    }

    @Test func promoteAndApplyTransitions() throws {
        try withTempStore {
            try LearnedRulesStore.observeContextDoc(makeDoc(id: "d-1"))
            let id = LearnedRulesStore.load()!.contextDocs[0].id
            try LearnedRulesStore.promoteContextDocToStaged(id: id)
            #expect(LearnedRulesStore.load()!.contextDocs[0].status == .staged)
            try LearnedRulesStore.applyContextDoc(id: id)
            #expect(LearnedRulesStore.load()!.contextDocs[0].status == .applied)
            // applyContextDoc on a non-staged doc is a no-op.
            try LearnedRulesStore.applyContextDoc(id: id)
            #expect(LearnedRulesStore.load()!.contextDocs[0].status == .applied)
        }
    }

    @Test func contextDocsInStatusFiltersAndSortsDesc() throws {
        try withTempStore {
            let older = makeDoc(id: "old", title: "alpha", status: .applied)
            let newerDate = fixedDate.addingTimeInterval(3600)
            let newer = LearnedContextDoc(
                id: "new", title: "beta", body: "n",
                sources: ["s"], confidence: 0.9, status: .applied,
                createdAt: newerDate
            )
            try LearnedRulesStore.save(LearnedRulesFile(
                version: 5,
                artifacts: [.contextDoc(older), .contextDoc(newer)]))
            LearnedRulesStore.reload()
            let applied = LearnedRulesStore.contextDocs(inStatus: .applied)
            #expect(applied.map(\.id) == ["new", "old"])
        }
    }

    @Test func appliedContextDocsIsAliasForAppliedStatus() throws {
        try withTempStore {
            let r = makeDoc(id: "r", title: "recur", status: .recurring)
            let a = makeDoc(id: "a", title: "appl", status: .applied)
            try LearnedRulesStore.save(LearnedRulesFile(
                version: 5,
                artifacts: [.contextDoc(r), .contextDoc(a)]))
            LearnedRulesStore.reload()
            let docs = LearnedRulesStore.appliedContextDocs()
            #expect(docs.map(\.id) == ["a"])
        }
    }
}
