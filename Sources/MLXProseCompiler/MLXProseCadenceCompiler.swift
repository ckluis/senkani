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
// ### What lives here in U.8b-2 (this child)
//
// The full inference path. compile() flow:
//
//   1. `try Task.checkCancellation()` — earliest cheap rejection. Mapped
//      to `.cancelled`. Sits BEFORE the locale gate so a cancelled call
//      throws `.cancelled` regardless of locale (Kleppmann's ordering
//      point — principled cancel-first semantics).
//   2. English-only locale gate — non-`en-*` throws `.unsupportedLocale`
//      WITHOUT touching the MLXInferenceLock or attempting a model load.
//   3. Lazy unload-handler registration (idempotent across calls).
//   4. `MLXInferenceLock.shared.run { … }` wraps the inference body:
//        - `ensureModel()` ladder over `ModelManager.visionModelIds`.
//        - Few-shot prompt build (Self.fewShotPrompt(prose:)).
//        - Stream collection → raw string.
//        - `parseAndValidate(raw:)` — JSON decode + cron-validation gate.
//   5. Returns `ProseCadence(prose:, locale:, cron:)`.
//
// ### What does NOT live here yet
//
// - `CompositeProseCadenceCompiler` (rule-first, MLX-fallback) — U.8b-3.
// - CLI wiring (`ScheduleCommand.proseCompilerFactory` swap) — U.8b-4.
// - Real-model integration test — U.8b-5.
//
// ### Test surface
//
// `parseAndValidate(raw:)` is `static`/`public` so the unit suite can
// drive the JSON parse + cron gate without a real model. The locale gate
// and cancellation path are exercised through the public `compile()`
// with `ensureModelCallCountForTesting` exposing the actor's load-attempt
// counter so tests can prove ensureModel was NOT called on rejection.

public actor MLXProseCadenceCompiler: ProseCadenceCompiler {

    /// Loaded VLM container. First call to `ensureModel()` populates;
    /// subsequent calls reuse. Cleared by the unload handler on memory
    /// warning.
    private var modelContainer: ModelContainer?

    /// Loaded model id (e.g. `gemma4-e4b`). Tracked alongside
    /// `modelContainer` for diagnostics.
    private var loadedModelId: String?

    /// One-shot unload-handler registration guard.
    private var unloadHandlerRegistered = false

    /// Test-observability counter — incremented at the top of
    /// `ensureModel()`. Tests assert this stays `0` after a locale-gate
    /// or cancellation rejection.
    private var ensureModelCallCount: Int = 0

    /// Token cap on JSON generation. Cron-JSON is a short envelope
    /// (~10–20 tokens of payload); 128 keeps any Gemma tier under ~1 s.
    private let maxTokens: Int

    public init(maxTokens: Int = 128) {
        self.maxTokens = maxTokens
    }

    /// Drop any loaded VLM. Called by MLXInferenceLock on memory warning.
    func unload() {
        modelContainer = nil
        loadedModelId = nil
    }

    /// Test-only read: how many times `ensureModel()` was entered on
    /// this actor. Stays `0` for any call that hit the cancellation
    /// check or the locale gate before reaching the MLX body.
    public var ensureModelCallCountForTesting: Int { ensureModelCallCount }

    public func compile(
        prose: String,
        locale: String
    ) async throws -> ProseCadence {
        // 1. Cancellation check — earliest cheap rejection. Sits before
        //    the locale gate so a cancelled call throws `.cancelled`
        //    regardless of locale (Kleppmann's ordering — cancel is the
        //    most fundamental rejection, locale is policy).
        do {
            try Task.checkCancellation()
        } catch {
            throw ProseCadenceCompilerError.cancelled
        }

        // 2. Locale gate — English only. Cheap rejection WITHOUT touching
        //    the MLXInferenceLock or attempting a model load. Reuses
        //    `RuleBasedProseCadenceCompiler.isEnglish(_:)` for `en-US` /
        //    `en_US` equivalence.
        guard RuleBasedProseCadenceCompiler.isEnglish(locale) else {
            throw ProseCadenceCompilerError.unsupportedLocale(locale)
        }

        // 3. Lazy unload-handler registration. Idempotent — only fires
        //    on the first compile call. Mirrors
        //    `GemmaInferenceAdapter.ensureModel()`'s lazy pattern,
        //    moved here so the registration is async-context-safe.
        if !unloadHandlerRegistered {
            unloadHandlerRegistered = true
            await MLXInferenceLock.shared.registerUnloadHandler { [weak self] in
                await self?.unload()
            }
        }

        // 4. Serialized inference body. The Gemma adapter pattern: catch
        //    CancellationError + ProseCadenceCompilerError and re-throw;
        //    map other errors to `.invalidJSON` (model surface error).
        do {
            return try await MLXInferenceLock.shared.run {
                let container: ModelContainer
                do {
                    container = try await self.ensureModel()
                } catch is CancellationError {
                    throw ProseCadenceCompilerError.cancelled
                } catch {
                    throw ProseCadenceCompilerError.unavailable
                }

                // Check cancellation once more after the (potentially
                // slow) cold load but before kicking off the generate
                // stream.
                try Task.checkCancellation()

                let userInput = UserInput(
                    prompt: Self.fewShotPrompt(prose: prose),
                    images: []
                )
                let input = try await container.prepare(input: userInput)
                let params = GenerateParameters(maxTokens: self.maxTokens)
                var raw = ""
                let stream = try await container.generate(
                    input: input,
                    parameters: params
                )
                for await generation in stream {
                    switch generation {
                    case .chunk(let text):
                        raw += text
                    case .info, .toolCall:
                        break
                    }
                }

                let validatedCron = try Self.parseAndValidate(raw: raw)
                return ProseCadence(
                    prose: prose,
                    locale: locale,
                    cron: validatedCron
                )
            }
        } catch let e as ProseCadenceCompilerError {
            throw e
        } catch is CancellationError {
            throw ProseCadenceCompilerError.cancelled
        } catch {
            // Model-side or stream-side surface error — surface to the
            // operator as a malformed-response signal (rare; the
            // production stream collection is stable, but the catch is
            // defensive so a thrown error never escapes the closed
            // `ProseCadenceCompilerError` taxonomy).
            throw ProseCadenceCompilerError.invalidJSON(error.localizedDescription)
        }
    }

    // MARK: - JSON parse + cron-validation gate
    //
    // Static so unit tests can exercise this path mock-driven (no actor
    // hop, no model load).

    /// Parse `raw` as `{"cron": "M H DOM MON DOW"}` and re-validate the
    /// cron via `CronToLaunchd.convert(_:)`. The contract:
    ///
    /// - Malformed JSON → `.invalidJSON(raw)`.
    /// - Missing or non-string `cron` field → `.invalidJSON(raw)`.
    /// - Extra fields IGNORED (forward-compatible — the few-shot prompt
    ///   asks for `cron` only, but tolerating `{"cron": "...",
    ///   "explanation": "..."}` lets the prompt evolve without breaking
    ///   the parser).
    /// - Range-form cron (`1-5`) trips the gate — defense-in-depth
    ///   against model drift away from the prompt's comma-list rule.
    public static func parseAndValidate(raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            throw ProseCadenceCompilerError.invalidJSON(raw)
        }
        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ProseCadenceCompilerError.invalidJSON(raw)
        }
        guard let obj = decoded as? [String: Any] else {
            throw ProseCadenceCompilerError.invalidJSON(raw)
        }
        guard let cron = obj["cron"] as? String else {
            throw ProseCadenceCompilerError.invalidJSON(raw)
        }
        let cronTrimmed = cron.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CronToLaunchd.convert(cronTrimmed) != nil else {
            throw ProseCadenceCompilerError.invalidCron(cronTrimmed)
        }
        return cronTrimmed
    }

    // MARK: - Few-shot prompt
    //
    // Verbatim from the parent body's `## Prompt design` section. The 6
    // worked examples cover the rule-based compiler's failure modes
    // (irregular intervals, multi-time-of-day, day-of-month,
    // weekend-only). The CronToLaunchd gate catches any drift toward
    // range form (`1-5`) at runtime — see `parseAndValidate`.

    static func fewShotPrompt(prose: String) -> String {
        return """
        System: You compile English prose schedules to 5-field POSIX cron.
        Return ONLY a JSON object: {"cron": "M H DOM MON DOW"}.
        Use comma-lists (1,2,3,4,5) NOT ranges (1-5).

        Examples:
          "every weekday at 9am"            → {"cron": "0 9 * * 1,2,3,4,5"}
          "every 3 hours"                   → {"cron": "0 */3 * * *"}
          "every other Tuesday at 6pm"      → {"cron": "0 18 * * 2/2"}
          "twice a day on weekdays"         → {"cron": "0 9,17 * * 1,2,3,4,5"}
          "first day of every month"        → {"cron": "0 0 1 * *"}
          "saturdays at noon"               → {"cron": "0 12 * * 6"}

        User: "\(prose)"
        """
    }

    // MARK: - Model loading
    //
    // Mirrors `GemmaInferenceAdapter.ensureModel()` — RAM-tiered ladder
    // over `ModelManager.visionModelIds`. Cached across calls; cleared
    // by the unload handler. Test-observability hook
    // (`ensureModelCallCount`) increments at the top so the unit suite
    // can assert this path was NOT entered after a locale-gate or
    // cancellation rejection.

    private func ensureModel() async throws -> ModelContainer {
        ensureModelCallCount += 1
        if let mc = modelContainer { return mc }

        let mgr = ModelManager.shared
        let ram = ModelManager.availableRAMGB
        let chain: [(modelId: String, repoId: String)] =
            ModelManager.visionModelIds.compactMap { id in
                guard let info = mgr.model(id), info.requiredRAM <= ram else { return nil }
                return (id, info.repoId)
            }

        guard !chain.isEmpty else {
            throw NSError(domain: "senkani.prose", code: 1, userInfo: [
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
                    "senkani.prose: Gemma VLM loaded: \(modelId)\n".utf8))
                return mc
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? NSError(domain: "senkani.prose", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "All Gemma tiers failed to load."])
    }
}
