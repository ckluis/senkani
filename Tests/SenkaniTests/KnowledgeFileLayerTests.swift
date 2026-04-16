import Testing
import Foundation
@testable import Core

// MARK: - Helpers

private func makeTempProject() throws -> (KnowledgeFileLayer, KnowledgeStore, String) {
    let root = "/tmp/senkani-fl-test-\(UUID().uuidString)"
    let store = KnowledgeStore(path: root + "/vault.db")
    let layer = try KnowledgeFileLayer(projectRoot: root, store: store)
    return (layer, store, root)
}

private func cleanup(_ root: String) {
    try? FileManager.default.removeItem(atPath: root)
}

/// Build a fully-populated KBContent for round-trip testing.
private func richContent(name: String) -> KBContent {
    let fm = KBFrontmatter(
        entityType: "class",
        sourcePath: "Sources/Core/\(name).swift",
        lastEnriched: KnowledgeParser.isoFull.date(from: "2026-04-12T10:00:00Z"),
        mentionCount: 7
    )
    return KBContent(
        frontmatter: fm,
        entityName: name,
        compiledUnderstanding: "Manages the \(name) lifecycle.\nHandles init and teardown.",
        relations: [
            ParsedRelation(targetName: "FeatureConfig", relationType: "depends_on", lineNumber: 1),
            ParsedRelation(targetName: "SessionDatabase", relationType: "used_by", lineNumber: 2),
        ],
        evidence: [
            ParsedEvidence(
                date: KnowledgeParser.isoDate.date(from: "2026-04-10")!,
                sessionId: "s_abc1",
                whatWasLearned: "Uses NSLock for thread safety"
            ),
            ParsedEvidence(
                date: KnowledgeParser.isoDate.date(from: "2026-04-12")!,
                sessionId: "s_def2",
                whatWasLearned: "Async writes avoid blocking main thread"
            ),
        ],
        decisions: [
            ParsedDecision(
                date: KnowledgeParser.isoDate.date(from: "2026-04-12")!,
                decision: "Use NSLock over actor",
                rationale: "callbacks fire on arbitrary threads"
            ),
        ]
    )
}

// MARK: - Suite 1: Directory Creation

@Suite("KnowledgeFileLayer — Directory Creation")
struct KnowledgeFileLayerDirectoryTests {

    @Test func testDirectoryCreation() throws {
        let (layer, _, root) = try makeTempProject()
        defer { cleanup(root) }

        let fm = FileManager.default
        var isDir: ObjCBool = false

        fm.fileExists(atPath: layer.knowledgeDir, isDirectory: &isDir)
        #expect(isDir.boolValue, "knowledge/ should exist")

        fm.fileExists(atPath: layer.stagedDir, isDirectory: &isDir)
        #expect(isDir.boolValue, ".staged/ should exist")

        fm.fileExists(atPath: layer.historyDir, isDirectory: &isDir)
        #expect(isDir.boolValue, ".history/ should exist")
    }
}

// MARK: - Suite 2: Parser (pure, no FS)

@Suite("KnowledgeParser — Pure Parsing")
struct KnowledgeParserTests {

    @Test func testFrontmatterParsed() {
        let md = """
        ---
        type: struct
        source_path: Sources/Core/Foo.swift
        last_enriched: 2026-04-12T10:00:00Z
        mention_count: 42
        ---

        # Foo

        ## Compiled Understanding
        Does things.

        ## Relations

        ## Evidence Timeline
        | Date | Session | What was learned |
        | --- | --- | --- |

        ## Decision Records

        """
        let content = KnowledgeParser.parse(md)
        #expect(content != nil, "Should parse valid markdown")
        #expect(content?.frontmatter.entityType == "struct")
        #expect(content?.frontmatter.sourcePath == "Sources/Core/Foo.swift")
        #expect(content?.frontmatter.mentionCount == 42)
        #expect(content?.frontmatter.lastEnriched != nil)
        #expect(content?.entityName == "Foo")
        #expect(content?.compiledUnderstanding == "Does things.")
    }

    @Test func testRelationsParsed() {
        let md = """
        ---
        type: class
        mention_count: 0
        ---

        # Router

        ## Compiled Understanding

        ## Relations
        - [[FeatureConfig]] depends_on
        - [[BudgetConfig]] depends_on
        - [[MCPSession]] used_by
        - [[Orphan]]

        ## Evidence Timeline
        | Date | Session | What was learned |
        | --- | --- | --- |

        ## Decision Records

        """
        let content = KnowledgeParser.parse(md)
        #expect(content?.relations.count == 4, "Should parse 4 relations")
        #expect(content?.relations[0].targetName == "FeatureConfig")
        #expect(content?.relations[0].relationType == "depends_on")
        #expect(content?.relations[2].relationType == "used_by")
        #expect(content?.relations[3].relationType == nil, "Missing relation type → nil")
    }

    @Test func testEvidenceTableParsed() {
        let md = """
        ---
        type: class
        mention_count: 0
        ---

        # Widget

        ## Compiled Understanding

        ## Relations

        ## Evidence Timeline
        | Date | Session | What was learned |
        | --- | --- | --- |
        | 2026-04-10 | s_abc1 | First observation |
        | 2026-04-12 | s_def2 | Second observation |

        ## Decision Records

        """
        let content = KnowledgeParser.parse(md)
        #expect(content?.evidence.count == 2, "Should parse 2 evidence rows")
        #expect(content?.evidence[0].sessionId == "s_abc1")
        #expect(content?.evidence[0].whatWasLearned == "First observation")
        #expect(content?.evidence[1].sessionId == "s_def2")

        // Verify date parsing
        let cal = Calendar(identifier: .gregorian)
        var comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: content!.evidence[0].date)
        #expect(comps.year == 2026 && comps.month == 4 && comps.day == 10)
    }

    @Test func testDecisionsParsed() {
        let md = """
        ---
        type: class
        mention_count: 0
        ---

        # Service

        ## Compiled Understanding

        ## Relations

        ## Evidence Timeline
        | Date | Session | What was learned |
        | --- | --- | --- |

        ## Decision Records
        - [2026-04-12] Use NSLock over actor because callbacks fire on arbitrary threads
        - [2026-04-10] Chose SQLite over CoreData

        """
        let content = KnowledgeParser.parse(md)
        #expect(content?.decisions.count == 2, "Should parse 2 decisions")
        #expect(content?.decisions[0].decision == "Use NSLock over actor")
        #expect(content?.decisions[0].rationale == "callbacks fire on arbitrary threads")
        #expect(content?.decisions[1].decision == "Chose SQLite over CoreData")
        #expect(content?.decisions[1].rationale == nil, "No 'because' → nil rationale")
    }

    @Test func testSecretStripping() {
        // A markdown file that accidentally contains an Anthropic API key
        let secret = "sk-ant-api01-AAABBBCCCDDDEEEFFFGGGHHHIIIJJJ"
        let md = """
        ---
        type: class
        mention_count: 0
        ---

        # Dangerous

        ## Compiled Understanding
        Do not use this key: \(secret)

        ## Relations

        ## Evidence Timeline
        | Date | Session | What was learned |
        | --- | --- | --- |

        ## Decision Records

        """
        let content = KnowledgeParser.parse(md)
        #expect(content != nil, "Should parse despite containing a secret")
        #expect(
            content?.compiledUnderstanding.contains(secret) == false,
            "Raw secret must not appear in compiledUnderstanding"
        )
        #expect(
            content?.compiledUnderstanding.contains("[REDACTED:ANTHROPIC_API_KEY]") == true,
            "Redacted placeholder should be present"
        )
    }
}

// MARK: - Suite 3: Round-Trip

@Suite("KnowledgeFileLayer — Round-Trip")
struct KnowledgeFileLayerRoundTripTests {

    @Test func testRoundTrip() throws {
        let (layer, _, root) = try makeTempProject()
        defer { cleanup(root) }

        let original = richContent(name: "RoundTripEntity")

        // Serialize → write to disk
        try layer.writeEntity(name: "RoundTripEntity", content: original)

        // Read back and parse
        let (parsed, _) = try layer.readEntity(name: "RoundTripEntity")

        // Full equality — verifies round-trip fidelity
        #expect(parsed == original,
                "parse(serialize(content)) must equal original content")
    }
}

// MARK: - Suite 4: Staging Lifecycle

@Suite("KnowledgeFileLayer — Staging Lifecycle")
struct KnowledgeFileLayerStagingTests {

    @Test func testStageAndCommit() throws {
        let (layer, _, root) = try makeTempProject()
        defer { cleanup(root) }

        let content = richContent(name: "StagedEntity")
        let markdown = KnowledgeParser.serialize(content, entityName: "StagedEntity")

        // Stage
        let stagedURL = try layer.stageProposal(for: "StagedEntity", content: markdown)
        #expect(FileManager.default.fileExists(atPath: stagedURL.path), "Staged file should exist")

        // Commit
        try layer.commitProposal(for: "StagedEntity")

        // Live file should now exist
        let liveURL = URL(fileURLWithPath: layer.knowledgeDir)
            .appendingPathComponent("StagedEntity.md")
        #expect(FileManager.default.fileExists(atPath: liveURL.path), "Live file should exist after commit")

        // Staged file should be gone
        #expect(!FileManager.default.fileExists(atPath: stagedURL.path), "Staged file should be removed after commit")
    }

    @Test func testCommitCreatesHistoryEntry() throws {
        let (layer, _, root) = try makeTempProject()
        defer { cleanup(root) }

        let v1 = KnowledgeParser.serialize(richContent(name: "HistEntity"), entityName: "HistEntity")

        // First commit — no previous live, so no history entry yet
        try layer.stageProposal(for: "HistEntity", content: v1)
        try layer.commitProposal(for: "HistEntity")

        let v2 = v1 + "<!-- v2 -->\n"
        try layer.stageProposal(for: "HistEntity", content: v2)
        try layer.commitProposal(for: "HistEntity")  // This archives v1 → .history/

        let histDir = URL(fileURLWithPath: layer.historyDir).appendingPathComponent("HistEntity")
        let histFiles = (try? FileManager.default.contentsOfDirectory(atPath: histDir.path)) ?? []
        let mdFiles = histFiles.filter { $0.hasSuffix(".md") }
        #expect(mdFiles.count == 1, "Second commit should create one history entry (v1)")
    }

    @Test func testRollback() throws {
        let (layer, _, root) = try makeTempProject()
        defer { cleanup(root) }

        let v1Body = "Version 1 content."
        let v2Body = "Version 2 content."

        func makeContent(_ body: String) -> KBContent {
            KBContent(
                frontmatter: KBFrontmatter(entityType: "class"),
                entityName: "RollbackEntity",
                compiledUnderstanding: body
            )
        }

        // Commit v1
        let v1Markdown = KnowledgeParser.serialize(makeContent(v1Body), entityName: "RollbackEntity")
        try layer.stageProposal(for: "RollbackEntity", content: v1Markdown)
        try layer.commitProposal(for: "RollbackEntity")

        // Small sleep to ensure different timestamps
        Thread.sleep(forTimeInterval: 1.1)
        let v1Date = Date()

        // Commit v2
        let v2Markdown = KnowledgeParser.serialize(makeContent(v2Body), entityName: "RollbackEntity")
        try layer.stageProposal(for: "RollbackEntity", content: v2Markdown)
        try layer.commitProposal(for: "RollbackEntity")

        // Rollback to v1
        try layer.rollback(entityName: "RollbackEntity", to: v1Date)

        // Live file should now contain v1 content
        let (restored, _) = try layer.readEntity(name: "RollbackEntity")
        #expect(restored.compiledUnderstanding == v1Body,
                "After rollback, content should match v1. Got: \(restored.compiledUnderstanding)")
    }

    @Test func testHistoryPruning() throws {
        let (layer, _, root) = try makeTempProject()
        defer { cleanup(root) }

        func makeMarkdown(_ n: Int) -> String {
            KnowledgeParser.serialize(
                KBContent(
                    frontmatter: KBFrontmatter(entityType: "class"),
                    entityName: "PruneEntity",
                    compiledUnderstanding: "Version \(n)"
                ),
                entityName: "PruneEntity"
            )
        }

        // First commit (establishes live file, no history)
        try layer.stageProposal(for: "PruneEntity", content: makeMarkdown(0))
        try layer.commitProposal(for: "PruneEntity")

        // 12 more commits, each archives the previous live version
        for i in 1...12 {
            Thread.sleep(forTimeInterval: 0.05) // distinct timestamps
            try layer.stageProposal(for: "PruneEntity", content: makeMarkdown(i))
            try layer.commitProposal(for: "PruneEntity")
        }

        let histDir = URL(fileURLWithPath: layer.historyDir).appendingPathComponent("PruneEntity")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: histDir.path)) ?? []
        let mdCount = files.filter { $0.hasSuffix(".md") }.count
        #expect(mdCount == 10, "History should be pruned to 10 entries, got \(mdCount)")
    }
}
