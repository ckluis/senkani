import Foundation
import Core
import MLXLMCommon
import MLXVLM

// MARK: - MLXProseCadenceCompiler
//
// Phase U.8b — MLX-backed prose→cron compiler (Gemma 4 VLM, text-only
// path). Mirrors `Sources/MCP/GemmaInferenceAdapter.swift` structurally
// for the actor shape, lazy model load, unload-handler registration,
// and `MLXInferenceLock.shared.run { … }` serialization wrapper.
//
// ### What lives here in U.8b-1 (this child)
//
// The actor skeleton, lock + unload-handler plumbing, and a single
// `compile()` body that throws `.unavailable` for every input. The
// throw lives inside the `MLXInferenceLock.shared.run { … }` wrapper
// so the next child (U.8b-2) only needs to fill in `ensureModel()` +
// the prompt + stream + JSON-parse + cron-gate; the lock topology is
// frozen by this child's smoke test.
//
// ### What does NOT live here yet
//
// - `ensureModel()` (the RAM-tiered Gemma 4 VLM ladder) — U.8b-2.
// - The few-shot prompt + JSON-mode response schema — U.8b-2.
// - The cron-validation gate via `CronToLaunchd.convert(_:)` — U.8b-2.
// - CLI wiring (`ScheduleCommand.proseCompilerFactory` swap) — U.8b-4.
// - Composite (rule-first, MLX-fallback) selection — U.8b-3.
//
// ### Reentrancy
//
// `MLXInferenceLock.shared.run` releases via `defer { release() }`, so
// a thrown error from inside the closure correctly drops the lock; the
// scaffold relies on that guarantee.
//
// ### Unload handler
//
// Registered in `init()` (mirrors `GemmaInferenceAdapter`'s lazy
// registration in `ensureModel()` — moved earlier here because the
// scaffold has no `ensureModel()` to gate registration on yet, and the
// handler's no-op semantics are safe when `modelContainer` is `nil`).

public actor MLXProseCadenceCompiler: ProseCadenceCompiler {

    /// Loaded VLM container. Stays `nil` in U.8b-1 (no model load
    /// path); U.8b-2 fills `ensureModel()` and assigns this.
    private var modelContainer: ModelContainer?

    /// Loaded model id (e.g. `gemma-3-4b-it-qat`). Stays `nil` in
    /// U.8b-1; U.8b-2 assigns alongside `modelContainer`.
    private var loadedModelId: String?

    /// One-shot unload-handler registration guard.
    private var unloadHandlerRegistered = false

    /// Token cap on JSON generation. Cron-JSON is a short envelope
    /// (~10–20 tokens of payload); 128 is generous and keeps any
    /// future Gemma tier under ~1 s when the call lands in U.8b-2.
    private let maxTokens: Int

    public init(maxTokens: Int = 128) {
        self.maxTokens = maxTokens
        // Defer the actual MLXInferenceLock.shared.registerUnloadHandler
        // call to the first compile invocation (matches the Gemma
        // adapter's lazy pattern). Doing it from a non-async init
        // would require `Task { … }` which complicates test
        // determinism.
    }

    /// Drop any loaded VLM. Called by MLXInferenceLock on memory
    /// warning. No-op in U.8b-1 (nothing is ever loaded); the
    /// signature is locked here so U.8b-2 only fills in the body.
    func unload() {
        modelContainer = nil
        loadedModelId = nil
    }

    public func compile(
        prose: String,
        locale: String
    ) async throws -> ProseCadence {
        // Lazy unload-handler registration. Mirrors
        // `GemmaInferenceAdapter.ensureModel()`'s pattern — kept here
        // (rather than `init`) so the registration is async-context-
        // safe and lazy. Idempotent via `unloadHandlerRegistered`.
        if !unloadHandlerRegistered {
            unloadHandlerRegistered = true
            await MLXInferenceLock.shared.registerUnloadHandler { [weak self] in
                await self?.unload()
            }
        }

        return try await MLXInferenceLock.shared.run {
            // U.8b-1 contract: every input throws `.unavailable`. The
            // throw lives inside the lock body so U.8b-2's
            // `ensureModel()` + stream collection + JSON-decode + cron
            // gate land in this exact slot without reshuffling the
            // serialization wrapper or the lazy-registration above.
            //
            // The Sendable closure captures no actor state — the
            // throw is a value-typed enum case, safe to escape.
            throw ProseCadenceCompilerError.unavailable
        }
    }
}
