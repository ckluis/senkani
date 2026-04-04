import Foundation
import MCP
import MLXLMCommon
import MLXVLM
import Core

/// Local vision model for screenshot analysis, OCR, and UI verification.
/// Cost: $0 (local Apple Silicon inference) vs $0.01+ per GPT-4o vision call.
actor VisionEngine {
    private var modelContainer: ModelContainer?

    /// The model ID used for ModelManager tracking.
    static let modelId = "qwen2-vl-2b"

    /// Load the VLM. ModelManager must report ready before calling this.
    func ensureModel() async throws -> ModelContainer {
        if let mc = modelContainer { return mc }
        ModelManager.shared.updateProgress(Self.modelId, progress: 0.0)
        let mc = try await VLMModelFactory.shared.loadContainer(
            configuration: VLMRegistry.qwen2VL2BInstruct4Bit
        ) { progress in
            ModelManager.shared.updateProgress(Self.modelId, progress: progress.fractionCompleted)
        }
        modelContainer = mc
        ModelManager.shared.markDownloaded(Self.modelId)
        return mc
    }

    /// Analyze an image with an optional prompt.
    func analyze(imagePath: String, prompt: String) async throws -> String {
        let mc = try await ensureModel()

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

        // Gate on ModelManager readiness — if not downloaded, guide the user
        let mgr = ModelManager.shared
        if !mgr.isReady(VisionEngine.modelId) {
            let info = mgr.model(VisionEngine.modelId)
            let size = ModelManager.formatBytes(info?.expectedSizeBytes ?? 1_500_000_000)
            let status = info?.status ?? .available
            switch status {
            case .downloading:
                let pct = Int((info?.downloadProgress ?? 0) * 100)
                return .init(content: [.text(text: "Vision model is downloading (\(pct)%). Please wait and retry.", annotations: nil, _meta: nil)], isError: true)
            case .error:
                let msg = info?.lastError ?? "unknown error"
                return .init(content: [.text(text: "Vision model failed to download: \(msg). The model (\(size)) will re-download on next attempt.", annotations: nil, _meta: nil)], isError: true)
            case .available:
                // Model not yet cached — allow the download to proceed via ensureModel()
                break
            case .downloaded:
                break // shouldn't reach here given the isReady check above
            }
        }

        let absPath = imagePath.hasPrefix("/") ? imagePath : session.projectRoot + "/" + imagePath
        let prompt = arguments?["prompt"]?.stringValue ?? "Describe this image in detail. Note any text, UI elements, buttons, errors, or notable features."

        do {
            let result = try await engine.analyze(imagePath: absPath, prompt: prompt)

            // Estimate savings: a GPT-4o vision call on a typical screenshot is ~1000 tokens input
            // Our local call is $0
            session.recordMetrics(rawBytes: 4000, compressedBytes: result.utf8.count, feature: "vision")

            let output = "// senkani_vision: analyzed locally ($0, ~1.5GB model)\n\(result)"
            return .init(content: [.text(text: output, annotations: nil, _meta: nil)])
        } catch {
            return .init(content: [.text(text: "Vision error: \(error.localizedDescription)", annotations: nil, _meta: nil)], isError: true)
        }
    }
}
