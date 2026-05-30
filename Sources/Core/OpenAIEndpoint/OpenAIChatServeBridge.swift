import Foundation

/// V.13 real-chat — bridge between `ChatEngine` (async, registered by the
/// MCP target) and `OpenAIChatHandler.Engine` (sync, consumed inside the
/// `NWListener`'s synchronous response closure). Mirrors
/// `OpenAIEmbeddingsServeBridge.syncEngine` 1:1.
///
/// Why a sync bridge: the listener closure is `(Data) -> Data?` and runs
/// on the listener's dispatch queue; making it async would require
/// refactoring the listener. MLX inference is already gated by
/// `MLXInferenceLock.shared` (serial across the process), so blocking the
/// listener thread on the inference task is the same wait the lock
/// already imposes.
public enum OpenAIChatServeBridge {

    /// Wrap a registered `ChatEngine` as a sync
    /// `OpenAIChatHandler.Engine`. Uses a `DispatchSemaphore` to bridge
    /// the async chat call — the listener thread waits while the MLX
    /// task runs under `MLXInferenceLock.shared`. On thrown error,
    /// returns an empty completion so the caller can decide how to
    /// render (the production caller — `ServeCommand` — will gate on
    /// `ModelManager.isReady` upstream once sub-item 3 lands; until
    /// then this matches v13c's pre-readiness-gate semantics).
    public static func syncEngine(for handler: any ChatEngine) -> OpenAIChatHandler.Engine {
        OpenAIChatHandler.Engine { model, messages, tools in
            let semaphore = DispatchSemaphore(value: 0)
            // Use a class wrapper so the inner Task can store the result
            // and signal even though closures are non-escaping-by-default.
            final class Box: @unchecked Sendable {
                var value: OpenAIChatHandler.Completion?
            }
            let box = Box()
            Task {
                box.value = try? await handler.chat(
                    model: model,
                    messages: messages,
                    tools: tools
                )
                semaphore.signal()
            }
            semaphore.wait()
            return box.value ?? OpenAIChatHandler.Completion(
                content: "",
                promptTokens: 0,
                completionTokens: 0
            )
        }
    }
}
