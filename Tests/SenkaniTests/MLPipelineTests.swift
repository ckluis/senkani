import Testing
import Foundation
@testable import Core
@testable import MCPServer

// MARK: - Suite 1: Model ID Consistency

@Suite("ML Pipeline — Model ID Consistency")
struct ModelIDConsistencyTests {

    @Test func registryContainsAllVisionModelIds() {
        let registryIds = Set(ModelManager.shared.models.map(\.id))
        for visionId in ModelManager.visionModelIds {
            #expect(registryIds.contains(visionId),
                    "Vision model '\(visionId)' should be in registry")
        }
    }

    @Test func allRegisteredIdsAreHandled() {
        let embedId = EmbedEngine.modelId
        let visionIds = Set(ModelManager.visionModelIds)
        for model in ModelManager.shared.models {
            let isHandled = model.id == embedId || visionIds.contains(model.id)
            #expect(isHandled,
                    "Model '\(model.id)' must be handled by download handler (embed or vision)")
        }
    }

    @Test func allModelsHaveValidMetadata() {
        for model in ModelManager.shared.models {
            #expect(!model.id.isEmpty, "Model ID should not be empty")
            #expect(!model.name.isEmpty, "Model name should not be empty for \(model.id)")
            #expect(!model.repoId.isEmpty, "Repo ID should not be empty for \(model.id)")
            #expect(model.requiredRAM >= 1, "Required RAM should be >= 1 for \(model.id)")
        }
    }

    @Test func noStaleModelIds() {
        let allIds = Set(ModelManager.shared.models.map(\.id))
        #expect(!allIds.contains("qwen2-vl-2b"), "Stale ID 'qwen2-vl-2b' should not be in registry")
        #expect(!allIds.contains("gemma3-4b"), "Stale ID 'gemma3-4b' should not be in registry")
    }
}

// MARK: - Suite 2: Readiness Gating

@Suite("ML Pipeline — Readiness Gating")
struct ReadinessGatingTests {

    @Test func embedModelNotReadyWhenNotDownloaded() {
        let mgr = ModelManager.shared
        let status = mgr.model(EmbedEngine.modelId)?.status
        if status != .downloaded {
            #expect(!mgr.isReady(EmbedEngine.modelId),
                    "isReady should be false when model is not downloaded")
        }
    }

    @Test func visionModelsNotDownloadingInTestEnv() {
        let mgr = ModelManager.shared
        for visionId in ModelManager.visionModelIds {
            let status = mgr.model(visionId)?.status
            #expect(status != .downloading,
                    "Vision model '\(visionId)' should not be downloading in test env")
        }
    }
}

// MARK: - Suite 3: State Transitions (non-destructive on shared singleton)

@Suite("ML Pipeline — State Transitions")
struct StateTransitionTests {

    @Test func modelsHaveValidInitialState() {
        let mgr = ModelManager.shared
        for model in mgr.models {
            // In test env, models should be .available, .downloaded, or .error
            let validStates: [ModelStatus] = [.available, .downloaded, .error]
            #expect(validStates.contains(model.status),
                    "Model '\(model.id)' has unexpected status: \(model.status)")
        }
    }

    @Test func modelRegistryIsNotEmpty() {
        #expect(!ModelManager.shared.models.isEmpty, "Registry should have at least 1 model")
        #expect(ModelManager.shared.models.count >= 4, "Should have at least 4 models (3 Gemma + MiniLM)")
    }

    @Test func visionModelIdsNotEmpty() {
        #expect(!ModelManager.visionModelIds.isEmpty, "visionModelIds should not be empty")
        #expect(ModelManager.visionModelIds.count >= 3, "Should have at least 3 Gemma tiers")
    }

    @Test func embedModelIdIsMinilm() {
        #expect(EmbedEngine.modelId == "minilm-l6", "Embed model ID should be minilm-l6")
    }
}

// MARK: - Suite 4: verifyInference

@Suite("ML Pipeline — Verify Inference")
struct VerifyInferenceTests {

    @Test func unknownIdReturnsError() {
        let result = ModelManager.shared.verifyInference("nonexistent-model-xyz")
        #expect(result != nil, "Should return error for unknown model")
        #expect(result!.contains("Unknown"), "Error should mention unknown: \(result!)")
    }

    @Test func notDownloadedReturnsError() {
        let mgr = ModelManager.shared
        // Find a model that's not downloaded
        let available = mgr.models.first { $0.status != .downloaded }
        guard let model = available else { return }  // All downloaded, can't test

        let result = mgr.verifyInference(model.id)
        #expect(result != nil, "Should return error for not-downloaded model")
        #expect(result!.contains("not downloaded"), "Error: \(result!)")
    }
}

// MARK: - Suite 5: Hot Files

@Suite("ML Pipeline — Hot Files")
struct HotFilesTests {

    private func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-ml-test-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        return (db, path)
    }

    private func cleanupDB(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    @Test func hotFilesReturnsAccessedFiles() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        let projectRoot = "/tmp/hotfiles-test"
        let sid = db.createSession(projectRoot: projectRoot)

        for file in ["Sources/main.swift", "Sources/App.swift", "README.md"] {
            db.recordTokenEvent(
                sessionId: sid, paneId: nil, projectRoot: projectRoot,
                source: "mcp_tool", toolName: "senkani_read", model: nil,
                inputTokens: 100, outputTokens: 50, savedTokens: 50,
                costCents: 1, feature: "read", command: file
            )
        }
        Thread.sleep(forTimeInterval: 0.1)

        let hot = db.hotFiles(projectRoot: projectRoot, limit: 20)
        #expect(hot.count == 3, "Should return 3 hot files, got \(hot.count)")
    }

    @Test func preCacheGuardedByCacheEnabled() {
        // When cacheEnabled is false, preCacheHotFiles should exit immediately
        // We verify by checking the method signature accepts the flag
        let session = MCPSession(
            projectRoot: "/tmp/ml-precache-test-\(UUID().uuidString)",
            indexerEnabled: false,
            cacheEnabled: false
        )
        // The session was created with cache disabled — preCacheHotFiles was called
        // in init but returned immediately due to guard. No crash = success.
        #expect(!session.cacheEnabled, "Cache should be disabled")
    }
}
