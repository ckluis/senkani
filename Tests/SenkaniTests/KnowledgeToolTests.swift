import Testing
import Foundation
@testable import Core
@testable import MCPServer

// MARK: - Helpers

private func makeTestSession() -> (MCPSession, String) {
    let root = "/tmp/senkani-kt-test-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    let session = MCPSession(
        projectRoot: root,
        filterEnabled: false,
        secretsEnabled: false,
        indexerEnabled: false,   // no background index build
        cacheEnabled: false
    )
    return (session, root)
}

private func cleanup(_ root: String) {
    try? FileManager.default.removeItem(atPath: root)
}

@discardableResult
private func insertEntity(_ name: String, type: String = "class", into store: KnowledgeStore) -> Int64 {
    store.upsertEntity(KnowledgeEntity(
        name: name,
        entityType: type,
        markdownPath: ".senkani/knowledge/\(name).md"
    ))
}

// Construct a PostToolUse hook event JSON for testing.
private func postToolUseEvent(toolName: String, toolInput: [String: Any]) -> Data {
    let event: [String: Any] = [
        "hook_event_name": "PostToolUse",
        "tool_name": toolName,
        "tool_input": toolInput,
        "session_id": "test-session",
        "cwd": "/tmp/test-project"
    ]
    return (try? JSONSerialization.data(withJSONObject: event)) ?? Data()
}

// MARK: - Suite

@Suite("KnowledgeTool")
struct KnowledgeToolTests {

    // 1. MCPSession creates KB components on init
    @Test func testMCPSessionCreatesKBComponents() {
        let (session, root) = makeTestSession()
        defer { cleanup(root) }

        // knowledgeStore is always non-nil (let property)
        let state = session.entityTracker.state()
        #expect(state.entityCount == 0, "Fresh session has no entities")
        #expect(state.pendingDelta.isEmpty)
        #expect(state.callsSinceFlush == 0)
    }

    // 2. KnowledgeFileLayer is created and KB dirs exist
    @Test func testMCPSessionKnowledgeLayerCreated() {
        let (session, root) = makeTestSession()
        defer { cleanup(root) }

        #expect(session.knowledgeLayer != nil, "knowledgeLayer should be created")
        guard let layer = session.knowledgeLayer else { return }

        let fm = FileManager.default
        var isDir: ObjCBool = false

        fm.fileExists(atPath: layer.knowledgeDir, isDirectory: &isDir)
        #expect(isDir.boolValue, "knowledge/ dir should exist")

        fm.fileExists(atPath: layer.stagedDir, isDirectory: &isDir)
        #expect(isDir.boolValue, ".staged/ dir should exist")

        fm.fileExists(atPath: layer.historyDir, isDirectory: &isDir)
        #expect(isDir.boolValue, ".history/ dir should exist")
    }

    // 3. status action includes entity count
    @Test func testKnowledgeStatusOutput() {
        let (session, root) = makeTestSession()
        defer { cleanup(root) }

        insertEntity("StatusAlpha", into: session.knowledgeStore)
        insertEntity("StatusBeta", into: session.knowledgeStore)

        let result = KnowledgeTool.handle(
            arguments: ["action": .string("status")],
            session: session
        )
        #expect(result.isError != true)
        let text = result.content.first.flatMap { if case .text(let t, _, _) = $0 { return t } else { return nil } } ?? ""
        #expect(text.contains("Knowledge Base Status"))
        #expect(text.contains("Entities: 2"))
    }

    // 4. get action returns entity info
    @Test func testKnowledgeGetFound() throws {
        let (session, root) = makeTestSession()
        defer { cleanup(root) }

        insertEntity("GetTarget", type: "struct", into: session.knowledgeStore)

        let result = KnowledgeTool.handle(
            arguments: ["action": .string("get"), "entity": .string("GetTarget")],
            session: session
        )
        #expect(result.isError != true)
        let text = result.content.first.flatMap { if case .text(let t, _, _) = $0 { return t } else { return nil } } ?? ""
        #expect(text.contains("GetTarget"))
        #expect(text.contains("struct"))
    }

    // 5. get for unknown entity returns error
    @Test func testKnowledgeGetNotFound() {
        let (session, root) = makeTestSession()
        defer { cleanup(root) }

        let result = KnowledgeTool.handle(
            arguments: ["action": .string("get"), "entity": .string("NonExistentWidget")],
            session: session
        )
        #expect(result.isError == true)
        let text = result.content.first.flatMap { if case .text(let t, _, _) = $0 { return t } else { return nil } } ?? ""
        #expect(text.contains("NonExistentWidget"), "Error should name the missing entity")
    }

    // 6. search returns hits for known content
    @Test func testKnowledgeSearchReturnsHits() {
        let (session, root) = makeTestSession()
        defer { cleanup(root) }

        session.knowledgeStore.upsertEntity(KnowledgeEntity(
            name: "SearchableWorker",
            markdownPath: ".senkani/knowledge/SearchableWorker.md",
            compiledUnderstanding: "processes background jobs asynchronously"
        ))

        let result = KnowledgeTool.handle(
            arguments: ["action": .string("search"), "query": .string("background jobs")],
            session: session
        )
        #expect(result.isError != true)
        let text = result.content.first.flatMap { if case .text(let t, _, _) = $0 { return t } else { return nil } } ?? ""
        #expect(text.contains("SearchableWorker"))
    }

    // 7. list returns all inserted entities
    @Test func testKnowledgeListAllEntities() {
        let (session, root) = makeTestSession()
        defer { cleanup(root) }

        insertEntity("ListAlpha", into: session.knowledgeStore)
        insertEntity("ListBeta", into: session.knowledgeStore)
        insertEntity("ListGamma", into: session.knowledgeStore)

        let result = KnowledgeTool.handle(
            arguments: ["action": .string("list")],
            session: session
        )
        #expect(result.isError != true)
        let text = result.content.first.flatMap { if case .text(let t, _, _) = $0 { return t } else { return nil } } ?? ""
        #expect(text.contains("ListAlpha"))
        #expect(text.contains("ListBeta"))
        #expect(text.contains("ListGamma"))
        #expect(text.contains("3 entit"))
    }

    // 8. relate returns entity links
    @Test func testKnowledgeRelateFound() {
        let (session, root) = makeTestSession()
        defer { cleanup(root) }

        let srcId = insertEntity("RelateSource", into: session.knowledgeStore)
        insertEntity("RelateTarget", into: session.knowledgeStore)
        session.knowledgeStore.insertLink(EntityLink(
            sourceId: srcId,
            targetName: "RelateTarget",
            relation: "depends_on"
        ))

        let result = KnowledgeTool.handle(
            arguments: ["action": .string("relate"), "entity": .string("RelateSource")],
            session: session
        )
        #expect(result.isError != true)
        let text = result.content.first.flatMap { if case .text(let t, _, _) = $0 { return t } else { return nil } } ?? ""
        #expect(text.contains("RelateTarget"))
        #expect(text.contains("depends_on"))
    }

    // 9. HookRouter.entityObserver fires on PostToolUse events
    @Test func testHookObserverFires() {
        // Save and restore observer after test
        let saved = HookRouter.entityObserver
        defer { HookRouter.entityObserver = saved }

        var firedToolName: String? = nil
        HookRouter.entityObserver = { toolName, _ in
            firedToolName = toolName
        }

        let event = postToolUseEvent(
            toolName: "Write",
            toolInput: ["file_path": "Sources/Core/Scheduler.swift", "content": "// Scheduler body"]
        )
        _ = HookRouter.handle(eventJSON: event)

        #expect(firedToolName == "Write", "Observer should fire with toolName 'Write'")
    }

    // 10. entityObserver feeds text into EntityTracker
    @Test func testEntityObserverFeedsTracker() {
        let (session, root) = makeTestSession()
        defer { cleanup(root) }

        // Save and restore observer after test
        let saved = HookRouter.entityObserver
        defer { HookRouter.entityObserver = saved }

        // Insert entity and reload tracker
        insertEntity("ObservedEntity", into: session.knowledgeStore)
        session.entityTracker.reloadEntities()

        // Wire observer to this session's tracker
        HookRouter.entityObserver = { toolName, toolInput in
            let texts = toolInput.values.compactMap { $0 as? String }.joined(separator: " ")
            if !texts.isEmpty {
                session.entityTracker.observe(text: texts, source: "test:hook:\(toolName)")
            }
        }

        // Fire PostToolUse with text mentioning the entity
        let event = postToolUseEvent(
            toolName: "Edit",
            toolInput: ["file_path": "Sources/Core/ObservedEntity.swift",
                        "new_string": "ObservedEntity handles state transitions"]
        )
        _ = HookRouter.handle(eventJSON: event)

        let state = session.entityTracker.state()
        #expect(state.sessionTotal["ObservedEntity"] != nil,
                "ObservedEntity should appear in session totals after hook observation")
        #expect(state.sessionTotal["ObservedEntity"]! >= 1)
    }
}
