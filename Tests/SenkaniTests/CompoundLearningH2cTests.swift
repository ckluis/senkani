import Testing
import Foundation
@testable import Core

private let fixedDate = Date(timeIntervalSince1970: 1_713_360_000)

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-h2c-\(UUID().uuidString)/senkani.db"
    return (SessionDatabase(path: path), path)
}

private func cleanupDB(path: String) {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
}

// MARK: - Sanitizer tests (Schneier)

@Suite("LearnedInstructionPatch + WorkflowPlaybook sanitizers (H+2c Schneier)")
struct H2cSanitizerTests {

    @Test func toolNameRejectsSpecialChars() {
        #expect(LearnedInstructionPatch.sanitizeToolName("senkani_exec") == "senkani_exec")
        #expect(LearnedInstructionPatch.sanitizeToolName("bad;rm -rf /") == "badrmrf")
        #expect(LearnedInstructionPatch.sanitizeToolName("CAPS-stuff") == "capsstuff")
        #expect(LearnedInstructionPatch.sanitizeToolName("") == "unknown")
    }

    @Test func hintCollapsesNewlinesAndRedactsSecrets() {
        let key = "sk-ant-api03-" + String(repeating: "X", count: 85)
        let raw = "Line 1\nLine 2\tkey=\(key)"
        let sanitized = LearnedInstructionPatch.sanitizeHint(raw)
        #expect(!sanitized.contains("\n"))
        #expect(!sanitized.contains(key))
    }

    @Test func hintCapped() {
        let huge = String(repeating: "a", count: 1000)
        let sanitized = LearnedInstructionPatch.sanitizeHint(huge)
        #expect(sanitized.count <= LearnedInstructionPatch.maxHintChars)
    }

    @Test func playbookDescriptionRedactsSecrets() {
        let key = "sk-ant-api03-" + String(repeating: "X", count: 85)
        let raw = "Workflow uses: \(key)"
        let sanitized = LearnedWorkflowPlaybook.sanitizeDescription(raw)
        #expect(!sanitized.contains(key))
    }

    @Test func playbookCapsStepCount() {
        let steps = (0..<20).map { i in
            LearnedWorkflowStep(toolName: "tool\(i)", example: "example \(i)")
        }
        let playbook = LearnedWorkflowPlaybook(
            id: "x", title: "many-steps", description: "",
            steps: steps, sources: [], confidence: 0.9,
            createdAt: fixedDate
        )
        #expect(playbook.steps.count == LearnedWorkflowPlaybook.maxSteps)
    }

    @Test func playbookTitleIsFilesystemSafe() {
        let playbook = LearnedWorkflowPlaybook(
            id: "x", title: "../../passwd", description: "",
            steps: [], sources: [], confidence: 0.9,
            createdAt: fixedDate
        )
        #expect(!playbook.title.contains(".."))
        #expect(!playbook.title.contains("/"))
    }
}

// MARK: - v4 → v5 migration + polymorphic round-trip (Celko)

@Suite("v4 → v5 polymorphic migration (H+2c)")
struct H2cMigrationTests {

    @Test func v4ArtifactsDecodeWithoutInstructionOrWorkflowCases() throws {
        let v4 = """
        {
          "version": 4,
          "artifacts": [
            {
              "type": "filterRule",
              "payload": {
                "id": "r1", "command": "docker", "subcommand": "compose",
                "ops": ["head(50)"], "source": "s", "confidence": 0.9,
                "status": "applied", "sessionCount": 5,
                "createdAt": "2026-04-15T10:00:00Z", "rationale": "x",
                "signalType": "failure", "recurrenceCount": 5,
                "lastSeenAt": "2026-04-17T00:00:00Z", "sources": ["s"]
              }
            }
          ]
        }
        """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let file = try dec.decode(LearnedRulesFile.self, from: Data(v4.utf8))
        #expect(file.artifacts.count == 1)
        #expect(file.instructionPatches.isEmpty)
        #expect(file.workflowPlaybooks.isEmpty)
    }

    @Test func allFourArtifactCasesRoundTrip() throws {
        let f = LearnedFilterRule(
            id: "f-1", command: "x", subcommand: nil, ops: ["head(50)"],
            source: "s", confidence: 0.9, status: .applied, sessionCount: 3,
            createdAt: fixedDate)
        let c = LearnedContextDoc(
            id: "c-1", title: "a-b", body: "body", sources: ["s"],
            confidence: 0.9, status: .staged, createdAt: fixedDate)
        let i = LearnedInstructionPatch(
            id: "i-1", toolName: "exec", hint: "prefer X over Y",
            sources: ["s"], confidence: 0.9, status: .recurring,
            createdAt: fixedDate)
        let w = LearnedWorkflowPlaybook(
            id: "w-1", title: "a-then-b",
            description: "# Do A then B", steps: [],
            sources: ["s"], confidence: 0.9, status: .recurring,
            createdAt: fixedDate)
        let file = LearnedRulesFile(version: 5, artifacts: [
            .filterRule(f), .contextDoc(c),
            .instructionPatch(i), .workflowPlaybook(w),
        ])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(file)

        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let reloaded = try dec.decode(LearnedRulesFile.self, from: data)
        #expect(reloaded.artifacts.count == 4)
        #expect(reloaded.instructionPatches.first?.toolName == "exec")
        #expect(reloaded.workflowPlaybooks.first?.title == "a-then-b")
    }

    @Test func saveStampsV5EvenIfFileWasV4() throws {
        let temp = NSTemporaryDirectory() + "senkani-h2c-mig-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        try LearnedRulesStore.withPath(temp) {
            let v4File = LearnedRulesFile(version: 4, artifacts: [])
            try LearnedRulesStore.save(v4File)
            let reloaded = LearnedRulesStore.load()!
            #expect(reloaded.version == LearnedRulesFile.currentVersion)
            #expect(LearnedRulesFile.currentVersion >= 5)
        }
    }
}

// MARK: - SQL queries

@Suite("H+2c SQL queries")
struct H2cSQLTests {

    @Test func instructionRetryPatternsDetectsRetryInSession() {
        let (db, path) = makeTempDB(); defer { cleanupDB(path: path) }
        let root = "/tmp/h2c-retry-yes"
        // Two sessions, each retrying `exec "big find"` 4 times.
        for _ in 0..<2 {
            let sid = db.createSession(projectRoot: root)
            for _ in 0..<4 {
                db.recordTokenEvent(
                    sessionId: sid, paneId: nil, projectRoot: root,
                    source: "mcp_tool", toolName: "exec", model: nil,
                    inputTokens: 500, outputTokens: 20, savedTokens: 40,
                    costCents: 1, feature: "filter",
                    command: "find / -name '*.swift'"
                )
            }
        }
        Thread.sleep(forTimeInterval: 0.05)

        let rows = db.instructionRetryPatterns(
            projectRoot: root, minRetries: 3, minSessions: 2)
        #expect(rows.count == 1)
        #expect(rows[0].toolName == "exec")
        #expect(rows[0].sessionCount >= 2)
        #expect(rows[0].avgRetries >= 3)
    }

    @Test func workflowPairPatternsDetectsOrderedPair() {
        let (db, path) = makeTempDB(); defer { cleanupDB(path: path) }
        let root = "/tmp/h2c-pair"
        // Two sessions: outline → fetch, 3 times each.
        for _ in 0..<2 {
            let sid = db.createSession(projectRoot: root)
            for i in 0..<3 {
                db.recordTokenEvent(
                    sessionId: sid, paneId: nil, projectRoot: root,
                    source: "mcp_tool", toolName: "outline", model: nil,
                    inputTokens: 100, outputTokens: 10, savedTokens: 50,
                    costCents: 1, feature: "outline", command: "file\(i).swift")
                db.recordTokenEvent(
                    sessionId: sid, paneId: nil, projectRoot: root,
                    source: "mcp_tool", toolName: "fetch", model: nil,
                    inputTokens: 100, outputTokens: 10, savedTokens: 80,
                    costCents: 1, feature: "fetch", command: "symbol\(i)")
            }
        }
        Thread.sleep(forTimeInterval: 0.05)

        let rows = db.workflowPairPatterns(
            projectRoot: root, minOccurrencesPerSession: 3,
            minSessions: 2)
        #expect(rows.contains { $0.firstTool == "outline" && $0.secondTool == "fetch" },
            "outline→fetch pair should surface")
    }
}

// MARK: - Generators

@Suite("H+2c generators")
struct H2cGeneratorTests {

    @Test func instructionGeneratorEmitsPatch() {
        let (db, path) = makeTempDB(); defer { cleanupDB(path: path) }
        let root = "/tmp/h2c-gen-ins"
        for _ in 0..<2 {
            let sid = db.createSession(projectRoot: root)
            for _ in 0..<4 {
                db.recordTokenEvent(
                    sessionId: sid, paneId: nil, projectRoot: root,
                    source: "mcp_tool", toolName: "search", model: nil,
                    inputTokens: 300, outputTokens: 20, savedTokens: 50,
                    costCents: 1, feature: "search",
                    command: "authenticationManager")
            }
        }
        Thread.sleep(forTimeInterval: 0.05)

        let proposals = InstructionSignalGenerator.analyze(
            projectRoot: root, sessionId: "test", db: db)
        #expect(!proposals.isEmpty)
        #expect(proposals[0].toolName == "search")
        #expect(proposals[0].status == .recurring)
        #expect(proposals[0].hint.count <= LearnedInstructionPatch.maxHintChars)
    }

    @Test func workflowGeneratorEmitsPlaybook() {
        let (db, path) = makeTempDB(); defer { cleanupDB(path: path) }
        let root = "/tmp/h2c-gen-wf"
        for _ in 0..<2 {
            let sid = db.createSession(projectRoot: root)
            for i in 0..<3 {
                db.recordTokenEvent(
                    sessionId: sid, paneId: nil, projectRoot: root,
                    source: "mcp_tool", toolName: "outline", model: nil,
                    inputTokens: 100, outputTokens: 10, savedTokens: 50,
                    costCents: 1, feature: "outline", command: "file\(i).swift")
                db.recordTokenEvent(
                    sessionId: sid, paneId: nil, projectRoot: root,
                    source: "mcp_tool", toolName: "fetch", model: nil,
                    inputTokens: 100, outputTokens: 10, savedTokens: 80,
                    costCents: 1, feature: "fetch", command: "sym\(i)")
            }
        }
        Thread.sleep(forTimeInterval: 0.05)

        let proposals = WorkflowSignalGenerator.analyze(
            projectRoot: root, sessionId: "test", db: db)
        #expect(!proposals.isEmpty)
        let outlineFetch = proposals.first { $0.title.contains("outline") && $0.title.contains("fetch") }
        #expect(outlineFetch != nil)
        #expect(outlineFetch?.steps.count == 2)
    }
}

// MARK: - Lifecycle (serialized)

@Suite("Instruction + workflow lifecycle (H+2c)", .serialized)
struct H2cLifecycleTests {

    private func withTempStore(_ body: () throws -> Void) rethrows {
        let temp = NSTemporaryDirectory() + "senkani-h2c-life-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        try LearnedRulesStore.withPath(temp, body)
    }

    @Test func observeInstructionMergesByToolAndHint() throws {
        try withTempStore {
            let p = LearnedInstructionPatch(
                id: "a", toolName: "exec", hint: "specify path",
                sources: ["s-1"], confidence: 0.85, createdAt: fixedDate,
                sessionCount: 2)
            try LearnedRulesStore.observeInstructionPatch(p)
            try LearnedRulesStore.observeInstructionPatch(
                LearnedInstructionPatch(
                    id: "b", toolName: "exec", hint: "specify path",
                    sources: ["s-2"], confidence: 0.85, createdAt: fixedDate,
                    sessionCount: 3))
            let reloaded = LearnedRulesStore.load()!
            #expect(reloaded.instructionPatches.count == 1)
            #expect(reloaded.instructionPatches[0].recurrenceCount == 2)
            #expect(reloaded.instructionPatches[0].sources.contains("s-2"))
        }
    }

    @Test func applyWorkflowPlaybookWritesToLearnedNamespace() throws {
        try withTempStore {
            let root = NSTemporaryDirectory() + "h2c-wf-apply-\(UUID().uuidString)"
            try FileManager.default.createDirectory(
                atPath: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: root) }

            let w = LearnedWorkflowPlaybook(
                id: "w-1", title: "outline-then-fetch",
                description: "# outline → fetch\n\nThe common pair.",
                steps: [
                    LearnedWorkflowStep(toolName: "outline", example: "…"),
                    LearnedWorkflowStep(toolName: "fetch", example: "…"),
                ], sources: ["s"], confidence: 0.9,
                status: .staged, createdAt: fixedDate)
            try LearnedRulesStore.save(LearnedRulesFile(
                version: 5, artifacts: [.workflowPlaybook(w)]))
            LearnedRulesStore.reload()

            let (db, dbPath) = makeTempDB(); defer { cleanupDB(path: dbPath) }
            try CompoundLearning.applyWorkflowPlaybook(
                id: "w-1", projectRoot: root, db: db)

            let reloaded = LearnedRulesStore.load()!
            #expect(reloaded.workflowPlaybooks.first?.status == .applied)

            // Written to .senkani/playbooks/learned/ — namespace
            // isolation verified.
            let filePath = root + "/.senkani/playbooks/learned/outline-then-fetch.md"
            #expect(FileManager.default.fileExists(atPath: filePath))
        }
    }

    @Test func instructionPatchNeverAutoAppliesFromSweep() throws {
        // Schneier constraint: daily sweep promotes recurring → staged
        // but must NEVER go staged → applied automatically. Apply is
        // explicit only.
        try withTempStore {
            let p = LearnedInstructionPatch(
                id: "ip", toolName: "exec", hint: "be specific",
                sources: ["s"], confidence: 0.95,
                status: .recurring, createdAt: fixedDate,
                recurrenceCount: 10, sessionCount: 5)
            try LearnedRulesStore.save(LearnedRulesFile(
                version: 5, artifacts: [.instructionPatch(p)]))
            LearnedRulesStore.reload()

            let (db, dbPath) = makeTempDB(); defer { cleanupDB(path: dbPath) }
            _ = CompoundLearning.runInstructionSweep(db: db)

            let after = LearnedRulesStore.load()!
            #expect(after.instructionPatches.first?.status == .staged,
                "sweep promotes to staged, never to applied")
        }
    }
}
