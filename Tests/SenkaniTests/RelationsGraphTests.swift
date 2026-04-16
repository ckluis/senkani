import Testing
import Foundation
import MCP
@testable import Core
@testable import MCPServer

private func makeGraphSession() -> (MCPSession, String) {
    let root = "/tmp/senkani-graph-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    let session = MCPSession(
        projectRoot: root, filterEnabled: false,
        secretsEnabled: false, indexerEnabled: false, cacheEnabled: false
    )
    return (session, root)
}

private func cleanup(_ root: String) { try? FileManager.default.removeItem(atPath: root) }

private func text(from result: CallTool.Result) -> String {
    result.content.first.flatMap {
        if case .text(let t, _, _) = $0 { return t } else { return nil }
    } ?? ""
}

@Suite("RelationsGraph")
struct RelationsGraphTests {

    // 1. Spring layout keeps all nodes within the given bounds
    @Test func testSpringLayoutKeepsNodesInBounds() {
        let size = CGSize(width: 400, height: 300)
        let nodes = [
            GraphNode(id: 1, name: "Root",    entityType: "class",  isRoot: true,  position: CGPoint(x: 200, y: 150)),
            GraphNode(id: 2, name: "Partner", entityType: "class",  isRoot: false, position: CGPoint(x: 300, y: 150)),
            GraphNode(id: 3, name: "Other",   entityType: "struct", isRoot: false, position: CGPoint(x: 100, y: 150)),
        ]
        let edges = [GraphEdge(sourceId: 1, targetName: "Partner", relation: "uses")]
        let result = springLayout(nodes: nodes, edges: edges, size: size)
        for node in result {
            #expect(node.position.x >= 40 && node.position.x <= size.width - 40)
            #expect(node.position.y >= 40 && node.position.y <= size.height - 40)
        }
    }

    // 2. Root node stays pinned at its initial position
    @Test func testSpringLayoutPinsRoot() {
        let size = CGSize(width: 400, height: 300)
        let rootPos = CGPoint(x: 200, y: 150)
        let nodes = [
            GraphNode(id: 1, name: "Root", entityType: "class", isRoot: true,  position: rootPos),
            GraphNode(id: 2, name: "A",    entityType: "class", isRoot: false, position: CGPoint(x: 300, y: 150)),
        ]
        let edges = [GraphEdge(sourceId: 1, targetName: "A", relation: nil)]
        let result = springLayout(nodes: nodes, edges: edges, size: size)
        let root = result.first { $0.isRoot }!
        #expect(abs(root.position.x - rootPos.x) < 0.001)
        #expect(abs(root.position.y - rootPos.y) < 0.001)
    }

    // 3. Single-node graph returns unchanged (no crash)
    @Test func testSpringLayoutSingleNode() {
        let node = GraphNode(id: 1, name: "Solo", entityType: "class", isRoot: true,
                             position: CGPoint(x: 100, y: 100))
        let result = springLayout(nodes: [node], edges: [],
                                   size: CGSize(width: 400, height: 300))
        #expect(result.count == 1)
    }

    // 4. graph action shows outgoing relations
    @Test func testGraphActionShowsOutgoing() {
        let (session, root) = makeGraphSession()
        defer { cleanup(root) }

        let srcId = session.knowledgeStore.upsertEntity(KnowledgeEntity(
            name: "GraphSrc", entityType: "class", markdownPath: ".senkani/knowledge/GraphSrc.md"
        ))
        session.knowledgeStore.upsertEntity(KnowledgeEntity(
            name: "GraphDst", entityType: "class", markdownPath: ".senkani/knowledge/GraphDst.md"
        ))
        session.knowledgeStore.insertLink(EntityLink(
            sourceId: srcId, targetName: "GraphDst", relation: "depends_on"
        ))

        let result = KnowledgeTool.handle(
            arguments: ["action": .string("graph"), "entity": .string("GraphSrc")],
            session: session
        )
        #expect(result.isError != true)
        let t = text(from: result)
        #expect(t.contains("Outgoing"))
        #expect(t.contains("depends_on"))
        #expect(t.contains("GraphDst"))
    }

    // 5. graph action shows incoming (backlinks) with resolved source name
    @Test func testGraphActionShowsIncoming() {
        let (session, root) = makeGraphSession()
        defer { cleanup(root) }

        let srcId = session.knowledgeStore.upsertEntity(KnowledgeEntity(
            name: "InSrc", entityType: "class", markdownPath: ".senkani/knowledge/InSrc.md"
        ))
        session.knowledgeStore.upsertEntity(KnowledgeEntity(
            name: "InDst", entityType: "class", markdownPath: ".senkani/knowledge/InDst.md"
        ))
        session.knowledgeStore.insertLink(EntityLink(
            sourceId: srcId, targetName: "InDst", relation: "used_by"
        ))

        let result = KnowledgeTool.handle(
            arguments: ["action": .string("graph"), "entity": .string("InDst")],
            session: session
        )
        #expect(result.isError != true)
        let t = text(from: result)
        #expect(t.contains("Incoming"))
        #expect(t.contains("InSrc"))
    }

    // 6. graph action returns error for unknown entity
    @Test func testGraphActionUnknownEntityError() {
        let (session, root) = makeGraphSession()
        defer { cleanup(root) }

        let result = KnowledgeTool.handle(
            arguments: ["action": .string("graph"), "entity": .string("Ghost")],
            session: session
        )
        #expect(result.isError == true)
    }
}
