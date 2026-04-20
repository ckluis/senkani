import Testing
import Foundation
@testable import Core

// MARK: - Helpers

private let now = Date(timeIntervalSince1970: 1_713_360_000) // 2024-04-17

private func withTempStore(_ body: () throws -> Void) rethrows {
    let tmp = NSTemporaryDirectory() + "senkani-sprintvm-\(UUID().uuidString).json"
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    try LearnedRulesStore.withPath(tmp, body)
}

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-sprintvm-db-\(UUID().uuidString)/senkani.db"
    let db = SessionDatabase(path: path)
    return (db, path)
}

private func cleanupDB(path: String) {
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.removeItem(atPath: dir)
}

private func makeTempRoot() -> String {
    let root = NSTemporaryDirectory()
        + "senkani-sprintvm-root-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(
        atPath: root, withIntermediateDirectories: true)
    return root
}

private func seedFilterRule(
    id: String,
    status: LearnedRuleStatus = .staged,
    lastSeenAt: Date = now
) -> LearnedFilterRule {
    LearnedFilterRule(
        id: id, command: "cmd-\(id)", subcommand: "sub",
        ops: ["head(50)"], source: "signal", confidence: 0.82,
        status: status, sessionCount: 3, createdAt: now,
        rationale: "rationale-\(id)",
        recurrenceCount: 5,
        lastSeenAt: lastSeenAt
    )
}

private func seedContextDoc(
    id: String,
    status: LearnedRuleStatus = .staged,
    lastSeenAt: Date = now
) -> LearnedContextDoc {
    LearnedContextDoc(
        id: id, title: "doc-\(id)", body: "b", sources: ["s1", "s2"],
        confidence: 0.75, status: status, createdAt: now,
        lastSeenAt: lastSeenAt, recurrenceCount: 4, sessionCount: 2
    )
}

private func seedInstructionPatch(
    id: String,
    status: LearnedRuleStatus = .staged,
    lastSeenAt: Date = now
) -> LearnedInstructionPatch {
    LearnedInstructionPatch(
        id: id, toolName: "exec", hint: "hint body",
        sources: ["s1"], confidence: 0.66, status: status,
        createdAt: now, lastSeenAt: lastSeenAt,
        recurrenceCount: 6, sessionCount: 3
    )
}

private func seedWorkflowPlaybook(
    id: String,
    status: LearnedRuleStatus = .staged,
    lastSeenAt: Date = now
) -> LearnedWorkflowPlaybook {
    LearnedWorkflowPlaybook(
        id: id, title: "wf-\(id)", description: "d",
        steps: [
            LearnedWorkflowStep(toolName: "a", example: "a x"),
            LearnedWorkflowStep(toolName: "b", example: "b y"),
            LearnedWorkflowStep(toolName: "c", example: "c z"),
        ],
        sources: ["s1"], confidence: 0.71, status: status,
        createdAt: now, lastSeenAt: lastSeenAt,
        recurrenceCount: 7, sessionCount: 4
    )
}

// MARK: - Snapshot shape

@Suite("SprintReviewViewModel — snapshot", .serialized)
struct SprintReviewSnapshotTests {

    @Test func emptyStoreYieldsEmptySnapshot() throws {
        try withTempStore {
            try LearnedRulesStore.save(.empty)
            let snap = SprintReviewViewModel.load(windowDays: 14, now: now)
            #expect(snap.isEmpty)
            #expect(snap.totalCount == 0)
            #expect(snap.sections.isEmpty)
            #expect(snap.stalenessFlags.isEmpty)
            #expect(snap.windowDays == 14)
        }
    }

    @Test func snapshotGroupsAllFourKinds() throws {
        try withTempStore {
            try LearnedRulesStore.save(LearnedRulesFile(version: 5, artifacts: [
                .filterRule(seedFilterRule(id: "r1")),
                .contextDoc(seedContextDoc(id: "c1")),
                .instructionPatch(seedInstructionPatch(id: "i1")),
                .workflowPlaybook(seedWorkflowPlaybook(id: "w1")),
            ]))
            LearnedRulesStore.reload()

            let snap = SprintReviewViewModel.load(windowDays: 14, now: now)
            #expect(snap.totalCount == 4)
            let kinds = snap.sections.map(\.kind)
            #expect(kinds == [.filterRule, .contextDoc, .instructionPatch, .workflowPlaybook])
        }
    }

    @Test func filterRuleRowShapesCommandWithSubcommand() throws {
        try withTempStore {
            let rule = seedFilterRule(id: "r1")
            try LearnedRulesStore.save(LearnedRulesFile(
                version: 5, artifacts: [.filterRule(rule)]))
            LearnedRulesStore.reload()

            let snap = SprintReviewViewModel.load(windowDays: 14, now: now)
            let row = snap.sections.first!.rows.first!
            #expect(row.id == "r1")
            #expect(row.title == "cmd-r1/sub")
            #expect(row.subtitle == "rationale-r1")
            #expect(row.recurrenceCount == 5)
            #expect(row.confidence == 0.82)
        }
    }

    @Test func workflowSubtitlePluralizesSteps() throws {
        try withTempStore {
            let single = LearnedWorkflowPlaybook(
                id: "one", title: "one-step", description: "d",
                steps: [LearnedWorkflowStep(toolName: "a", example: "a")],
                sources: [], confidence: 0.5, status: .staged,
                createdAt: now, lastSeenAt: now)
            let many = seedWorkflowPlaybook(id: "many")
            try LearnedRulesStore.save(LearnedRulesFile(version: 5, artifacts: [
                .workflowPlaybook(single),
                .workflowPlaybook(many),
            ]))
            LearnedRulesStore.reload()

            let snap = SprintReviewViewModel.load(windowDays: 14, now: now)
            let rows = snap.sections.first!.rows
            let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.subtitle) })
            #expect(byId["one"] == "1 step")
            #expect(byId["many"] == "3 steps")
        }
    }

    @Test func windowFilterHidesOlderArtifacts() throws {
        try withTempStore {
            let recent = seedFilterRule(id: "recent",
                lastSeenAt: now.addingTimeInterval(-3 * 86400))
            let old = seedFilterRule(id: "old",
                lastSeenAt: now.addingTimeInterval(-30 * 86400))
            try LearnedRulesStore.save(LearnedRulesFile(version: 5, artifacts: [
                .filterRule(recent), .filterRule(old)]))
            LearnedRulesStore.reload()

            let snap = SprintReviewViewModel.load(windowDays: 7, now: now)
            #expect(snap.sections.first!.rows.map(\.id) == ["recent"])
        }
    }

    @Test func appliedStaleItemSurfacesInStalenessFlags() throws {
        try withTempStore {
            let stale = seedFilterRule(
                id: "stale", status: .applied,
                lastSeenAt: now.addingTimeInterval(-120 * 86400))
            try LearnedRulesStore.save(LearnedRulesFile(
                version: 5, artifacts: [.filterRule(stale)]))
            LearnedRulesStore.reload()

            let snap = SprintReviewViewModel.load(
                windowDays: 14, appliedIdleDays: 60, now: now)
            #expect(snap.sections.isEmpty)  // not staged
            #expect(snap.stalenessFlags.count == 1)
            let flag = snap.stalenessFlags.first!
            #expect(flag.artifactId == "stale")
            #expect(flag.kind == .filterRule)
            #expect(flag.idleDays >= 120)
        }
    }
}

// MARK: - Accept / reject routing

@Suite("SprintReviewViewModel — accept + reject", .serialized)
struct SprintReviewActionTests {

    @Test func acceptFilterRulePromotesToApplied() throws {
        try withTempStore {
            try LearnedRulesStore.save(LearnedRulesFile(
                version: 5, artifacts: [.filterRule(seedFilterRule(id: "rf1"))]))
            LearnedRulesStore.reload()
            let (db, dbPath) = makeTempDB()
            defer { cleanupDB(path: dbPath) }
            let root = makeTempRoot()
            defer { try? FileManager.default.removeItem(atPath: root) }

            try SprintReviewViewModel.accept(
                rowId: "rf1", kind: .filterRule,
                projectRoot: root, db: db)

            let loaded = LearnedRulesStore.load()!
            #expect(loaded.rules.first?.status == .applied)
        }
    }

    @Test func acceptContextDocWritesFileAndApplies() throws {
        try withTempStore {
            try LearnedRulesStore.save(LearnedRulesFile(
                version: 5, artifacts: [.contextDoc(seedContextDoc(id: "cd1"))]))
            LearnedRulesStore.reload()
            let (db, dbPath) = makeTempDB()
            defer { cleanupDB(path: dbPath) }
            let root = makeTempRoot()
            defer { try? FileManager.default.removeItem(atPath: root) }

            try SprintReviewViewModel.accept(
                rowId: "cd1", kind: .contextDoc,
                projectRoot: root, db: db)

            let loaded = LearnedRulesStore.load()!
            #expect(loaded.contextDocs.first?.status == .applied)
            let path = root + "/.senkani/context/doc-cd1.md"
            #expect(FileManager.default.fileExists(atPath: path),
                "applied context doc must land on disk")
        }
    }

    @Test func acceptInstructionPatchPromotesToApplied() throws {
        try withTempStore {
            try LearnedRulesStore.save(LearnedRulesFile(
                version: 5,
                artifacts: [.instructionPatch(seedInstructionPatch(id: "ip1"))]))
            LearnedRulesStore.reload()
            let (db, dbPath) = makeTempDB()
            defer { cleanupDB(path: dbPath) }
            let root = makeTempRoot()
            defer { try? FileManager.default.removeItem(atPath: root) }

            try SprintReviewViewModel.accept(
                rowId: "ip1", kind: .instructionPatch,
                projectRoot: root, db: db)

            let loaded = LearnedRulesStore.load()!
            #expect(loaded.instructionPatches.first?.status == .applied)
        }
    }

    @Test func acceptWorkflowPlaybookWritesFileAndApplies() throws {
        try withTempStore {
            try LearnedRulesStore.save(LearnedRulesFile(
                version: 5,
                artifacts: [.workflowPlaybook(seedWorkflowPlaybook(id: "wp1"))]))
            LearnedRulesStore.reload()
            let (db, dbPath) = makeTempDB()
            defer { cleanupDB(path: dbPath) }
            let root = makeTempRoot()
            defer { try? FileManager.default.removeItem(atPath: root) }

            try SprintReviewViewModel.accept(
                rowId: "wp1", kind: .workflowPlaybook,
                projectRoot: root, db: db)

            let loaded = LearnedRulesStore.load()!
            #expect(loaded.workflowPlaybooks.first?.status == .applied)
            let path = root + "/.senkani/playbooks/learned/wf-wp1.md"
            #expect(FileManager.default.fileExists(atPath: path),
                "applied playbook must land on disk")
        }
    }

    @Test func rejectFilterRuleMovesToRejected() throws {
        try withTempStore {
            try LearnedRulesStore.save(LearnedRulesFile(
                version: 5, artifacts: [.filterRule(seedFilterRule(id: "rj1"))]))
            LearnedRulesStore.reload()

            try SprintReviewViewModel.reject(
                rowId: "rj1", kind: .filterRule)

            let loaded = LearnedRulesStore.load()!
            #expect(loaded.rules.first?.status == .rejected)
        }
    }

    @Test func rejectRoutesEveryKindToTypedRejectMethod() throws {
        try withTempStore {
            try LearnedRulesStore.save(LearnedRulesFile(version: 5, artifacts: [
                .filterRule(seedFilterRule(id: "r")),
                .contextDoc(seedContextDoc(id: "c")),
                .instructionPatch(seedInstructionPatch(id: "i")),
                .workflowPlaybook(seedWorkflowPlaybook(id: "w")),
            ]))
            LearnedRulesStore.reload()

            try SprintReviewViewModel.reject(rowId: "r", kind: .filterRule)
            try SprintReviewViewModel.reject(rowId: "c", kind: .contextDoc)
            try SprintReviewViewModel.reject(rowId: "i", kind: .instructionPatch)
            try SprintReviewViewModel.reject(rowId: "w", kind: .workflowPlaybook)

            let loaded = LearnedRulesStore.load()!
            #expect(loaded.rules.first?.status == .rejected)
            #expect(loaded.contextDocs.first?.status == .rejected)
            #expect(loaded.instructionPatches.first?.status == .rejected)
            #expect(loaded.workflowPlaybooks.first?.status == .rejected)
        }
    }

    @Test func rejectedItemNoLongerAppearsInNextSnapshot() throws {
        try withTempStore {
            try LearnedRulesStore.save(LearnedRulesFile(version: 5, artifacts: [
                .filterRule(seedFilterRule(id: "a")),
                .filterRule(seedFilterRule(id: "b")),
            ]))
            LearnedRulesStore.reload()

            try SprintReviewViewModel.reject(rowId: "a", kind: .filterRule)
            let snap = SprintReviewViewModel.load(windowDays: 14, now: now)
            #expect(snap.sections.first?.rows.map(\.id) == ["b"])
        }
    }
}
