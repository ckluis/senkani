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
        chain.append(fields, bodies: bodies)
        return db.recordOpenAIRequest(
            ts: fields.ts,
            surface: surface,
            status: httpStatus,
            keyLabel: fields.keyLabel
        )
    }
}
