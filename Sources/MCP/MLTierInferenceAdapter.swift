import Foundation
import Bench
import Core
import MLXLMCommon
import MLXVLM

// MARK: - MLTierInferenceAdapter
//
// Single-tier inference closure for `senkani ml-eval`. Loads ONE Gemma 4
// VLM at a time (caller decides which repo via `load(repoId:)`), then
// answers `MLTierEvalTask`s through `run(task:)`. Bench's eval runner is
// tier-agnostic — this adapter is the bridge between an `MLTierEvalTask`
// (pure data) and the live MLX container.
//
// Why a per-tier adapter rather than the existing `VisionEngine` /
// `GemmaInferenceAdapter`: those pick whichever tier best fits available
// RAM and reuse it. The eval needs to drive a SPECIFIC tier (whichever the
// orchestrator picked next), tear it down, and load the next. Reusing the
// shared engines would either (a) keep loading the same biggest-fitting
// tier, or (b) require new "force this repoId" entry points cluttering the
// production engines. Splitting the eval-only path keeps the prod loaders
// untouched.
//
// Actor-isolated: container load + generate are CPU/GPU heavy; we don't
// want concurrent `evaluate` calls thrashing the Metal pool. The shared
// `MLXInferenceLock` adds the global serialization that also protects
// concurrent embed / vision tools running in the same process.

public actor MLTierInferenceAdapter {

    private var container: ModelContainer?
    private var loadedRepoId: String?

    /// Token cap per task. Eval tasks expect short answers (the "expected
    /// substring" is usually one phrase); 256 tokens is generous and keeps
    /// even the smallest tier's per-task latency under ~3 s on Apple
    /// Silicon. Matches `VisionTool.analyze` order of magnitude (512).
    private let maxTokens: Int

    public init(maxTokens: Int = 256) {
        self.maxTokens = maxTokens
    }

    /// Currently loaded repo, if any. Visible for diagnostics.
    public var currentRepoId: String? { loadedRepoId }

    /// Load the named VLM tier. No-op if `repoId` already loaded.
    /// Throws on load failure — caller records the tier as `notEvaluated`
    /// with the error message and proceeds to the next tier.
    public func load(repoId: String) async throws {
        if container != nil, loadedRepoId == repoId { return }
        if container != nil { unload() }
        let config = ModelConfiguration(id: repoId)
        let mc = try await VLMModelFactory.shared.loadContainer(
            configuration: config,
            progressHandler: { _ in }
        )
        container = mc
        loadedRepoId = repoId
    }

    /// Drop the loaded container so the next `load(repoId:)` can pick a
    /// different (often larger or smaller) tier without OOM.
    public func unload() {
        container = nil
        loadedRepoId = nil
    }

    /// Answer one eval task with the currently-loaded tier. Vision tasks
    /// attach the resolved fixture image; rationale tasks send text only.
    /// Returns the raw response and an output-token PROXY (chunk count) —
    /// `MLXLMCommon.Generation` doesn't expose a precise token count from
    /// every chunk so we count emitted chunks; the report's
    /// `totalOutputTokens` is therefore "chunks emitted," surfaced as
    /// tokens-of-the-same-order. Refine if MLX adds a precise counter.
    public func run(task: MLTierEvalTask) async throws -> (response: String, outputTokens: Int) {
        guard let mc = container else {
            throw NSError(
                domain: "dev.senkani.MLTierInferenceAdapter", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "no container loaded — call load(repoId:) first"]
            )
        }
        let cap = self.maxTokens
        return try await MLXInferenceLock.shared.run {
            let userInput: UserInput
            if task.category == .vision, let imageURL = task.imageURL {
                userInput = UserInput(prompt: task.prompt, images: [.url(imageURL)])
            } else {
                userInput = UserInput(prompt: task.prompt, images: [])
            }
            let input = try await mc.prepare(input: userInput)
            let params = GenerateParameters(maxTokens: cap)
            var result = ""
            var chunks = 0
            let stream = try await mc.generate(input: input, parameters: params)
            for await generation in stream {
                switch generation {
                case .chunk(let text):
                    result += text
                    chunks += 1
                case .info, .toolCall:
                    break
                }
            }
            return (response: result, outputTokens: chunks)
        }
    }
}
