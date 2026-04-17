import Foundation

// MARK: - RationaleLLM
//
// Phase H+2a: narrow protocol for rewriting a compound-learning rule's
// deterministic rationale into a natural-language enrichment.
//
// The protocol lives in Core so `GemmaRationaleRewriter` can compose
// with any LLM backend without importing MLX (which would pull Tree-sitter
// + vision-model machinery into every Core client). Production wires an
// MLX-backed adapter in MCPServer; unit tests wire a `MockRationaleLLM`.
//
// Contract:
//   - `rewrite(prompt:)` accepts a prompt string ≤ `maxPromptBytes` and
//     returns an answer string. Callers are responsible for the prompt
//     cap — the protocol does not enforce it (keeps adapters stateless).
//   - Errors on the model side (model missing, inference failure, cancelled)
//     propagate as thrown errors. The rewriter catches any error and
//     falls back to a `nil` enrichment so compound learning never breaks
//     because of a flaky or absent model.
//   - Adapters may take arbitrarily long; rewriter-side timeout is the
//     caller's job.

public protocol RationaleLLM: Sendable {
    /// Generate a natural-language rewrite of `prompt`. May throw.
    func rewrite(prompt: String) async throws -> String
}

// MARK: - NullRationaleLLM
//
// Default wiring when no MLX adapter is available. Every call throws
// `RationaleLLMError.unavailable` so the rewriter's silent-fallback path
// fires. This is what runs in Phase H+2a deployments where the user
// hasn't downloaded a Gemma model yet.

public struct NullRationaleLLM: RationaleLLM {
    public init() {}

    public func rewrite(prompt: String) async throws -> String {
        throw RationaleLLMError.unavailable
    }
}

// MARK: - Errors

public enum RationaleLLMError: Error, Equatable, Sendable {
    /// No backend is configured or the model isn't downloaded.
    case unavailable
    /// The backend returned an empty string.
    case emptyResponse
    /// The backend returned something unusable (non-utf8, malformed).
    case invalidResponse(String)
    /// The inference timed out or was cancelled.
    case cancelled
}
