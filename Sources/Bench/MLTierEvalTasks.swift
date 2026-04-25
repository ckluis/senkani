import Foundation

// MARK: - Categories

public enum MLTierEvalCategory: String, Codable, Sendable {
    case vision
    case rationale
}

// MARK: - Task

/// One eval task. Pure data — the runner supplies inference.
///
/// Pass criterion: a case-insensitive substring match on `expectedAnyOf`.
/// At least one of the strings must appear in the model's response.
public struct MLTierEvalTask: Sendable, Identifiable, Codable {
    public let id: String
    public let category: MLTierEvalCategory
    public let prompt: String
    /// Stable filename ID of the fixture image (without the `.png`
    /// extension), when category == .vision. Resolved at runtime via
    /// `imageURL` against `Sources/Bench/Resources/MLEvalImages/<imageRef>.png`,
    /// shipped through SwiftPM's `Bundle.module`.
    public let imageRef: String?
    /// One-of substring match; case-insensitive. A response that contains
    /// any string in this list passes.
    public let expectedAnyOf: [String]

    public init(
        id: String,
        category: MLTierEvalCategory,
        prompt: String,
        imageRef: String? = nil,
        expectedAnyOf: [String]
    ) {
        self.id = id
        self.category = category
        self.prompt = prompt
        self.imageRef = imageRef
        self.expectedAnyOf = expectedAnyOf
    }

    public func passes(response: String) -> Bool {
        let lower = response.lowercased()
        return expectedAnyOf.contains { !$0.isEmpty && lower.contains($0.lowercased()) }
    }

    /// Resolve `imageRef` to a real PNG `URL` shipped via SwiftPM resources.
    ///
    /// Returns `nil` for tasks without an `imageRef` (i.e. rationale tasks)
    /// or when the bundle does not contain a matching `<imageRef>.png`.
    /// The Bench target's `Sources/Bench/Resources/MLEvalImages/` directory
    /// is shipped as a `.copy` resource so every fixture lives under
    /// `Bundle.module`.
    public var imageURL: URL? {
        guard let ref = imageRef else { return nil }
        return Bundle.module.url(
            forResource: ref,
            withExtension: "png",
            subdirectory: "MLEvalImages"
        )
    }
}

// MARK: - Fixture set

public enum MLTierEvalTasks {

    public static func all() -> [MLTierEvalTask] {
        return rationaleTasks() + visionTasks()
    }

    /// Ten rationale tasks — text in, text out. Probe the same kinds of
    /// reasoning the rationale rewriter uses in production: terseness,
    /// causal reasoning, terminology recognition, structured output.
    public static func rationaleTasks() -> [MLTierEvalTask] {
        return [
            .init(
                id: "rationale_filter_purpose",
                category: .rationale,
                prompt: "In one sentence: why does Senkani filter 'git clone' progress lines from terminal output?",
                expectedAnyOf: ["progress", "noise", "token", "save", "redundant", "verbose"]
            ),
            .init(
                id: "rationale_secret_redaction",
                category: .rationale,
                prompt: "In one sentence: why redact API keys (e.g. 'sk-ant-…') from terminal output before sending to a model?",
                expectedAnyOf: ["leak", "secret", "secur", "expose", "credential", "privacy"]
            ),
            .init(
                id: "rationale_cache_hit",
                category: .rationale,
                prompt: "What is a 'cache hit' in the context of an LLM agent re-running the same shell command?",
                expectedAnyOf: ["reuse", "stored", "previous", "skip", "saved", "cached"]
            ),
            .init(
                id: "rationale_indexer_role",
                category: .rationale,
                prompt: "Briefly: what role does a code indexer play when an agent searches a 1000-file repository?",
                expectedAnyOf: ["search", "find", "locate", "lookup", "symbol", "fast", "skip"]
            ),
            .init(
                id: "rationale_terse_mode",
                category: .rationale,
                prompt: "What does 'terse mode' do to model output, and why does it save tokens?",
                expectedAnyOf: ["short", "concise", "fewer", "less", "brief", "reduce"]
            ),
            .init(
                id: "rationale_routing_local",
                category: .rationale,
                prompt: "Why route a 'list files' command to a local on-device model instead of a frontier cloud model?",
                expectedAnyOf: ["cheap", "free", "cost", "simple", "trivial", "local", "offline", "privacy"]
            ),
            .init(
                id: "rationale_filter_npm",
                category: .rationale,
                prompt: "Suggest one filter rule that reduces 'npm install' output without losing useful signal.",
                expectedAnyOf: ["warn", "added", "audit", "progress", "fund", "deprecat"]
            ),
            .init(
                id: "rationale_oom_recovery",
                category: .rationale,
                prompt: "If Gemma 4 fails to load due to low free RAM, what should the system do?",
                expectedAnyOf: ["fallback", "smaller", "tier", "step down", "lower", "retry", "reduce"]
            ),
            .init(
                id: "rationale_sandbox_purpose",
                category: .rationale,
                prompt: "Why sandbox a shell command before letting an agent execute it?",
                expectedAnyOf: ["safe", "isolat", "prevent", "limit", "destruct", "harm", "secur"]
            ),
            .init(
                id: "rationale_filter_vs_summarize",
                category: .rationale,
                prompt: "When is deterministic filtering preferable to LLM summarization for compressing terminal output?",
                expectedAnyOf: ["determin", "fast", "cheap", "predict", "reliab", "regex", "rule"]
            ),
        ]
    }

    /// Ten vision tasks. Each references an image fixture by stable
    /// filename ID; the PNGs ship under
    /// `Sources/Bench/Resources/MLEvalImages/<imageRef>.png` and are
    /// rendered from `tools/render-ml-eval-fixtures.py`. Resolve at
    /// runtime via `MLTierEvalTask.imageURL`. In CI the tests cover task
    /// structure + fixture presence, not inference.
    public static func visionTasks() -> [MLTierEvalTask] {
        return [
            .init(
                id: "vision_terminal_error",
                category: .vision,
                prompt: "What error does this terminal screenshot show?",
                imageRef: "vision_terminal_error",
                expectedAnyOf: ["error", "fail", "exception", "not found", "missing", "denied"]
            ),
            .init(
                id: "vision_diff_summary",
                category: .vision,
                prompt: "Summarize what the unified diff in this image changes.",
                imageRef: "vision_diff_summary",
                expectedAnyOf: ["add", "remov", "chang", "rename", "modif", "delet", "insert"]
            ),
            .init(
                id: "vision_swift_signature",
                category: .vision,
                prompt: "What is the function signature visible in this code screenshot?",
                imageRef: "vision_swift_signature",
                expectedAnyOf: ["func", "->", "(", ")", "throws", "async"]
            ),
            .init(
                id: "vision_chart_axes",
                category: .vision,
                prompt: "What do the X and Y axes of this chart represent?",
                imageRef: "vision_chart_axes",
                expectedAnyOf: ["axis", "axes", "x", "y", "time", "count", "tokens", "latency"]
            ),
            .init(
                id: "vision_test_fail",
                category: .vision,
                prompt: "Which test failed and what is the assertion message?",
                imageRef: "vision_test_fail",
                expectedAnyOf: ["fail", "expected", "got", "assert", "test"]
            ),
            .init(
                id: "vision_warn_count",
                category: .vision,
                prompt: "How many warnings appear in the build log shown in this image?",
                imageRef: "vision_warn_count",
                expectedAnyOf: ["warning", "warn", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
            ),
            .init(
                id: "vision_ui_button",
                category: .vision,
                prompt: "What is the label on the primary button in this UI mockup?",
                imageRef: "vision_ui_button",
                expectedAnyOf: ["button", "click", "submit", "save", "cancel", "ok", "next", "label"]
            ),
            .init(
                id: "vision_panes_count",
                category: .vision,
                prompt: "How many terminal panes are visible in this Senkani window?",
                imageRef: "vision_panes_count",
                expectedAnyOf: ["pane", "panel", "window", "1", "2", "3", "4", "split"]
            ),
            .init(
                id: "vision_stack_trace",
                category: .vision,
                prompt: "What is the top frame of the stack trace in this crash report?",
                imageRef: "vision_stack_trace",
                expectedAnyOf: ["stack", "trace", "frame", "thread", "crash", "abort"]
            ),
            .init(
                id: "vision_progress_bar",
                category: .vision,
                prompt: "What percentage complete is the download progress bar in this screenshot?",
                imageRef: "vision_progress_bar",
                expectedAnyOf: ["%", "percent", "progress", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
            ),
        ]
    }
}
