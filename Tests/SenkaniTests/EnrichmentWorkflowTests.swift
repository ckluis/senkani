import Testing
import Foundation
import MCP
@testable import Core
@testable import MCPServer

// MARK: - Helpers

private func makeEnrichSession() -> (MCPSession, String) {
    let root = "/tmp/senkani-enrich-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    let session = MCPSession(
        projectRoot: root, filterEnabled: false,
        secretsEnabled: false, indexerEnabled: false, cacheEnabled: false
    )
    return (session, root)
}

private func cleanup(_ root: String) { try? FileManager.default.removeItem(atPath: root) }

@discardableResult
private func insertEntity(_ name: String, into store: KnowledgeStore, sourcePath: String? = nil) -> Int64 {
    store.upsertEntity(KnowledgeEntity(
        name: name, entityType: "class",
        sourcePath: sourcePath,
        markdownPath: ".senkani/knowledge/\(name).md"
    ))
}

private func text(from result: CallTool.Result) -> String {
    result.content.first.flatMap {
        if case .text(let t, _, _) = $0 { return t } else { return nil }
    } ?? ""
}

// MARK: - Suite

@Suite("EnrichmentWorkflow")
struct EnrichmentWorkflowTests {

    // 1. propose with understanding stages markdown file
    @Test func testProposeStagesContent() throws {
        let (session, root) = makeEnrichSession()
        defer { cleanup(root) }
        guard let layer = session.knowledgeLayer else { return }

        insertEntity("ProposeTarget", into: session.knowledgeStore)
        let result = KnowledgeTool.handle(
            arguments: [
                "action": .string("propose"),
                "entity": .string("ProposeTarget"),
                "understanding": .string("Handles authentication tokens.")
            ],
            session: session
        )
        #expect(result.isError != true)
        #expect(text(from: result).contains("Staged"))

        let staged = layer.readStagedProposal(for: "ProposeTarget")
        #expect(staged != nil)
        #expect(staged?.contains("Handles authentication tokens.") == true)
    }

    // 2. propose without understanding returns enrichment context (not an error)
    @Test func testProposeWithoutUnderstandingReturnsContext() {
        let (session, root) = makeEnrichSession()
        defer { cleanup(root) }

        insertEntity("ContextTarget", into: session.knowledgeStore)
        let result = KnowledgeTool.handle(
            arguments: ["action": .string("propose"), "entity": .string("ContextTarget")],
            session: session
        )
        #expect(result.isError != true)
        let t = text(from: result)
        #expect(t.contains("ContextTarget"))
        #expect(t.contains("propose"))
    }

    // 3. commit applies staged proposal and records evidence
    @Test func testCommitStagedProposal() throws {
        let (session, root) = makeEnrichSession()
        defer { cleanup(root) }
        guard let layer = session.knowledgeLayer else { return }

        let entityId = insertEntity("CommitTarget", into: session.knowledgeStore)

        _ = KnowledgeTool.handle(
            arguments: [
                "action": .string("propose"),
                "entity": .string("CommitTarget"),
                "understanding": .string("Core routing logic.")
            ],
            session: session
        )
        #expect(layer.readStagedProposal(for: "CommitTarget") != nil)

        let result = KnowledgeTool.handle(
            arguments: ["action": .string("commit"), "entity": .string("CommitTarget")],
            session: session
        )
        #expect(result.isError != true)
        #expect(text(from: result).contains("Committed"))

        // Staged file removed
        #expect(layer.readStagedProposal(for: "CommitTarget") == nil)

        // Live file updated
        let (content, _) = try layer.readEntity(name: "CommitTarget")
        #expect(content.compiledUnderstanding == "Core routing logic.")

        // Evidence recorded
        let timeline = session.knowledgeStore.timeline(forEntityId: entityId)
        #expect(timeline.contains { $0.source == "enrichment" })
    }

    // 4. discard removes staged file
    @Test func testDiscardStagedProposal() {
        let (session, root) = makeEnrichSession()
        defer { cleanup(root) }
        guard let layer = session.knowledgeLayer else { return }

        insertEntity("DiscardTarget", into: session.knowledgeStore)
        _ = KnowledgeTool.handle(
            arguments: [
                "action": .string("propose"),
                "entity": .string("DiscardTarget"),
                "understanding": .string("Temporary proposal.")
            ],
            session: session
        )
        #expect(layer.readStagedProposal(for: "DiscardTarget") != nil)

        let result = KnowledgeTool.handle(
            arguments: ["action": .string("discard"), "entity": .string("DiscardTarget")],
            session: session
        )
        #expect(result.isError != true)
        #expect(layer.readStagedProposal(for: "DiscardTarget") == nil)
    }

    // 5. propose for unknown entity returns error
    @Test func testProposeUnknownEntityReturnsError() {
        let (session, root) = makeEnrichSession()
        defer { cleanup(root) }

        let result = KnowledgeTool.handle(
            arguments: [
                "action": .string("propose"),
                "entity": .string("Ghost"),
                "understanding": .string("Doesn't exist.")
            ],
            session: session
        )
        #expect(result.isError == true)
    }

    // 6. readStagedProposal returns nil when no staged file
    @Test func testReadStagedProposalNilWhenAbsent() {
        let (session, root) = makeEnrichSession()
        defer { cleanup(root) }
        guard let layer = session.knowledgeLayer else { return }

        insertEntity("NilStaged", into: session.knowledgeStore)
        #expect(layer.readStagedProposal(for: "NilStaged") == nil)
    }

    // 7. handleGet shows STAGED marker when proposal exists
    @Test func testGetShowsStagedMarker() {
        let (session, root) = makeEnrichSession()
        defer { cleanup(root) }

        insertEntity("MarkerEntity", into: session.knowledgeStore)
        _ = KnowledgeTool.handle(
            arguments: [
                "action": .string("propose"),
                "entity": .string("MarkerEntity"),
                "understanding": .string("Proposed text.")
            ],
            session: session
        )
        let result = KnowledgeTool.handle(
            arguments: ["action": .string("get"), "entity": .string("MarkerEntity")],
            session: session
        )
        #expect(result.isError != true)
        #expect(text(from: result).contains("STAGED"))
    }
}
