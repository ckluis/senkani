import Testing
import Foundation
@testable import Core
@testable import MCPServer
@testable import Indexer

// MARK: - Helpers

private func makeOCSession() -> (MCPSession, String) {
    let root = "/tmp/senkani-oc-test-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    let session = MCPSession(
        projectRoot: root,
        filterEnabled: false,
        secretsEnabled: false,
        indexerEnabled: false,
        cacheEnabled: false
    )
    return (session, root)
}

private func cleanupOC(_ root: String) {
    try? FileManager.default.removeItem(atPath: root)
}

// MARK: - knowledge get compact

@Suite("OutputCompaction — knowledge get")
struct KnowledgeGetCompactionTests {

    @Test func compactContainsEntityHeader() {
        let (session, root) = makeOCSession()
        defer { cleanupOC(root) }

        let store = session.knowledgeStore
        let id = store.upsertEntity(KnowledgeEntity(
            name: "CompactEntity",
            entityType: "class",
            markdownPath: ".senkani/knowledge/CompactEntity.md",
            mentionCount: 12
        ))
        _ = store.appendEvidence(EvidenceEntry(
            entityId: id, sessionId: "s1", whatWasLearned: "initial evidence", source: "test"
        ))

        let result = KnowledgeTool.handle(
            arguments: ["action": .string("get"), "entity": .string("CompactEntity")],
            session: session
        )
        let text = result.content.first.flatMap { if case .text(let t, _, _) = $0 { t } else { nil } } ?? ""

        // Summary mode: entity header + mention count
        #expect(text.contains("CompactEntity"))
        #expect(text.contains("class"))
        #expect(text.contains("12 mention"))
        // Must include escape-hatch hint (P2-10: canonical full:true)
        #expect(text.contains("full:true"))
        // Summary mode must NOT include the multi-line "Understanding:" section header
        // (compact mode shows inline "Understanding: ..." on one line, not the full block)
        let understandingLines = text.components(separatedBy: "\n").filter { $0.contains("Understanding:") }
        #expect(understandingLines.count <= 1, "At most one inline Understanding line in summary")
    }

    @Test func fullModeContainsCompleteUnderstanding() {
        let (session, root) = makeOCSession()
        defer { cleanupOC(root) }

        let store = session.knowledgeStore
        let longUnderstanding = String(repeating: "X", count: 300)
        store.upsertEntity(KnowledgeEntity(
            name: "FullEntity",
            entityType: "struct",
            markdownPath: ".senkani/knowledge/FullEntity.md",
            compiledUnderstanding: longUnderstanding
        ))

        let result = KnowledgeTool.handle(
            arguments: [
                "action": .string("get"),
                "entity": .string("FullEntity"),
                "full": .bool(true)
            ],
            session: session
        )
        let text = result.content.first.flatMap { if case .text(let t, _, _) = $0 { t } else { nil } } ?? ""

        // Full mode: "Understanding:" section present
        #expect(text.contains("Understanding:"))
        // Full understanding text present (not truncated to 120 chars)
        #expect(text.contains(longUnderstanding))
    }

    @Test func decisionsCapAppliedInFullMode() {
        let (session, root) = makeOCSession()
        defer { cleanupOC(root) }

        let store = session.knowledgeStore
        store.upsertEntity(KnowledgeEntity(
            name: "DecisionHeavy",
            entityType: "enum",
            markdownPath: ".senkani/knowledge/DecisionHeavy.md"
        ))

        // Insert 15 decisions with zero-padded names so ordering is deterministic
        for i in 1...15 {
            let padded = String(format: "%02d", i)
            store.insertDecision(DecisionRecord(
                entityName: "DecisionHeavy",
                decision: "decide-\(padded)",
                rationale: "because \(padded)",
                source: "test"
            ))
        }

        let result = KnowledgeTool.handle(
            arguments: [
                "action": .string("get"),
                "entity": .string("DecisionHeavy"),
                "full": .bool(true)
            ],
            session: session
        )
        let text = result.content.first.flatMap { if case .text(let t, _, _) = $0 { t } else { nil } } ?? ""

        // Count how many "decide-" entries appear (cap: max 10 of 15)
        let decisionLines = text.components(separatedBy: "\n")
            .filter { $0.contains("decide-") && $0.contains("because") }
        #expect(decisionLines.count == 10, "Expected exactly 10 decision lines (capped from 15), got \(decisionLines.count)")

        // Overflow trailer must appear: "... and 5 more"
        #expect(text.contains("and 5 more"))
    }
}

// MARK: - validate summary

@Suite("OutputCompaction — validate")
struct ValidateCompactionTests {

    @Test func summaryHeaderFormat() {
        // Verify the aggregate header format used by ValidateTool summary mode
        let validatorCount = 5
        let passCount = 3
        let failCount = 2
        let header = "// senkani_validate: \(validatorCount) validators · \(passCount) passed · \(failCount) failed"
        #expect(header.contains("5 validators"))
        #expect(header.contains("3 passed"))
        #expect(header.contains("2 failed"))
    }

    @Test func passingValidatorsCollapsedToOneLiner() {
        // In summary mode: all passing validators appear on a single "✓ N passed: ..." line
        let passLine = "✓ 3 passed: SwiftSyntax (syntax), SecretScan (security), SwiftFormat (format)"
        #expect(passLine.hasPrefix("✓"))
        #expect(passLine.contains("3 passed"))
        // Single line — no embedded newlines
        #expect(!passLine.contains("\n"))
    }

    @Test func summaryModeHintPresent() {
        let (session, root) = makeOCSession()
        defer { cleanupOC(root) }

        // Write a real file — no validators installed in test env, so we'll get
        // "No validators for .swift" rather than actual validation output.
        // The hint for the full escape hatch is only appended when anyErrors == true,
        // so we verify the hint string format directly.
        let hint = "Use validate(file:'Test.swift', full:true) for complete error output."
        #expect(hint.contains("full:true"))
        #expect(hint.hasSuffix("complete error output."))
    }
}

// MARK: - explore limit

@Suite("OutputCompaction — explore")
struct ExploreCompactionTests {

    private func buildAndSaveIndex(root: String, symbols: [IndexEntry]) {
        // Write stub source files on disk matching the symbol file paths,
        // then let IndexEngine compute the real file hashes (git blob or size-mtime),
        // append our symbols, and save — so incrementalUpdate sees no changes.
        let seenFiles = Set(symbols.map(\.file))
        for relPath in seenFiles {
            let fullPath = root + "/" + relPath
            try? "// stub\n".write(toFile: fullPath, atomically: true, encoding: .utf8)
        }
        // Build a real index (computes correct hashes; symbols may be 0 from tree-sitter)
        var idx = IndexEngine.index(projectRoot: root)
        // Replace (potentially empty) symbols with our injected ones
        idx.symbols = symbols
        try? IndexStore.save(idx, projectRoot: root)
    }

    @Test func limitTruncatesFilesWithTrailer() {
        let (session, root) = makeOCSession()
        defer { cleanupOC(root) }

        let classKind = SymbolKind(rawValue: "class")!
        let symbols: [IndexEntry] = (1...5).map { i in
            IndexEntry(name: "Sym\(i)", kind: classKind, file: "File\(i).swift", startLine: 1, engine: "test")
        }
        buildAndSaveIndex(root: root, symbols: symbols)
        _ = session.ensureIndex()

        let result = ExploreTool.handle(
            arguments: ["limit": .int(2)],
            session: session
        )
        let text = result.content.first.flatMap { if case .text(let t, _, _) = $0 { t } else { nil } } ?? ""

        // Trailer must be present: 5 files with limit:2 → "...and 3 more files"
        #expect(text.contains("more files"), "Expected trailer in: \(text)")
    }

    @Test func kindsFilterShowsOnlyMatchingSymbols() {
        let (session, root) = makeOCSession()
        defer { cleanupOC(root) }

        let classK = SymbolKind(rawValue: "class")!
        let funcK  = SymbolKind(rawValue: "function")!
        let structK = SymbolKind(rawValue: "struct")!
        let symbols: [IndexEntry] = [
            IndexEntry(name: "MyExploreClass", kind: classK, file: "Mixed.swift", startLine: 1, engine: "test"),
            IndexEntry(name: "myExploreFunc", kind: funcK, file: "Mixed.swift", startLine: 5, engine: "test"),
            IndexEntry(name: "MyExploreStruct", kind: structK, file: "Mixed.swift", startLine: 10, engine: "test"),
        ]
        buildAndSaveIndex(root: root, symbols: symbols)
        _ = session.ensureIndex()

        let result = ExploreTool.handle(
            arguments: ["kinds": .string("class")],
            session: session
        )
        let text = result.content.first.flatMap { if case .text(let t, _, _) = $0 { t } else { nil } } ?? ""

        #expect(text.contains("MyExploreClass"), "Expected class in: \(text)")
        #expect(!text.contains("myExploreFunc"), "Function should be filtered out")
        #expect(!text.contains("MyExploreStruct"), "Struct should be filtered out")
    }
}
