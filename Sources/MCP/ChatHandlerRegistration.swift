import Foundation
import Core
import MLXLMCommon
import MLXVLM

/// V.13 real-chat — MCP-side adapter that registers an MLX-backed
/// `ChatEngine` with `Core.ModelManager`. `ServeCommand` (in CLI) resolves
/// this at request time when `senkani serve --openai` handles
/// `POST /v1/chat/completions`. Mirrors `EmbeddingHandlerRegistration` —
/// Core stays MLX-free; the CLI link surface is unchanged.
///
/// The adapter delegates to `MLXChatEngine` (below), which loads the
/// largest Gemma 4 VLM tier that fits in RAM and runs text-only inference
/// under `MLXInferenceLock.shared`. Mirrors `GemmaInferenceAdapter`'s
/// load chain so memory-pressure unload + RAM-aware tier selection
/// behave identically across the two text-only Gemma consumers.
struct MLXChatEngineAdapter: ChatEngine {
    func chat(
        model: String,
        messages: [ChatCompletionRequest.Message],
        tools: [ChatCompletionRequest.Tool]
    ) async throws -> OpenAIChatHandler.Completion {
        // Role-prefixed prompt assembly. Karpathy audit (2026-05-30) flagged
        // that plain `messages.map(\.content).joined("\n")` (the placeholder
        // approach) loses turn boundaries. Tokenizer-template-accurate
        // assembly lands in sub-item 3; this is the minimum viable
        // role-aware prompt for Gemma 4 instruction-tuned models.
        let prompt = MLXChatPrompt.assemble(messages: messages)

        // V.13 real-chat (sub-item 3) — capture the MLX `.info`
        // (`GenerateCompletionInfo`) so the OpenAI response's
        // `usage.prompt_tokens` / `usage.completion_tokens` reflect the
        // real Gemma tokenizer count, not the ~4-chars/token heuristic.
        // The heuristic counts are kept as the always-present fallback;
        // `OpenAIChatHandler.handle(...)` prefers the real fields when set.
        let outcome = try await MLXChatEngine.shared.completeWithInfo(prompt: prompt)
        let heuristicPrompt = OpenAIChatHandler.estimateTokens(prompt)
        let heuristicCompletion = OpenAIChatHandler.estimateTokens(outcome.content)
        return OpenAIChatHandler.Completion(
            content: outcome.content,
            promptTokens: heuristicPrompt,
            completionTokens: heuristicCompletion,
            realPromptTokens: outcome.info?.promptTokenCount,
            realCompletionTokens: outcome.info?.generationTokenCount
        )
    }
}

/// V.13 real-chat (sub-item 2) — MCP-side adapter wiring `MLXChatEngine`'s
/// token-stream API into Core's `StreamingChatEngine` seam. Emits one
/// `TokenDelta` per MLX `Generation.chunk` as the model produces it, so
/// `senkani serve --openai`'s SSE deltas reflect real arrival timing rather
/// than v13b's post-hoc content chunking. Sub-item 3 layers
/// readiness-503 + tokenizer-accurate usage; this child ships the
/// real-token-arrival surface only.
struct MLXStreamingChatEngineAdapter: StreamingChatEngine {
    func stream(
        model: String,
        messages: [ChatCompletionRequest.Message],
        tools: [ChatCompletionRequest.Tool]
    ) -> AsyncThrowingStream<OpenAIChatHandler.TokenDelta, Error> {
        let prompt = MLXChatPrompt.assemble(messages: messages)
        let upstream = MLXChatEngine.shared.stream(prompt: prompt)
        return AsyncThrowingStream<OpenAIChatHandler.TokenDelta, Error> { continuation in
            let task = Task {
                do {
                    for try await chunk in upstream {
                        if Task.isCancelled { break }
                        continuation.yield(OpenAIChatHandler.TokenDelta(content: chunk))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Shared prompt assembly used by both the non-streaming and streaming MLX
/// adapters so the two surfaces send identical bytes to MLX. Tokenizer-
/// template-accurate assembly lands in sub-item 3 (chat-template path); for
/// today, role-prefixed flat text matches what Gemma 4 instruction-tuned
/// models tolerate.
enum MLXChatPrompt {
    static func assemble(messages: [ChatCompletionRequest.Message]) -> String {
        return messages.map { msg -> String in
            "[\(msg.role)] \(msg.content)"
        }.joined(separator: "\n") + "\n[assistant] "
    }
}

enum ChatHandlerRegistration {
    /// Register the MLX-backed chat handlers (non-streaming + streaming)
    /// with `ModelManager.shared`. Called from `MCPServerRunner.run` at
    /// startup; idempotent (the registration slots replace on second call).
    static func register() {
        ModelManager.shared.registerChatHandler(MLXChatEngineAdapter())
        ModelManager.shared.registerStreamingChatHandler(MLXStreamingChatEngineAdapter())
    }
}

/// V.13 real-chat — text-only Gemma 4 VLM inference shared across calls.
/// Mirrors `GemmaInferenceAdapter` closely (same RAM-aware fallback chain,
/// same empty-images text-only `UserInput`, same memory-pressure unload
/// hook), but exposes a chat-shaped `complete(prompt:)` returning the
/// generated string. Actor-serialized so two concurrent
/// `/v1/chat/completions` requests don't thrash the Metal pool —
/// `MLXInferenceLock.shared` provides process-wide serialization across
/// all MLX consumers (embed, vision, rationale, chat).
actor MLXChatEngine {
    static let shared = MLXChatEngine()

    /// Token cap on generation. VisionTool uses 512 for image descriptions;
    /// chat completions are typically longer but capped for safety. Sub-
    /// item 3 will surface this via config; for now, 512 matches the
    /// existing Gemma consumer's budget.
    private let maxTokens: Int = 512

    private var modelContainer: ModelContainer?
    private var loadedModelId: String?
    private var unloadHandlerRegistered = false

    /// Drop the loaded VLM. Called by MLXInferenceLock on memory warning.
    func unload() {
        modelContainer = nil
        loadedModelId = nil
    }

    func complete(prompt: String) async throws -> String {
        return try await completeWithInfo(prompt: prompt).content
    }

    /// V.13 real-chat (sub-item 3) — same generation loop as
    /// `complete(prompt:)` but also captures the terminal
    /// `Generation.info(GenerateCompletionInfo)` so the OpenAI handler
    /// can surface real tokenizer counts in `usage.prompt_tokens` /
    /// `usage.completion_tokens`. The `info` is the last event MLX
    /// emits with the prompt + generation token counts measured by the
    /// real Gemma tokenizer; if no `.info` is observed (engine drift /
    /// early cancel), the field is nil and the OpenAI handler falls
    /// back to the heuristic counts in `Completion.promptTokens` /
    /// `Completion.completionTokens`.
    struct CompletionOutcome: Sendable {
        let content: String
        let info: GenerateCompletionInfo?
    }
    func completeWithInfo(prompt: String) async throws -> CompletionOutcome {
        return try await MLXInferenceLock.shared.run { [maxTokens] in
            let container = try await self.ensureModel()
            // Empty images array is the text-only path for VLMs; Gemma 4
            // handles it (matches GemmaInferenceAdapter's pattern).
            // Constructed inside the Sendable closure — `UserInput` is
            // not Sendable.
            let userInput = UserInput(prompt: prompt, images: [])
            let input = try await container.prepare(input: userInput)
            let params = GenerateParameters(maxTokens: maxTokens)
            var result = ""
            var observedInfo: GenerateCompletionInfo?
            let stream = try await container.generate(input: input, parameters: params)
            for await generation in stream {
                switch generation {
                case .chunk(let text):
                    result += text
                case .info(let info):
                    observedInfo = info
                case .toolCall:
                    break
                }
            }
            return CompletionOutcome(
                content: result.trimmingCharacters(in: .whitespacesAndNewlines),
                info: observedInfo
            )
        }
    }

    /// V.13 real-chat (sub-item 2) — yield each MLX `Generation.chunk` as
    /// the model produces it. Mirrors `complete(prompt:)` byte-for-byte
    /// except: (1) chunks are yielded to the continuation rather than
    /// concatenated, (2) no end-of-stream `trimmingCharacters` since the
    /// caller can't unwrite earlier deltas — clients accumulate the SSE
    /// `delta.content` verbatim. The whole pipeline runs INSIDE
    /// `MLXInferenceLock.shared.run` so the actor / lock semantics match
    /// the non-streaming path; the continuation yields synchronously
    /// (non-blocking) inside the lock body.
    nonisolated func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error> { continuation in
            let task = Task { [maxTokens] in
                do {
                    try await MLXInferenceLock.shared.run {
                        let container = try await self.ensureModel()
                        let userInput = UserInput(prompt: prompt, images: [])
                        let input = try await container.prepare(input: userInput)
                        let params = GenerateParameters(maxTokens: maxTokens)
                        let mlxStream = try await container.generate(input: input, parameters: params)
                        for await generation in mlxStream {
                            if Task.isCancelled { break }
                            switch generation {
                            case .chunk(let text):
                                continuation.yield(text)
                            case .info, .toolCall:
                                break
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Load the first Gemma 4 VLM tier that fits in available RAM.
    /// Mirrors `VisionEngine.ensureModel` / `GemmaInferenceAdapter.ensureModel`
    /// — kept as a private copy so the chat adapter doesn't depend on
    /// either module's layout changing out from under it.
    private func ensureModel() async throws -> ModelContainer {
        if let mc = modelContainer { return mc }

        if !unloadHandlerRegistered {
            unloadHandlerRegistered = true
            await MLXInferenceLock.shared.registerUnloadHandler { [weak self] in
                await self?.unload()
            }
        }

        let mgr = ModelManager.shared
        let ram = ModelManager.availableRAMGB
        let chain: [(modelId: String, repoId: String)] =
            ModelManager.visionModelIds.compactMap { id in
                guard let info = mgr.model(id), info.requiredRAM <= ram else { return nil }
                return (id, info.repoId)
            }

        guard !chain.isEmpty else {
            throw NSError(domain: "senkani.chat", code: 1, userInfo: [
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
                    "senkani.chat: Gemma VLM loaded: \(modelId)\n".utf8))
                return mc
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? NSError(domain: "senkani.chat", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "All Gemma tiers failed to load."])
    }
}
