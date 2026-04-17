import Foundation
import Core
import MLXLMCommon
import MLXVLM

// MARK: - GemmaInferenceAdapter
//
// Phase H+2a — MLX-backed `RationaleLLM` using an already-downloaded
// Gemma 4 VLM for text-only rationale rewriting. Reuses the VLM that
// `senkani_vision` loads; if the user hasn't downloaded one yet, every
// call throws `RationaleLLMError.unavailable` and the rewriter's silent-
// fallback path fires.
//
// Why reuse the VLM: it's the model we already know how to load. A
// text-only Gemma tier would cut RAM but is a separate download path.
// H+2a keeps scope tight — reuse wins until telemetry says otherwise.
//
// Actor-serialized: inference is CPU/GPU bound and we don't want two
// enrichments running concurrently on the same container.

public actor GemmaInferenceAdapter: RationaleLLM {

    /// Shared container across calls — `ModelContainer` load is the
    /// expensive step. First call pays it; subsequent calls reuse.
    private var modelContainer: ModelContainer?
    private var loadedModelId: String?

    /// Token cap on generation. Rationales are one sentence; 128 tokens
    /// is generous and keeps even the smallest Gemma tier under ~1 s.
    private let maxTokens: Int

    public init(maxTokens: Int = 128) {
        self.maxTokens = maxTokens
    }

    public func rewrite(prompt: String) async throws -> String {
        let container: ModelContainer
        do {
            container = try await ensureModel()
        } catch {
            // Treat all load failures as "model unavailable" — the
            // rewriter is a best-effort path and callers must never
            // see a thrown error surface anywhere except as a silent
            // nil rewrite.
            throw RationaleLLMError.unavailable
        }

        // Text-only UserInput. Empty image array is the text-only path
        // for VLMs; Gemma 4 handles it fine.
        let userInput = UserInput(prompt: prompt, images: [])

        do {
            let input = try await container.prepare(input: userInput)
            let params = GenerateParameters(maxTokens: maxTokens)
            var result = ""
            let stream = try await container.generate(input: input, parameters: params)
            for await generation in stream {
                switch generation {
                case .chunk(let text):
                    result += text
                case .info, .toolCall:
                    break
                }
            }
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw RationaleLLMError.emptyResponse }
            return trimmed
        } catch let e as RationaleLLMError {
            throw e
        } catch is CancellationError {
            throw RationaleLLMError.cancelled
        } catch {
            throw RationaleLLMError.invalidResponse(error.localizedDescription)
        }
    }

    // MARK: - Model loading

    /// Load the first Gemma 4 VLM tier that fits in available RAM.
    /// Mirrors `VisionEngine.ensureModel` — kept as a private copy here
    /// so the rationale adapter doesn't depend on the VisionTool module
    /// layout changing out from under it.
    private func ensureModel() async throws -> ModelContainer {
        if let mc = modelContainer { return mc }

        let mgr = ModelManager.shared
        let ram = ModelManager.availableRAMGB
        let chain: [(modelId: String, repoId: String)] =
            ModelManager.visionModelIds.compactMap { id in
                guard let info = mgr.model(id), info.requiredRAM <= ram else { return nil }
                return (id, info.repoId)
            }

        guard !chain.isEmpty else {
            throw NSError(domain: "senkani.rationale", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "No Gemma 4 VLM tier fits in \(ram) GB RAM."
            ])
        }

        var lastError: Error?
        for (modelId, repoId) in chain {
            do {
                let config = ModelConfiguration(id: repoId)
                let mc = try await VLMModelFactory.shared.loadContainer(
                    configuration: config,
                    progressHandler: { _ in }
                )
                modelContainer = mc
                loadedModelId = modelId
                FileHandle.standardError.write(Data(
                    "senkani.rationale: Gemma VLM loaded: \(modelId)\n".utf8))
                return mc
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? NSError(domain: "senkani.rationale", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "All Gemma tiers failed to load."])
    }
}
