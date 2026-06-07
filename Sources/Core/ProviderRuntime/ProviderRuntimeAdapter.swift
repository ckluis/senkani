import Foundation

/// Phase V.17a-1 — the parser ABI every provider-runtime adapter
/// (Codex CLI v17a-2, Claude Code v17a-3, Gemini CLI v17a-4, OpenCode
/// v17a-5) conforms to.
///
/// **Pure parser contract.** `ingest` translates a chunk of provider-
/// emitted bytes (typically a JSONL line buffer drained from the
/// CLI subprocess stdout) into zero or more `ProviderRuntimeEvent`
/// values. The protocol forbids — by convention, not by language —
/// any network call, any auth probe, any provider-side side-effect.
/// The chain-integrity-and-pivot-regression test in v17a-6 asserts
/// the conformance is observable from the call site (no actor
/// reentry, no executor hop, no Task spawning during parse).
///
/// Adapters are constructed by the V.17b dashboard scaffold once it
/// lands; the spine v17a-1 ships only the protocol + a synthetic
/// stub used by the projection idempotency-replay test.
public protocol ProviderRuntimeAdapter: Sendable {
    /// Stable identifier the adapter writes into every emitted
    /// `ProviderRuntimeEvent.providerID`. Must match the value
    /// downstream queries pivot on (e.g. `"codex"`,
    /// `"claude_code"`, `"gemini"`, `"opencode"`).
    var providerID: String { get }

    /// Translate raw bytes into zero or more events. Idempotent at
    /// the byte-buffer level: feeding the same bytes twice produces
    /// events with identical `rawPayloadHash` values, so the store's
    /// UNIQUE constraint deduplicates on insert.
    ///
    /// Throws when the adapter cannot parse a delimited unit
    /// (typically a malformed JSONL line); partial buffers should
    /// return an empty array and wait for more bytes rather than
    /// throw.
    func ingest(_ raw: Data) async throws -> [ProviderRuntimeEvent]
}
