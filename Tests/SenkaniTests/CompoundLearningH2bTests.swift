import Testing
import Foundation
@testable import Core

// MARK: - Fixture helpers

private let fixedDate = Date(timeIntervalSince1970: 1_713_360_000)

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-h2b-\(UUID().uuidString)/senkani.db"
    return (SessionDatabase(path: path), path)
}

private func cleanupDB(path: String) {
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.removeItem(atPath: dir)
}

// MARK: - LearnedContextDoc validation

@Suite("LearnedContextDoc sanitizers (H+2b Schneier)")
struct LearnedContextDocSanitizerTests {

    @Test func titleIsFilesystemSafe() {
        #expect(LearnedContextDoc.sanitizeTitle("Sources/Foo/Bar.swift")
            == "sources-foo-bar-swift")
        #expect(LearnedContextDoc.sanitizeTitle("../../etc/passwd")
            == "etc-passwd",
            "path-traversal attempt reduced to safe slug")
        #expect(LearnedContextDoc.sanitizeTitle("   ")
            == "context",
            "empty input gets fallback slug")
    }

    @Test func titleCappedAtMaxLength() {
        let long = String(repeating: "a", count: 500)
        let slug = LearnedContextDoc.sanitizeTitle(long)
        #expect(slug.count <= LearnedContextDoc.maxTitleChars)
    }

    @Test func bodyRedactsSecrets() {
        let key = "sk-ant-api03-" + String(repeating: "X", count: 85)
        let body = "This file uses the API key \(key) for auth."
        let sanitized = LearnedContextDoc.sanitizeBody(body)
        #expect(!sanitized.contains(key))
    }

    @Test func bodyCappedAtMaxBytes() {
        let huge = String(repeating: "a", count: 10_000)
        let sanitized = LearnedContextDoc.sanitizeBody(huge)
        #expect(sanitized.utf8.count <= LearnedContextDoc.maxBodyBytes)
    }

    @Test func initRunsBothSanitizers() {
        let doc = LearnedContextDoc(
            id: "abc",
            title: "Sources/Unsafe Path.swift",
            body: String(repeating: "x", count: 5000),
            sources: ["s1"],
            confidence: 0.8,
            createdAt: fixedDate
        )
        #expect(!doc.title.contains("/"))
        #expect(!doc.title.contains(" "))
        #expect(doc.body.utf8.count <= LearnedContextDoc.maxBodyBytes)
    }

    @Test func decodeReSanitizes() throws {
        let maliciousJSON = """
        {
          "id": "x",
          "title": "../etc/passwd",
          "body": "benign",
          "sources": [],
          "confidence": 0.5,
          "status": "recurring",
          "createdAt": "2026-04-17T00:00:00Z"
        }
        """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let doc = try dec.decode(LearnedContextDoc.self, from: Data(maliciousJSON.utf8))
        #expect(!doc.title.contains(".."))
        #expect(!doc.title.contains("/"))
    }
}

// MARK: - v3 → v4 migration (Celko)

@Suite("LearnedRulesFile v3 → v4 polymorphic migration (H+2b)")
struct LearnedRulesV4MigrationTests {

    @Test func v3FlatRulesArrayMigratesToArtifacts() throws {
        let v3 = """
        {
          "version": 3,
          "rules": [
            {
              "id": "r1",
              "command": "docker",
              "subcommand": "compose",
              "ops": ["head(50)"],
              "source": "s-old",
              "confidence": 0.9,
              "status": "applied",
              "sessionCount": 5,
              "createdAt": "2026-04-15T10:00:00Z",
              "rationale": "head(50) caps output.",
              "signalType": "failure",
              "recurrenceCount": 5,
              "lastSeenAt": "2026-04-17T00:00:00Z",
              "sources": ["s-old"]
            }
          ]
        }
        """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let file = try dec.decode(LearnedRulesFile.self, from: Data(v3.utf8))
        #expect(file.artifacts.count == 1)
        guard case .filterRule(let rule) = file.artifacts[0] else {
            Issue.record("v3 rule must decode as .filterRule case"); return
        }
        #expect(rule.command == "docker")
        #expect(rule.status == .applied)
    }

    @Test func v4PolymorphicDecodeRoundTripsBothCases() throws {
        let filterRule = LearnedFilterRule(
            id: "fr-1", command: "mycli", subcommand: nil,
            ops: ["head(50)"], source: "s1", confidence: 0.9,
            status: .staged, sessionCount: 3, createdAt: fixedDate
        )
        let contextDoc = LearnedContextDoc(
            id: "cd-1", title: "sources-foo",
            body: "# sources-foo\n\nRecurring file.", sources: ["s1"],
            confidence: 0.85, status: .applied, createdAt: fixedDate
        )
        let file = LearnedRulesFile(version: 4, artifacts: [
            .filterRule(filterRule), .contextDoc(contextDoc)
        ])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(file)

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let reloaded = try dec.decode(LearnedRulesFile.self, from: data)
        #expect(reloaded.artifacts.count == 2)
        #expect(reloaded.rules.count == 1)
        #expect(reloaded.contextDocs.count == 1)
        #expect(reloaded.rules[0].command == "mycli")
        #expect(reloaded.contextDocs[0].title == "sources-foo")
    }

    @Test func rulesComputedSetterPreservesContextDocs() {
        let filterRule = LearnedFilterRule(
            id: "fr-1", command: "mycli", subcommand: nil,
            ops: ["head(50)"], source: "s1", confidence: 0.9,
            status: .staged, sessionCount: 3, createdAt: fixedDate
        )
        let contextDoc = LearnedContextDoc(
            id: "cd-1", title: "sources-foo",
            body: "# sources-foo\n\nx.", sources: ["s1"],
            confidence: 0.9, status: .applied, createdAt: fixedDate
        )
        var file = LearnedRulesFile(version: 4, artifacts: [
            .filterRule(filterRule), .contextDoc(contextDoc)
        ])
        // Mutate the rules view — context doc must survive.
        let newRule = LearnedFilterRule(
            id: "fr-2", command: "other", subcommand: nil,
            ops: ["head(30)"], source: "s2", confidence: 0.9,
            status: .staged, sessionCount: 3, createdAt: fixedDate
        )
        file.rules = [newRule]
        #expect(file.rules.map(\.id) == ["fr-2"])
        #expect(file.contextDocs.map(\.id) == ["cd-1"],
            "setter must not wipe context docs")
    }

    @Test func decoderRejectsUnknownArtifactTag() {
        let unknown = """
        {
          "version": 4,
          "artifacts": [
            { "type": "instructionPatch", "payload": {} }
          ]
        }
        """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        #expect(throws: DecodingError.self) {
            try dec.decode(LearnedRulesFile.self, from: Data(unknown.utf8))
        }
    }
}

// MARK: - SessionDatabase.recurringFileMentions

@Suite("SessionDatabase.recurringFileMentions (H+2b)")
struct RecurringFileMentionsTests {

    private func seedRead(
        db: SessionDatabase, session: String,
        root: String, path: String
    ) {
        db.recordTokenEvent(
            sessionId: session, paneId: nil, projectRoot: root,
            source: "mcp_tool", toolName: "read", model: nil,
            inputTokens: 200, outputTokens: 10, savedTokens: 80,
            costCents: 1, feature: "cache", command: path
        )
    }

    @Test func detectsFilesAcrossThreeDistinctSessions() {
        let (db, path) = makeTempDB(); defer { cleanupDB(path: path) }
        let root = "/tmp/h2b-recur-yes"
        let filePath = "Sources/Core/Target.swift"
        let s1 = db.createSession(projectRoot: root)
        let s2 = db.createSession(projectRoot: root)
        let s3 = db.createSession(projectRoot: root)
        seedRead(db: db, session: s1, root: root, path: filePath)
        seedRead(db: db, session: s2, root: root, path: filePath)
        seedRead(db: db, session: s3, root: root, path: filePath)
        Thread.sleep(forTimeInterval: 0.05)

        let rows = db.recurringFileMentions(projectRoot: root, minSessions: 3)
        #expect(rows.count == 1)
        #expect(rows[0].path == filePath)
        #expect(rows[0].sessionCount >= 3)
    }

    @Test func excludesFilesBelowSessionThreshold() {
        let (db, path) = makeTempDB(); defer { cleanupDB(path: path) }
        let root = "/tmp/h2b-recur-no"
        let s1 = db.createSession(projectRoot: root)
        seedRead(db: db, session: s1, root: root, path: "Sources/One.swift")
        seedRead(db: db, session: s1, root: root, path: "Sources/One.swift")
        Thread.sleep(forTimeInterval: 0.05)

        let rows = db.recurringFileMentions(projectRoot: root, minSessions: 3)
        #expect(rows.isEmpty, "single-session mentions don't qualify as recurring")
    }

    @Test func excludesExecCommands() {
        let (db, path) = makeTempDB(); defer { cleanupDB(path: path) }
        let root = "/tmp/h2b-recur-exec"
        for _ in 0..<3 {
            let sid = db.createSession(projectRoot: root)
            db.recordTokenEvent(
                sessionId: sid, paneId: nil, projectRoot: root,
                source: "mcp_tool", toolName: "exec", model: nil,
                inputTokens: 200, outputTokens: 10, savedTokens: 10,
                costCents: 1, feature: "filter", command: "git status"
            )
        }
        Thread.sleep(forTimeInterval: 0.05)
        let rows = db.recurringFileMentions(projectRoot: root, minSessions: 3)
        #expect(rows.isEmpty,
            "exec commands are NOT files — must not appear in recurring-file-mentions")
    }
}

// MARK: - ContextSignalGenerator

@Suite("ContextSignalGenerator (H+2b)")
struct ContextSignalGeneratorTests {

    private func seedRead(
        db: SessionDatabase, session: String,
        root: String, path: String
    ) {
        db.recordTokenEvent(
            sessionId: session, paneId: nil, projectRoot: root,
            source: "mcp_tool", toolName: "read", model: nil,
            inputTokens: 200, outputTokens: 10, savedTokens: 80,
            costCents: 1, feature: "cache", command: path
        )
    }

    @Test func emitsContextDocPerRecurringFile() {
        let (db, path) = makeTempDB(); defer { cleanupDB(path: path) }
        let root = "/tmp/h2b-gen-yes"
        let filePath = "Sources/Core/Target.swift"
        for i in 0..<3 {
            let s = db.createSession(projectRoot: root)
            _ = i
            seedRead(db: db, session: s, root: root, path: filePath)
        }
        Thread.sleep(forTimeInterval: 0.05)

        let proposals = ContextSignalGenerator.analyze(
            projectRoot: root, sessionId: "test-sid", db: db,
            minSessions: 3
        )
        #expect(proposals.count == 1)
        let p = proposals[0]
        #expect(p.status == .recurring)
        #expect(p.title.hasPrefix("core-target"))
        #expect(p.body.contains("3 distinct sessions"))
        #expect(p.sessionCount >= 3)
        #expect(p.confidence > 0.5)
    }

    @Test func emitsEmptyWhenNoRecurringFiles() {
        let (db, path) = makeTempDB(); defer { cleanupDB(path: path) }
        let root = "/tmp/h2b-gen-empty"
        let proposals = ContextSignalGenerator.analyze(
            projectRoot: root, sessionId: "test-sid", db: db,
            minSessions: 3
        )
        #expect(proposals.isEmpty)
    }

    @Test func titleUsesLastTwoPathComponents() {
        // Collision-avoidance test — two files with the same basename
        // in different dirs should produce distinct titles.
        let title1 = ContextSignalGenerator.titleForPath("Sources/A/Types.swift")
        let title2 = ContextSignalGenerator.titleForPath("Sources/B/Types.swift")
        #expect(title1 != title2,
            "same basename in different dirs must produce distinct slugs")
    }
}

// MARK: - Context store mutations (observe, promote, apply, reject)

@Suite("Context artifact lifecycle (H+2b)", .serialized)
struct ContextArtifactLifecycleTests {

    private func withTempStore(_ body: () throws -> Void) rethrows {
        let temp = NSTemporaryDirectory() + "senkani-h2b-ctx-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        try LearnedRulesStore.withPath(temp, body)
    }

    private func sampleDoc(
        id: String = UUID().uuidString,
        title: String = "sources-foo",
        status: LearnedRuleStatus = .recurring,
        recurrenceCount: Int = 1
    ) -> LearnedContextDoc {
        LearnedContextDoc(
            id: id, title: title,
            body: "# \(title)\n\nSeen across sessions.",
            sources: ["s-1"], confidence: 0.85,
            status: status, createdAt: fixedDate,
            recurrenceCount: recurrenceCount, sessionCount: 3
        )
    }

    @Test func observeAppendsNewDoc() throws {
        try withTempStore {
            try LearnedRulesStore.observeContextDoc(sampleDoc())
            let loaded = LearnedRulesStore.load()!
            #expect(loaded.contextDocs.count == 1)
            #expect(loaded.contextDocs[0].status == .recurring)
        }
    }

    @Test func observeMergesDuplicateByTitleAndBumpsRecurrence() throws {
        try withTempStore {
            try LearnedRulesStore.observeContextDoc(sampleDoc(id: "a"))
            try LearnedRulesStore.observeContextDoc(
                LearnedContextDoc(
                    id: "b", title: "sources-foo",
                    body: "new evidence", sources: ["s-2"],
                    confidence: 0.85, status: .recurring, createdAt: fixedDate,
                    recurrenceCount: 1, sessionCount: 5))
            let loaded = LearnedRulesStore.load()!
            #expect(loaded.contextDocs.count == 1,
                "same-title observations merge")
            #expect(loaded.contextDocs[0].recurrenceCount == 2)
            #expect(loaded.contextDocs[0].sessionCount == 5,
                "session count grows monotonically")
            #expect(loaded.contextDocs[0].sources.contains("s-2"))
        }
    }

    @Test func observeRespectsRejectedStatus() throws {
        try withTempStore {
            try LearnedRulesStore.save(LearnedRulesFile(
                version: 4,
                artifacts: [.contextDoc(sampleDoc(id: "a", status: .rejected))]
            ))
            LearnedRulesStore.reload()

            try LearnedRulesStore.observeContextDoc(sampleDoc(id: "b"))
            let loaded = LearnedRulesStore.load()!
            #expect(loaded.contextDocs.count == 1,
                "rejected doc must not be resurrected")
            #expect(loaded.contextDocs[0].status == .rejected)
        }
    }

    @Test func promoteRecurringToStaged() throws {
        try withTempStore {
            let doc = sampleDoc(id: "p", recurrenceCount: 3)
            try LearnedRulesStore.save(LearnedRulesFile(
                version: 4, artifacts: [.contextDoc(doc)]))
            LearnedRulesStore.reload()

            try LearnedRulesStore.promoteContextDocToStaged(id: "p")
            let loaded = LearnedRulesStore.load()!
            #expect(loaded.contextDocs.first?.status == .staged)
        }
    }

    @Test func applyContextDocWritesFileAndUpdatesStatus() throws {
        try withTempStore {
            let root = NSTemporaryDirectory() + "h2b-apply-\(UUID().uuidString)"
            try FileManager.default.createDirectory(
                atPath: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: root) }

            let doc = sampleDoc(id: "app-1", status: .staged)
            try LearnedRulesStore.save(LearnedRulesFile(
                version: 4, artifacts: [.contextDoc(doc)]))
            LearnedRulesStore.reload()

            let (db, dbPath) = makeTempDB()
            defer { cleanupDB(path: dbPath) }
            try CompoundLearning.applyContextDoc(
                id: "app-1", projectRoot: root, db: db)

            let reloaded = LearnedRulesStore.load()!
            #expect(reloaded.contextDocs.first?.status == .applied)

            let filePath = root + "/.senkani/context/sources-foo.md"
            #expect(FileManager.default.fileExists(atPath: filePath),
                "applied doc must land on disk")
            let body = try String(contentsOfFile: filePath, encoding: .utf8)
            #expect(body.contains("sources-foo"))
        }
    }
}

// MARK: - Daily sweep + post-session orchestration

@Suite("Context signal orchestration (H+2b)", .serialized)
struct ContextOrchestrationTests {

    private func totalCount(for prefix: String, in db: SessionDatabase) -> Int {
        db.eventCounts(prefix: prefix).reduce(0) { $0 + $1.count }
    }

    @Test func runPostSessionProposesContextSignal() async throws {
        let (db, dbPath) = makeTempDB(); defer { cleanupDB(path: dbPath) }
        let root = "/tmp/h2b-orch-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        // Seed: one file read across 3 sessions.
        let filePath = "Sources/Core/Target.swift"
        for _ in 0..<3 {
            let s = db.createSession(projectRoot: root)
            db.recordTokenEvent(
                sessionId: s, paneId: nil, projectRoot: root,
                source: "mcp_tool", toolName: "read", model: nil,
                inputTokens: 200, outputTokens: 10, savedTokens: 80,
                costCents: 1, feature: "cache", command: filePath)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        let temp = NSTemporaryDirectory() + "senkani-h2b-orch-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        // Swift 6: withPath can't hold NSLock across await. Run the
        // async body in a detached Task and block via semaphore.
        let rootCopy: String = root
        try LearnedRulesStore.withPath(temp) {
            let sem = DispatchSemaphore(value: 0)
            Task { [db] in
                await CompoundLearning.runPostSession(
                    sessionId: "sid-under-test",
                    projectRoot: rootCopy,
                    db: db)
                sem.signal()
            }
            sem.wait()
        }

        let proposedCounter = totalCount(
            for: "compound_learning.context.proposed", in: db)
        #expect(proposedCounter >= 1,
            "recurring-file detection must bump the proposed counter")
    }

    @Test func dailySweepPromotesContextDoc() throws {
        let (db, dbPath) = makeTempDB(); defer { cleanupDB(path: dbPath) }
        let temp = NSTemporaryDirectory() + "senkani-h2b-sweep-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: temp) }

        try LearnedRulesStore.withPath(temp) {
            // A context doc meeting both thresholds (recurrence 3,
            // confidence 0.8 — above the 0.7 daily gate).
            let doc = LearnedContextDoc(
                id: "cd-promote", title: "sources-foo",
                body: "body", sources: ["s1", "s2", "s3"],
                confidence: 0.85, status: .recurring, createdAt: fixedDate,
                recurrenceCount: 3, sessionCount: 3)
            try LearnedRulesStore.save(LearnedRulesFile(
                version: 4, artifacts: [.contextDoc(doc)]))
            LearnedRulesStore.reload()

            _ = CompoundLearning.runDailySweep(db: db)

            let after = LearnedRulesStore.load()!
            #expect(after.contextDocs.first?.status == .staged)

            let promoted = totalCount(
                for: "compound_learning.context.promoted", in: db)
            #expect(promoted >= 1)
        }
    }
}

// MARK: - Session-brief integration

@Suite("SessionBriefGenerator with context docs (H+2b)")
struct SessionBriefWithContextTests {

    @Test func emitsEmptyWhenNeitherActivityNorDocsPresent() {
        let brief = SessionBriefGenerator.generate(
            lastActivity: nil,
            appliedContextDocs: []
        )
        #expect(brief.isEmpty)
    }

    @Test func emitsContextSectionWithoutPriorActivity() {
        let doc = LearnedContextDoc(
            id: "x", title: "sources-auth",
            body: "AuthManager handles session tokens.",
            sources: [], confidence: 0.9,
            status: .applied, createdAt: fixedDate)
        let brief = SessionBriefGenerator.generate(
            lastActivity: nil,
            appliedContextDocs: [doc]
        )
        #expect(brief.contains("Learned:"))
        #expect(brief.contains("sources-auth"))
        #expect(brief.contains("AuthManager handles session tokens"))
    }

    @Test func mergesContextSectionBelowActivity() {
        let activity = SessionDatabase.LastSessionActivity(
            sessionId: "s1",
            startedAt: fixedDate,
            endedAt: fixedDate,
            durationSeconds: 300,
            commandCount: 12,
            totalSavedTokens: 800,
            totalRawTokens: 1000,
            lastCommand: "swift build",
            recentSearchQueries: [],
            topHotFiles: ["Sources/Core.swift"]
        )
        let doc = LearnedContextDoc(
            id: "x", title: "sources-foo",
            body: "Recurring file across sessions.",
            sources: [], confidence: 0.9,
            status: .applied, createdAt: fixedDate)
        let brief = SessionBriefGenerator.generate(
            lastActivity: activity,
            appliedContextDocs: [doc]
        )
        #expect(brief.contains("Last session"))
        #expect(brief.contains("Learned:"))
        // Activity section precedes Learned: section.
        let lastPos = brief.range(of: "Last session")!.lowerBound
        let learnedPos = brief.range(of: "Learned:")!.lowerBound
        #expect(lastPos < learnedPos)
    }

    @Test func respectsTokenBudget() {
        let bigDoc = LearnedContextDoc(
            id: "x", title: "sources-huge",
            body: String(repeating: "word ", count: 500),
            sources: [], confidence: 0.9,
            status: .applied, createdAt: fixedDate)
        let brief = SessionBriefGenerator.generate(
            lastActivity: nil,
            appliedContextDocs: [bigDoc],
            maxTokens: 60 // 240 chars
        )
        #expect(brief.count <= 240)
    }
}
