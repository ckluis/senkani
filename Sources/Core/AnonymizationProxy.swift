import Foundation

/// T.2c-1 — `AnonymizationProxy` ships the headless privacy
/// substrate. `scrubOutbound` replaces detected PII spans with
/// per-engagement surrogates; `rewriteInbound` restores the
/// originals in model output before it surfaces to the operator.
///
/// The proxy is decoupled from the real PII classifier via the
/// `PIISpanEmitter` protocol — tests inject a stub emitter, and
/// T.2c-2 wires the real `PIIClassifierAdapter` once the T.2b
/// backend ships. Decoupling keeps the substrate fully testable
/// without weights.

/// A single PII span detected inside an outbound payload. Named
/// `AnonymizationSpan` to disambiguate from the model-side
/// `PIISpan` in `PIIClassifier.swift` (which uses character-index
/// offsets and a typed `PIICategory`). The proxy carries
/// `Range<String.Index>` because outbound rewrite needs UTF-8-safe
/// `String.replaceSubrange` and a `String` category so the
/// surrogate prefix (`PRIVATE_PERSON_…`) is the emitter's
/// canonical uppercase shape, not the model's lowercase rawValue.
public struct AnonymizationSpan: Sendable, Equatable {
    public let range: Range<String.Index>
    public let category: String
    public let text: String

    public init(range: Range<String.Index>, category: String, text: String) {
        self.range = range
        self.category = category
        self.text = text
    }
}

/// Adapter the proxy uses to discover spans. Conformances:
///   - production (T.2c-2): wraps `PIIClassifierAdapter` once the
///     T.2b inference backend lands and the Layer-3 wiring is
///     bridged into the proxy seam.
///   - tests: stub emitter that returns a pre-baked span list for
///     a known fixture string.
public protocol PIISpanEmitter: Sendable {
    func spans(in text: String, threshold: Double) async throws -> [AnonymizationSpan]
}

/// One surrogate allocation the proxy emitted while scrubbing an
/// outbound payload. Returned to callers so they can wire downstream
/// audit-chain rows (T.2c-2 ships the `surrogate_writes` row writer).
public struct SurrogateAllocation: Sendable, Equatable {
    public let surrogateID: String
    public let category: String
    public let originalValue: String

    public init(surrogateID: String, category: String, originalValue: String) {
        self.surrogateID = surrogateID
        self.category = category
        self.originalValue = originalValue
    }
}

/// Return shape for `scrubOutbound`. `scrubbed` is the rewritten
/// payload safe to hand to a non-local adapter; `surrogates`
/// enumerates the allocations made during this call (first-seen
/// order — reuses do not appear).
public struct ScrubResult: Sendable {
    public let scrubbed: String
    public let surrogates: [SurrogateAllocation]

    public init(scrubbed: String, surrogates: [SurrogateAllocation]) {
        self.scrubbed = scrubbed
        self.surrogates = surrogates
    }
}

/// Sink for one chained `surrogate_writes` row. Production binds this
/// to `SessionDatabase.shared.surrogateWritesStore.record(...)`; tests
/// inject a closure that records into an in-memory buffer.
public typealias SurrogateAuditSink = @Sendable (
    _ engagementID: String,
    _ surrogateID: String,
    _ category: String
) -> Void

public actor AnonymizationProxy {
    private let engagement: EngagementContext
    private let vault: SurrogateVault
    private let emitter: PIISpanEmitter
    private let auditSink: SurrogateAuditSink?

    public init(
        engagement: EngagementContext,
        vault: SurrogateVault,
        emitter: PIISpanEmitter,
        auditSink: SurrogateAuditSink? = nil
    ) {
        self.engagement = engagement
        self.vault = vault
        self.emitter = emitter
        self.auditSink = auditSink
    }

    /// Replace every detected PII span with a per-engagement
    /// surrogate. Spans are emitted in source order; replacements
    /// happen in reverse-index order so earlier ranges stay valid
    /// while later ones are rewritten.
    public func scrubOutbound(_ text: String) async throws -> ScrubResult {
        let spans = try await emitter.spans(
            in: text,
            threshold: engagement.sensitivityThreshold
        )
        guard !spans.isEmpty else {
            return ScrubResult(scrubbed: text, surrogates: [])
        }

        // Source-order pass: allocate (or reuse) surrogate IDs.
        // We track newly-allocated rows separately so reuses don't
        // duplicate the SurrogateAllocation row in the result.
        var perSpanID: [String] = []
        perSpanID.reserveCapacity(spans.count)
        var allocations: [SurrogateAllocation] = []
        var seen: Set<String> = []
        for span in spans {
            let result = try await vault.allocateDetailed(
                originalValue: span.text,
                category: span.category
            )
            perSpanID.append(result.id)
            // T.2c-2: emit one chain row per ALLOCATION (not per reuse).
            // Vault's `isNew` flag is the cross-call truth — reuse within
            // a single scrub call AND reuse across calls both surface as
            // `isNew == false`.
            if result.isNew {
                auditSink?(engagement.id, result.id, span.category)
            }
            // First-time-seen-this-call dedupe for the per-call surrogate
            // list returned to the caller (separate from the audit-chain
            // signal above).
            if seen.insert(result.id).inserted {
                allocations.append(SurrogateAllocation(
                    surrogateID: result.id,
                    category: span.category,
                    originalValue: span.text
                ))
            }
        }

        // Reverse-order replace — keeps earlier indices valid.
        var output = text
        for (span, id) in zip(spans, perSpanID).reversed() {
            output.replaceSubrange(span.range, with: id)
        }
        return ScrubResult(scrubbed: output, surrogates: allocations)
    }

    /// Restore originals for every known surrogate id in `text`.
    /// Uses word-boundary anchored matching so JSON-quoted
    /// (`"PRIVATE_PERSON_001"`) and code-fenced
    /// (`` `PRIVATE_PERSON_001` ``) tokens round-trip safely.
    /// Unknown ids are left alone — never invents an "original."
    ///
    /// T.2c-2: when the engagement is closed (`meta.closed_at` set),
    /// rewrite-back is disabled — the operator sees the literal
    /// surrogates so post-close audit trails preserve the anonymized
    /// view. Per Cavoukian: the operator hand-off boundary makes
    /// surrogates the audit artifact, not originals.
    public func rewriteInbound(_ text: String) async throws -> String {
        if try await vault.isClosed() {
            return text
        }
        let known = await vault.knownSurrogateIDs()
        if known.isEmpty { return text }

        // Sort longest-first so a shorter id never partially matches
        // a longer one (e.g. `_001` substring of `_0011`). Word
        // boundaries make this defensive — surrogate ids are
        // `[A-Z0-9_]` only — but the sort costs nothing.
        let ids = known.keys.sorted { $0.count > $1.count }
        var output = text
        for id in ids {
            guard let original = known[id] else { continue }
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: id))\\b"
            let regex = try NSRegularExpression(pattern: pattern, options: [])
            let ns = output as NSString
            let matches = regex.matches(
                in: output,
                range: NSRange(location: 0, length: ns.length)
            )
            // Reverse-replace so earlier NSRanges remain valid.
            for m in matches.reversed() {
                output = (output as NSString)
                    .replacingCharacters(in: m.range, with: original)
            }
        }
        return output
    }
}
