import Foundation
import MCP
import MLXLMCommon
import MLXVLM
import Core

/// Local vision model for screenshot analysis, OCR, and UI verification.
/// Cost: $0 (local Apple Silicon inference) vs $0.01+ per GPT-4o vision call.
///
/// Fallback chain: Gemma 3 4B (preferred, better quality) -> Qwen2-VL 2B (smaller fallback) -> error.
/// Both models are actors, so concurrent calls are serialized safely by Swift concurrency.
///
/// TODO: Memory pressure handling — when running as a daemon (Phase 5), the loaded VLM
/// stays resident (~1.5-2.5GB). ModelContainer does not expose an unload/evict API.
/// Consider implementing an idle timer that nil-outs `modelContainer` after e.g. 10 minutes,
/// allowing ARC to free the MLX buffers. This requires measuring whether re-load latency
/// (~5-15s) is acceptable for the use case.
actor VisionEngine {
    private var modelContainer: ModelContainer?

    /// Which model is currently loaded, tracked for ModelManager reporting.
    private var loadedModelId: String?

    /// Fallback chain: try Gemma 3 first (better quality), then Qwen2-VL (smaller).
    static let fallbackChain: [(modelId: String, configuration: ModelConfiguration)] = [
        ("gemma3-4b", VLMRegistry.gemma3_4B_qat_4bit),
        ("qwen2-vl-2b", VLMRegistry.qwen2VL2BInstruct4Bit),
    ]

    /// Load a VLM using the fallback chain. Tries each model in order.
    /// Returns (container, modelId) for the first model that loads successfully.
    func ensureModel() async throws -> (ModelContainer, String) {
        if let mc = modelContainer, let id = loadedModelId {
            return (mc, id)
        }

        var lastError: Error?

        for (modelId, config) in Self.fallbackChain {
            do {
                ModelManager.shared.updateProgress(modelId, progress: 0.0)
                let mc = try await VLMModelFactory.shared.loadContainer(
                    configuration: config
                ) { progress in
                    ModelManager.shared.updateProgress(modelId, progress: progress.fractionCompleted)
                }
                modelContainer = mc
                loadedModelId = modelId
                ModelManager.shared.markDownloaded(modelId)
                fputs("senkani: vision model loaded: \(modelId) (\(config.name))\n", stderr)
                return (mc, modelId)
            } catch {
                fputs("senkani: vision model \(modelId) failed to load: \(error.localizedDescription), trying next fallback\n", stderr)
                ModelManager.shared.markError(modelId, message: error.localizedDescription)
                lastError = error
            }
        }

        throw lastError ?? NSError(
            domain: "senkani",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "All vision models failed to load. Tried: \(Self.fallbackChain.map(\.modelId).joined(separator: ", "))"]
        )
    }

    /// Analyze an image with an optional prompt.
    func analyze(imagePath: String, prompt: String) async throws -> String {
        let (mc, _) = try await ensureModel()

        let imageURL = URL(fileURLWithPath: imagePath)
        guard FileManager.default.fileExists(atPath: imagePath) else {
            throw NSError(domain: "senkani", code: 1, userInfo: [NSLocalizedDescriptionKey: "Image not found: \(imagePath)"])
        }

        let userInput = UserInput(
            prompt: prompt,
            images: [.url(imageURL)]
        )

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

        let absPath = imagePath.hasPrefix("/") ? imagePath : session.projectRoot + "/" + imagePath
        let prompt = arguments?["prompt"]?.stringValue ?? "Describe this image in detail. Note any text, UI elements, buttons, errors, or notable features."

        do {
            let result = try await engine.analyze(imagePath: absPath, prompt: prompt)

            // Estimate savings: a GPT-4o vision call on a typical screenshot is ~1000 tokens input
            // Our local call is $0
            session.recordMetrics(rawBytes: 4000, compressedBytes: result.utf8.count, feature: "vision")

            let output = "// senkani_vision: analyzed locally ($0, on-device VLM)\n\(result)"
            return .init(content: [.text(text: output, annotations: nil, _meta: nil)])
        } catch {
            return .init(content: [.text(text: "Vision error: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }
    }
}
