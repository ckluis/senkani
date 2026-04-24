import Foundation

/// Testable helpers for the Ollama-launcher pane. Lives in Core so it
/// stays decoupled from SwiftUI — the app-target `OllamaLauncherPane`
/// view consumes these.
///
/// Scope boundary (Evans' gate at umbrella time): senkani-internal ML
/// (minilm-l6, gemma4) is a DIFFERENT bounded context managed by
/// `ModelManagerView`. This file is for user-facing Ollama LLMs only —
/// the two contexts share no code.
public enum OllamaLauncherSupport {

    /// Model tags the default-model selector offers. Sourced from
    /// `OllamaModelCatalog.curated` — the single source of truth for the
    /// user-facing LLM list. Order is display order; first entry is the
    /// chooser's default.
    ///
    /// Tags are the exact `ollama pull` / `ollama run` targets.
    public static var defaultModelTags: [String] { OllamaModelCatalog.curatedTags }

    /// The default model the pane launches with when the user hasn't
    /// overridden it. Kept as the first entry in `defaultModelTags` so
    /// the list is single-sourced.
    public static var defaultModelTag: String { defaultModelTags.first ?? "llama3.1:8b" }

    /// Validate that a string is an acceptable ollama model tag for the
    /// pane's launch command. Ollama tags are `name[:tag]` where each
    /// side is a small set of characters. We reject shell metacharacters
    /// defensively so the string can be interpolated into a shell
    /// command without further escaping.
    ///
    /// Returns true for e.g. `llama3.1:8b`, `qwen2.5-coder:7b`,
    /// `codellama`; false for empty, whitespace, or anything with
    /// shell-meaningful characters.
    public static func isValidModelTag(_ tag: String) -> Bool {
        guard !tag.isEmpty, tag.count <= 128 else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.:_-/")
        return tag.allSatisfy { allowed.contains($0) }
    }

    /// Build the shell command the Ollama-launcher pane hands to the
    /// terminal subprocess. Returns `nil` if the tag is invalid so the
    /// caller can surface the error instead of running a malformed
    /// command.
    public static func launchCommand(modelTag: String) -> String? {
        guard isValidModelTag(modelTag) else { return nil }
        return "ollama run \(modelTag)"
    }

    /// Resolve the tag the pane should launch with, falling back to the
    /// package default when the stored value is missing or invalid.
    /// Callers store the user's choice on `PaneModel.ollamaDefaultModel`
    /// and pass it here on pane spawn.
    public static func resolveModelTag(_ stored: String?) -> String {
        if let stored, isValidModelTag(stored) { return stored }
        return defaultModelTag
    }
}

/// Availability probe for the Ollama HTTP API. Extracted from
/// `WelcomeView.detectOllama` so the same check can be reused in the
/// pane's absent-state gate AND is unit-testable against a local
/// fixture server.
public enum OllamaAvailability {

    /// Hit the local Ollama version endpoint with a short timeout.
    /// Returns true iff the API answers 200 within `timeout`.
    /// The default URL matches Ollama's documented local port (11434).
    public static func detect(
        url: URL = URL(string: "http://localhost:11434/api/version")!,
        timeout: TimeInterval = 2.0,
        session: URLSession = .shared
    ) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
