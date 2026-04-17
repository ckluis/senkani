import Foundation

// MARK: - GemmaRationaleRewriter
//
// Phase H+2a: takes a `LearnedFilterRule` (Phase K, v2/v3) and asks a
// `RationaleLLM` to produce a natural-language enrichment of the
// deterministic `rationale` string. The enrichment is *additive* — the
// deterministic rationale remains the canonical record and a fallback
// for every reader. Enrichment is NEVER injected into FilterPipeline,
// the gate, or any decision-making path. It lives in a dedicated
// `enrichedRationale: String?` field surfaced only in the CLI.
//
// Safety (Schneier):
//   - Prompt caps input at `maxPromptBytes` (default 2 KB) so a rule
//     with a pathological ops list can't OOM the model.
//   - Output passes through `SecretDetector.scan` before the adapter's
//     return value lands back in LearnedRulesStore. The same pattern
//     `senkani_bundle` uses for embedded free-text.
//   - Output capped at `maxOutputChars` (default 500) — this is human-
//     facing CLI text, not machine-consumed.
//   - Any adapter error (unavailable, empty, cancelled, unknown) returns
//     `nil`. Caller does not retry; orchestrator logs to event_counters
//     and moves on. Compound learning NEVER breaks because a model
//     failed.
//
// Determinism:
//   - Not deterministic — LLM output varies. Do NOT call from code paths
//     that demand reproducibility (golden tests, bundle composition,
//     benchmark baselines). Safe call sites: CLI surface, async post-
//     stage enrichment.

public struct GemmaRationaleRewriter: Sendable {
    public let llm: RationaleLLM
    public let maxPromptBytes: Int
    public let maxOutputChars: Int

    public init(
        llm: RationaleLLM,
        maxPromptBytes: Int = 2048,
        maxOutputChars: Int = 500
    ) {
        self.llm = llm
        self.maxPromptBytes = maxPromptBytes
        self.maxOutputChars = maxOutputChars
    }

    /// Enrich `rule.rationale` into a natural-language form.
    /// Returns `nil` on any failure — caller falls back to deterministic rationale.
    public func enrich(_ rule: LearnedFilterRule) async -> String? {
        let prompt = buildPrompt(for: rule)
        do {
            let raw = try await llm.rewrite(prompt: prompt)
            return sanitize(raw)
        } catch {
            return nil
        }
    }

    /// Construct the prompt. Deterministic given the rule — so two
    /// calls on the same rule hit the same model input, even if the
    /// output varies.
    func buildPrompt(for rule: LearnedFilterRule) -> String {
        let subPart = rule.subcommand.map { "/\($0)" } ?? ""
        let opsStr = rule.ops.joined(separator: ", ")
        let deterministic = rule.rationale.isEmpty ? "(no deterministic rationale)" : rule.rationale
        let raw = """
        You rewrite machine-generated filter-rule rationales in one short sentence for a developer CLI. \
        The rule proposes to filter shell command output. Explain WHY in natural English — what \
        noise does this rule strip, and why is that worth doing?

        Command: \(rule.command)\(subPart)
        Filter ops: \(opsStr)
        Confidence: \(String(format: "%.2f", rule.confidence))
        Sessions observed: \(rule.sessionCount)
        Deterministic rationale: \(deterministic)

        Reply with one sentence, 15–30 words, addressed to the developer. No preamble, no quotes, no lists.
        """
        if raw.utf8.count <= maxPromptBytes { return raw }
        // Cap — truncate the deterministic-rationale block first since
        // command/ops/counts are load-bearing.
        let trimmedDeterministic = String(deterministic.prefix(200))
        let capped = """
        You rewrite machine-generated filter-rule rationales in one short sentence for a developer CLI. \
        Command: \(rule.command)\(subPart)
        Filter ops: \(opsStr)
        Confidence: \(String(format: "%.2f", rule.confidence))
        Sessions observed: \(rule.sessionCount)
        Deterministic rationale: \(trimmedDeterministic)
        Reply with one sentence, 15–30 words. No preamble.
        """
        return String(capped.prefix(maxPromptBytes))
    }

    /// Strip secrets, trim whitespace, cap length. Returns nil if the
    /// LLM emitted only whitespace or only a redaction marker (no
    /// information to surface).
    func sanitize(_ raw: String) -> String? {
        let scanned = SecretDetector.scan(raw).redacted
        let trimmed = scanned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // If everything was redacted into one big marker, don't surface it —
        // the deterministic rationale is strictly better.
        if trimmed == "[REDACTED]" || trimmed.allSatisfy({ $0 == "*" }) { return nil }
        // Single-line for CLI rendering.
        let flat = trimmed
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let collapsed = flat.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let capped = String(collapsed.prefix(maxOutputChars))
        return capped.isEmpty ? nil : capped
    }
}
