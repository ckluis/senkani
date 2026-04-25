import Foundation
import MCP
import MLXLMCommon
import MLXVLM
import Core

/// Local vision model for screenshot analysis, OCR, and UI verification.
/// Cost: $0 (local Apple Silicon inference) vs $0.01+ per GPT-4o vision call.
///
/// Fallback chain: auto-selected Gemma 4 tier (by RAM) → smaller tiers → error.
/// Inference is serialized globally by `MLXInferenceLock.shared` — a concurrent
/// `senkani_embed` or `senkani_vision` call from another session queues up
/// instead of thrashing the Metal pool.
///
/// Memory pressure: this engine registers an unload handler with the lock
/// on first load. A macOS memory-pressure warning invokes the handler,
/// which nils out `modelContainer`; the next call re-loads via the
/// RAM-aware fallback chain and naturally steps down to a smaller tier
/// if RAM shrank.
actor VisionEngine {
    private var modelContainer: ModelContainer?

    /// Which model is currently loaded, tracked for ModelManager reporting.
    private(set) var loadedModelId: String?

    /// True once we've registered an unload handler with MLXInferenceLock.
    private var unloadHandlerRegistered = false

    /// Drop the loaded VLM. Called by MLXInferenceLock on memory warning.
    func unload() {
        modelContainer = nil
        loadedModelId = nil
    }

    /// Build a RAM-ordered fallback chain from ModelManager's Gemma 4 tiers.
    /// Tries the recommended (highest-quality) tier first, falls back to smaller ones.
    static var fallbackChain: [(modelId: String, repoId: String)] {
        let mgr = ModelManager.shared
        let ram = ModelManager.availableRAMGB
        // All Gemma 4 models, sorted by quality (highest RAM requirement = best quality)
        return ModelManager.visionModelIds.compactMap { id in
            guard let info = mgr.model(id), info.requiredRAM <= ram else { return nil }
            return (id, info.repoId)
        }
    }

    /// Load a VLM using the RAM-based fallback chain. Tries each model in order.
    /// Returns (container, modelId) for the first model that loads successfully.
    func ensureModel() async throws -> (ModelContainer, String) {
        if let mc = modelContainer, let id = loadedModelId {
            return (mc, id)
        }

        if !unloadHandlerRegistered {
            unloadHandlerRegistered = true
            await MLXInferenceLock.shared.registerUnloadHandler { [weak self] in
                await self?.unload()
            }
        }

        let chain = Self.fallbackChain
        guard !chain.isEmpty else {
            throw NSError(
                domain: "senkani", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No Gemma 4 model fits in \(ModelManager.availableRAMGB)GB RAM. Need at least 4GB."]
            )
        }

        var lastError: Error?

        for (modelId, repoId) in chain {
            do {
                ModelManager.shared.updateProgress(modelId, progress: 0.0)
                let config = ModelConfiguration(id: repoId)
                let mc = try await VLMModelFactory.shared.loadContainer(
                    configuration: config
                ) { progress in
                    ModelManager.shared.updateProgress(modelId, progress: progress.fractionCompleted)
                }
                modelContainer = mc
                loadedModelId = modelId
                ModelManager.shared.markDownloaded(modelId)
                fputs("senkani: vision model loaded: \(modelId) (\(repoId))\n", stderr)
                return (mc, modelId)
            } catch {
                fputs("senkani: vision model \(modelId) failed: \(error.localizedDescription), trying next tier\n", stderr)
                ModelManager.shared.markError(modelId, message: error.localizedDescription)
                lastError = error
            }
        }

        throw lastError ?? NSError(
            domain: "senkani",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "All Gemma 4 tiers failed to load. Tried: \(chain.map(\.modelId).joined(separator: ", "))"]
        )
    }

    /// Analyze an image with an optional prompt. Serialized globally by
    /// `MLXInferenceLock` so a concurrent embedding or rationale call
    /// queues rather than thrashing Metal.
    func analyze(imagePath: String, prompt: String) async throws -> String {
        guard FileManager.default.fileExists(atPath: imagePath) else {
            throw NSError(domain: "senkani", code: 1, userInfo: [NSLocalizedDescriptionKey: "Image not found: \(imagePath)"])
        }
        let imageURL = URL(fileURLWithPath: imagePath)

        return try await MLXInferenceLock.shared.run {
            let (mc, _) = try await self.ensureModel()
            let userInput = UserInput(prompt: prompt, images: [.url(imageURL)])
            let input = try await mc.prepare(input: userInput)
            let params = GenerateParameters(maxTokens: 512)

            var result = ""
            let stream = try await mc.generate(input: input, parameters: params)
            for await generation in stream {
                switch generation {
                case .chunk(let text):
                    result += text
                case .info, .toolCall:
                    break
                }
            }
            return result
        }
    }
}

enum VisionTool {
    static let engine = VisionEngine()

    static func handle(arguments: [String: Value]?, session: MCPSession) async -> CallTool.Result {
        guard let imagePath = arguments?["image"]?.stringValue else {
            return .init(content: [.text(text: "Error: 'image' path is required", annotations: nil, _meta: nil)], isError: true)
        }

        // Gate on ModelManager readiness — check all models in fallback chain
        let mgr = ModelManager.shared
        let anyDownloading = VisionEngine.fallbackChain.contains { (modelId, _) in
            mgr.model(modelId)?.status == .downloading
        }
        if anyDownloading {
            // Find the one currently downloading
            for (modelId, _) in VisionEngine.fallbackChain {
                if let info = mgr.model(modelId), info.status == .downloading {
                    let pct = Int(info.downloadProgress * 100)
                    return .init(content: [.text(text: "Vision model '\(info.name)' is downloading (\(pct)%). Please wait and retry.", annotations: nil, _meta: nil)], isError: true)
                }
            }
        }

        let absPath: String
        do {
            absPath = try ProjectSecurity.resolveProjectFile(imagePath, projectRoot: session.projectRoot)
        } catch {
            return .init(
                content: [.text(text: "Error: \(error)", annotations: nil, _meta: nil)],
                isError: true
            )
        }
        let prompt = arguments?["prompt"]?.stringValue ?? "Describe this image in detail. Note any text, UI elements, buttons, errors, or notable features."

        do {
            let result = try await engine.analyze(imagePath: absPath, prompt: prompt)

            // Estimate savings: a GPT-4o vision call on a typical screenshot is ~1000 tokens input
            // Our local call is $0
            session.recordMetrics(rawBytes: 4000, compressedBytes: result.utf8.count, feature: "vision",
                                  command: absPath, outputPreview: String(result.prefix(200)))

            let output = "// senkani_vision: analyzed locally ($0, on-device VLM)\n\(result)"
            return .init(content: [.text(text: output, annotations: nil, _meta: nil)])
        } catch {
            return .init(content: [.text(text: "Vision error: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }
    }
}
