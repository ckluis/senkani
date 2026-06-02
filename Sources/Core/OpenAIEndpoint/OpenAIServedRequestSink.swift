import Foundation

/// V.13e — the single seam that records one served OpenAI-endpoint request
/// to BOTH observability sinks:
///
///   1. the in-memory `OpenAIAuditChain` (per-process, T.5 tamper-evident,
///      optionally body-storing), and
///   2. the persisted cross-process `openai_request_log` (metadata-only,
///      survives a restart so `senkani doctor` reads real trailing-24h
///      request count + 429-rate).
///
/// **Why this exists.** V.13e-1 landed the persisted store + query API, but
/// NO live request path wrote to it — the serve endpoint only appended to
/// the in-memory chain, so the v13e-2 doctor check rendered `0` requests /
/// `0%` 429-rate regardless of real traffic and the persisted telemetry was
/// permanently empty. This seam is the producer. `ServeCommand`'s chat /
/// embeddings / stream-onFinish closures call it at the exact points that
/// previously called `auditChain.append` directly, so the two sinks stay in
/// lockstep and a single function — not three replicated closures — owns
/// the dual write (and is what the unit test exercises).
///
/// **Best-effort persistence.** A SQLite failure on the persisted write is
/// swallowed: the listener must keep serving even if the audit DB is
/// offline, and a persisted-write failure never affects the in-memory
/// append. The in-memory `append` runs FIRST and has no failure mode.
///
/// **Privacy.** The raw API key is never passed. Both `ts` and `keyLabel`
/// are sourced from the SAME `AuditFields` the in-memory chain stored, so
/// the two sinks can never disagree on either value, and the only label
/// that can reach disk is `fields.keyLabel` — the provisioned key's label,
/// set far upstream by the auth gate. The persisted store has no raw-key
/// column or parameter, so a raw key is structurally unreachable here.
public enum OpenAIServedRequestSink {

    /// Append to the in-memory chain, then best-effort record the persisted
    /// request-log row.
    ///
    /// - Parameters:
    ///   - chain: the per-process in-memory audit chain (appended first).
    ///   - fields: the audit fields the handler produced; `ts` + `keyLabel`
    ///     for the persisted row are taken from here so the two sinks match.
    ///   - bodies: opt-in request/response bodies for the in-memory chain
    ///     (`--audit-bodies`); never persisted to the request log.
    ///   - db: the session database owning `openai_request_log`.
    ///   - surface: which OpenAI surface served the request.
    ///   - httpStatus: the HTTP status code returned to the client. The
    ///     reachable serve paths that append here all return `200` (decode /
    ///     tool-scope errors return before the append; 429 / auth refusals
    ///     are emitted by the gate ahead of the handler). A client-cancelled
    ///     SSE stream is still HTTP `200` — the response head was already
    ///     sent — while the in-memory chain captures the finer `ok`/`cancel`
    ///     distinction in `fields.status`.
    /// - Returns: `true` iff the persisted row landed. The in-memory append
    ///   has no failure mode, so a `false` return means only the persisted
    ///   write failed. Production callers ignore the result; tests assert it.
    @discardableResult
    public static func record(
        chain: OpenAIAuditChain,
        fields: OpenAIAuditChain.AuditFields,
        bodies: OpenAIAuditChain.AuditBodies?,
        db: SessionDatabase,
        surface: OpenAIRequestLogStore.Surface,
        httpStatus: Int
    ) -> Bool {
        // The in-memory tamper-evident chain stores the RAW client-asked
        // model string. The persisted store stores a regex-sanitized copy
        // (or `<malformed>`). Sanitization happens at the single trust
        // boundary — this sink — so every downstream consumer can render
        // the persisted column raw without re-validating. Schneier:
        // sanitize at the trust boundary, not at every consumer.
        chain.append(fields, bodies: bodies)
        let sanitizedModel = sanitize(modelLogged: fields.modelLogged)
        // V.13b prompt-caching B — cache token counts ride INSIDE AuditFields
        // (Lauret P2 — sink positional signature unchanged). Child B always
        // sees these as nil; Child A wires non-nil values from the engine
        // when an opt-in request invokes prompt caching.
        return db.recordOpenAIRequest(
            ts: fields.ts,
            surface: surface,
            status: httpStatus,
            keyLabel: fields.keyLabel,
            modelLogged: sanitizedModel,
            resolvedTier: fields.resolvedTier,
            inputTokens: fields.promptTokenCount,
            outputTokens: fields.completionTokenCount,
            cacheCreationInputTokens: fields.cacheCreationInputTokens,
            cacheReadInputTokens: fields.cacheReadInputTokens
        )
    }

    /// V.13e-7 — producer-side `model_logged` sanitization. The OpenAI
    /// `model` field is attacker-controlled (clients can send arbitrary
    /// bytes). Strings matching `^[A-Za-z0-9._:/-]{1,64}$` persist as
    /// themselves; everything else persists as the literal `<malformed>`.
    /// The in-memory tamper-evident chain still records the raw value
    /// for forensics — this sentinel is for the persisted column only.
    ///
    /// Regex is anchored at both ends so a 65-character or
    /// out-of-character-class string fails the entire match. The
    /// allowed character class — alphanumerics plus `.`, `_`, `:`, `/`,
    /// `-` — covers every model identifier the upstream router
    /// currently emits (e.g. `gpt-4o-mini`, `claude-3-7-sonnet`,
    /// `local/gemma-3-2b-it`, namespaced provider:model tuples).
    static func sanitize(modelLogged: String) -> String {
        // Hand-coded character check is faster than NSRegularExpression
        // on the hot serve path and avoids any locale/dotAll trap.
        guard !modelLogged.isEmpty, modelLogged.utf8.count <= 64 else {
            return "<malformed>"
        }
        for scalar in modelLogged.unicodeScalars {
            switch scalar.value {
            case 0x30...0x39,   // 0-9
                 0x41...0x5A,   // A-Z
                 0x61...0x7A,   // a-z
                 0x2E,          // .
                 0x5F,          // _
                 0x3A,          // :
                 0x2F,          // /
                 0x2D:          // -
                continue
            default:
                return "<malformed>"
            }
        }
        return modelLogged
    }

    /// V.13e — record a gate REFUSAL (401 / 403 / 429) to the persisted
    /// `openai_request_log`. The auth gate emits these responses BEFORE any
    /// surface handler runs, so refused requests never reach `record(...)`
    /// above — this is their single producer site. Without it the persisted
    /// `429-rate` is structurally `0.0%` no matter how much real traffic is
    /// rate-limited (the v13e doctor line reads this store).
    ///
    /// **Deliberate asymmetry with `record`.** Refusals are NOT appended to
    /// the in-memory `OpenAIAuditChain`: that chain is the per-served-request
    /// log (its append sites live inside the surface handlers, downstream of
    /// the gate), while this persisted store is the cross-process
    /// observability log. Touching the chain here would change the v13e-5
    /// burst-integrity test's chain semantics. The persisted write is the
    /// ONLY side effect, and it is best-effort (a SQLite failure must not
    /// break the listener).
    ///
    /// **Key-label policy (privacy + the item's acceptance contract).** The
    /// raw key is never recorded; only the matched record's `label`:
    ///   - `.unauthorized` (401) → `keyLabel: nil` — missing / unknown /
    ///     expired / malformed: no label is attributed. An expired key still
    ///     records nil so the log never leaks which labelled key expired.
    ///   - `.forbidden` (403) → the matched key's label (a 403 always matched
    ///     an in-vault record; the refusal is a scope miss, not identity).
    ///   - `.rateLimited` (429) → the matched key's label (a 429 is a per-key
    ///     limit, so a record always matched).
    ///   - `.ok` → no-op (the surface handler records the admit, with its
    ///     precise surface, via `record(...)`).
    ///
    /// **Surface.** Derived from the request path via
    /// `OpenAIAuthGate.surface(forPath:)` — `/v1/chat*` → `.chat`,
    /// `/v1/embeddings` → `.embeddings`. A `/v1/*` path with no specific
    /// surface (e.g. `/v1/models`, the bare `/v1`) records under `.other`,
    /// preserving honest per-surface attribution in
    /// `recentOpenAIRequests` reads and keeping the recon-signal class
    /// (an unauthenticated probe of `/v1/models` etc.) sliceable instead
    /// of disguised as chat traffic. The doctor `429-rate` is
    /// surface-agnostic (`status = 429` across ALL rows) and unaffected
    /// regardless of which bucket carries a surface-less refusal.
    ///
    /// `decide(...)` runs exactly once per `/v1/*` request, so calling this
    /// once with that decision yields exactly one row per refused request —
    /// no double-count across retry frames or connection events.
    ///
    /// - Returns: `true` iff a row landed; `false` for an `.ok` decision or a
    ///   best-effort persisted-write failure. Production ignores the result;
    ///   the unit test asserts it.
    @discardableResult
    public static func recordRefusal(
        decision: OpenAIAuthGate.Decision,
        path: String,
        authorizationHeader: String?,
        records: [OpenAIKeyRecord],
        db: SessionDatabase,
        now: Date = Date()
    ) -> Bool {
        let status: Int
        let keyLabel: String?
        switch decision {
        case .ok:
            return false
        case .unauthorized:
            status = 401
            keyLabel = nil
        case .forbidden:
            status = 403
            keyLabel = matchedLabel(authorizationHeader: authorizationHeader, records: records)
        case .rateLimited:
            status = 429
            keyLabel = matchedLabel(authorizationHeader: authorizationHeader, records: records)
        }
        let surface: OpenAIRequestLogStore.Surface
        switch OpenAIAuthGate.surface(forPath: path) {
        case "embeddings": surface = .embeddings
        case "chat":       surface = .chat
        default:           surface = .other   // nil / unrecognized paths (e.g. /v1/models)
        }
        // V.13e-7 — refusals fire BEFORE any surface handler routes, so
        // there's no resolved tier, no token counts, and no client-asked
        // model worth persisting raw. `<refused>` is the literal sentinel
        // for `model_logged` (length-bounded, character-bounded, parses
        // as text not as a real model id); the other three columns
        // persist NULL.
        return db.recordOpenAIRequest(
            ts: now, surface: surface, status: status, keyLabel: keyLabel,
            modelLogged: "<refused>", resolvedTier: nil,
            inputTokens: nil, outputTokens: nil
        )
    }

    /// Re-derive the matched key's label from the presented bearer token, or
    /// nil when no token is present / no record matched. Mirrors the re-match
    /// idiom the surface handlers use to fetch the record's label after the
    /// gate has admitted the request. Never returns the raw key.
    private static func matchedLabel(
        authorizationHeader: String?,
        records: [OpenAIKeyRecord]
    ) -> String? {
        guard let token = OpenAIAuthGate.bearerToken(fromHeader: authorizationHeader) else {
            return nil
        }
        return OpenAIAuthGate.matchRecord(presentedKey: token, records: records)?.label
    }
}
