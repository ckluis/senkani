import Foundation

/// V.13b-2 — Anthropic `/v1/messages` (non-stream) chat client conforming
/// to the `ChatEngine` seam. Hand-rolled URLSession POST; no third-party
/// SDK. Server-side accept-list, senkani-shortname → Anthropic-API-ID
/// translation, and Anthropic↔OpenAI shape mapping live here.
///
/// Scope carves (parent v13b-2 spec):
///   - Retry / backoff / 429+529 rate-limit translation → V.13b-2b, landed
///     HERE: bounded backoff honoring `Retry-After`, exhaustion surfaced as
///     `.rateLimited(retryAfter:)` + the `openAIRateLimitResponse` renderer.
///   - EgressProxy routing (allowlist / connectionProxyDictionary /
///     direct-HTTPS-bypass) → b-4. Today's calls egress directly.
///   - Streaming `/v1/messages` (`stream:true`) → later sub-item.
///
/// Retry safety (V.13b-2b): only `429` (rate limit) and `529` (overloaded)
/// are retried — both signal the upstream did NOT process the request, so
/// retrying a non-idempotent billable POST is safe. `500/502/503` and 4xx
/// are NOT retried (ambiguous side-effect state; no idempotency key). The
/// backoff `await`s in-band; `RetryPolicy.default`'s 30s ceiling bounds the
/// CUMULATIVE BACKOFF SLEEP (the parent spec's "max 30s total" budget) —
/// NOT end-to-end wall-clock: the per-attempt upstream round-trips are
/// additional and are bounded only by the URLRequest/URLSession timeout,
/// which the serve consumer (b-4) MUST set as a real per-request deadline.
/// `OpenAIChatServeBridge` calls chat() SYNCHRONOUSLY via
/// `ServeBridge.runBlocking` on the listener thread, so b-4 MUST also
/// inject `RetryPolicy.serveSafe` (8s) AND run this off the listener thread
/// — otherwise one rate-limited request head-of-line-blocks every other
/// chat request. See the b-4 blocking note.
///
/// Info-leak guard (Schneier): on Anthropic non-200, only the HTTP status
/// + the Anthropic `error.type` short identifier surface. The raw body —
/// which can echo prompt content or upstream guidance — is discarded.
/// On URLSession failure the thrown error carries only `URLError.Code`'s
/// raw value, never `String(describing: error)`, so undocumented userInfo
/// fields can't smuggle headers (including `x-api-key`) into logs.

/// V.13b-2 — accept-list of senkani-side model shortnames the engine will
/// route to Anthropic. These match `ModelTier.claudeModelValue` and are
/// what `OpenAIChatHandler.route` produces. The wire IDs sent to Anthropic
/// are translated via `ClaudeAPIChatEngine.wireModelID(for:)`.
public enum ClaudeAPIChatEngine_AcceptList {
    public static let models: Set<String> = ["claude-haiku-3.5", "claude-sonnet-4", "claude-opus-4"]
}

public enum ClaudeAPIChatEngineError: Error, Sendable, Equatable {
    /// The caller-supplied model is not in the senkani accept-list. No
    /// upstream HTTP call is made before this throws — so DNS/connect-side
    /// channels can't leak attacker-controlled model strings.
    case upstreamModelUnavailable(model: String)
    /// URLSession failed. Carries only `URLError.Code`'s raw value (a small
    /// integer) so undocumented userInfo can't smuggle headers into logs.
    case networkError(code: Int)
    /// The 200 response body could not be decoded as Anthropic Messages
    /// shape. Reason is a short fixed identifier; never raw bytes. Also
    /// surfaced as a LOCAL validation error before any wire egress (e.g.
    /// `role:"tool"` follow-up without a `tool_call_id`) so the caller
    /// sees the parse failure point clearly rather than an opaque
    /// upstream 400.
    case decodeError(reason: String)
    /// Anthropic returned a non-200. `type` is the short identifier from
    /// `error.type` if parseable (`authentication_error`,
    /// `overloaded_error`, `invalid_request_error`, …); nil when the body
    /// is missing, non-JSON, or malformed. The body itself is discarded.
    case upstreamError(status: Int, type: String?)
    /// V.13b-2b — bounded retry of `429`/`529` was exhausted (retry count
    /// or total-wait budget). `retryAfter` is the VALIDATED upstream
    /// `Retry-After` delta-seconds from the last rate-limit response
    /// (non-negative integer; nil when absent/unparseable). Carries only a
    /// small integer — no upstream body, so `String(describing:)` cannot
    /// echo prompt/guidance content (same info-leak guard as
    /// `upstreamError`). Render to the OpenAI wire shape via
    /// `ClaudeAPIChatEngine.openAIRateLimitResponse(retryAfter:)`.
    case rateLimited(retryAfter: Int?)
}

public final class ClaudeAPIChatEngine: ChatEngine {

    /// V.13b prompt-caching A — pinned beta header value.
    ///
    /// Anthropic gates prompt-caching behind a per-request beta header. We
    /// pin the exact token here so:
    ///   (a) the request-builder rule "header IFF body carries
    ///       cache_control" lives in ONE place,
    ///   (b) grep for `prompt-caching` finds every emission site when
    ///       Anthropic GA's the feature and retires this beta token, and
    ///   (c) a future-day operator can audit "is senkani still on the beta
    ///       header?" with one `git grep`.
    ///
    /// TODO(prompt-caching-GA): when Anthropic moves prompt caching out of
    /// beta, remove this constant + the header emission AND drop the
    /// once-per-process deprecation warning.
    ///
    /// Reference: https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching
    public static let promptCachingBetaHeader = "prompt-caching-2024-07-31"

    /// V.13b prompt-caching A — Schneier P2: once-per-process-lifetime
    /// stderr warning when the opt-in flag is set but the upstream response
    /// carries NEITHER `cache_creation_input_tokens` NOR
    /// `cache_read_input_tokens`. Defensive signal that the beta header may
    /// have been deprecated / rejected by Anthropic. Capped to once per
    /// process so log spam is bounded. Lock-guarded via the static `nslock`
    /// so concurrent first-warning races resolve to a single emission.
    nonisolated(unsafe) private static var hasWarnedAboutCacheTokenAbsence: Bool = false
    private static let cacheTokenWarningLock = NSLock()

    /// Fire the once-per-process cache-token-absence warning. Called from
    /// the response-decode path when opt-in was requested but the upstream
    /// response is missing both `cache_*_input_tokens` fields.
    static func warnAboutMissingCacheTokensOnceIfNeeded() {
        cacheTokenWarningLock.lock()
        let alreadyWarned = hasWarnedAboutCacheTokenAbsence
        if !alreadyWarned { hasWarnedAboutCacheTokenAbsence = true }
        cacheTokenWarningLock.unlock()
        if alreadyWarned { return }
        FileHandle.standardError.write(Data(
            "warning: prompt-caching beta header may be deprecated — response carried no cache_* usage fields\n".utf8
        ))
    }

    /// TEST-ONLY — reset the once-per-process warning flag. Production code
    /// MUST NOT call this; it exists so tests can drive the
    /// "fire the warning" branch deterministically.
    static func resetCacheTokenAbsenceWarningForTesting() {
        cacheTokenWarningLock.lock()
        hasWarnedAboutCacheTokenAbsence = false
        cacheTokenWarningLock.unlock()
    }

    /// TEST-ONLY — observe the warning flag state. Production code MUST
    /// NOT call this.
    static func hasWarnedAboutCacheTokenAbsenceForTesting() -> Bool {
        cacheTokenWarningLock.lock()
        let v = hasWarnedAboutCacheTokenAbsence
        cacheTokenWarningLock.unlock()
        return v
    }

    /// V.13b-4c follow-up — Schneier P2 silent-opt-in-drop notice
    /// (once-per-process). Fires when the operator requests
    /// `cacheControl == .ephemeral` but supplies NO system message —
    /// caching is a no-op for the request (the typed-block system field is
    /// omitted entirely on the wire), so the opt-in is silently dropped.
    /// Separate flag from the beta-deprecation warning; lock-guarded so
    /// concurrent first-emission races resolve to a single stderr line.
    nonisolated(unsafe) private static var hasWarnedAboutSilentOptInDrop: Bool = false
    private static let silentOptInDropWarningLock = NSLock()

    /// Fire the once-per-process silent-opt-in-drop notice. Called from
    /// `buildSystemField` at the `(.ephemeral, .none)` arm before the nil
    /// return (no system content → nothing to cache).
    static func warnAboutSilentOptInDropOnceIfNeeded() {
        silentOptInDropWarningLock.lock()
        let alreadyWarned = hasWarnedAboutSilentOptInDrop
        if !alreadyWarned { hasWarnedAboutSilentOptInDrop = true }
        silentOptInDropWarningLock.unlock()
        if alreadyWarned { return }
        FileHandle.standardError.write(Data(
            "warning: cacheControl: .ephemeral requested but no system message — caching is a no-op for this request\n".utf8
        ))
    }

    /// TEST-ONLY — reset the silent-opt-in-drop warning flag. Production
    /// code MUST NOT call this.
    static func resetSilentOptInDropWarningForTesting() {
        silentOptInDropWarningLock.lock()
        hasWarnedAboutSilentOptInDrop = false
        silentOptInDropWarningLock.unlock()
    }

    /// TEST-ONLY — observe the silent-opt-in-drop warning flag state.
    /// Production code MUST NOT call this.
    static func hasWarnedAboutSilentOptInDropForTesting() -> Bool {
        silentOptInDropWarningLock.lock()
        let v = hasWarnedAboutSilentOptInDrop
        silentOptInDropWarningLock.unlock()
        return v
    }

    /// V.13b-2b — bounded-backoff policy for `429`/`529` retries.
    /// `maxRetries` retries follow the initial attempt (so up to
    /// `maxRetries + 1` total upstream requests). `maxTotalWait` caps the
    /// CUMULATIVE backoff sleep (sum of per-attempt delays); when the next
    /// delay would push the accumulated sleep past it, the delay is clamped
    /// and the budget exhausts. `baseDelay` is the exponential base for the
    /// no-`Retry-After` path (`baseDelay * 2^attempt`, full-jittered).
    public struct RetryPolicy: Sendable {
        public let maxRetries: Int
        public let maxTotalWait: Duration
        public let baseDelay: Duration
        public init(maxRetries: Int, maxTotalWait: Duration, baseDelay: Duration) {
            self.maxRetries = maxRetries
            self.maxTotalWait = maxTotalWait
            self.baseDelay = baseDelay
        }
        /// Spec default (parent v13b-2b acceptance): max 3 retries, max 30s
        /// total wall-clock. Suitable for the DIRECT/CLI caller.
        public static let `default` = RetryPolicy(maxRetries: 3, maxTotalWait: .seconds(30), baseDelay: .seconds(1))
        /// Serve-path preset (b-4): tighter 8s ceiling so a rate-limited
        /// upstream can't park the synchronous listener thread for 30s.
        /// b-4 MUST also run chat() off the listener thread.
        public static let serveSafe = RetryPolicy(maxRetries: 3, maxTotalWait: .seconds(8), baseDelay: .seconds(1))
    }

    private let apiKey: String
    private let session: URLSession
    private let endpoint: URL
    private let anthropicVersion: String
    /// Cap on `max_tokens` sent to Anthropic. 4096 is high enough that
    /// realistic chat completions don't truncate; if Anthropic returns
    /// `stop_reason: "max_tokens"` we APPEND a visible `[truncated:
    /// max_tokens reached]` sentinel to the returned content so the caller
    /// sees truncation in the response text (the `Completion` shape has no
    /// `finish_reason` field — `OpenAIChatHandler.handle` derives it
    /// itself from `toolCalls.isEmpty`, so a structural channel would mean
    /// a wider refactor; see follow-up filing).
    private let maxTokens: Int
    /// V.13b-2b — retry/backoff policy for rate-limit responses.
    private let retryPolicy: RetryPolicy
    /// V.13b-2b — backoff sleeper seam. Defaults to `Task.sleep(for:)`;
    /// TEST-ONLY override so suites inject a recording no-op (instant, and
    /// asserts the sleep count + summed wait). Production callers must NOT
    /// override this. Propagates `CancellationError` like `Task.sleep`.
    private let sleeper: @Sendable (Duration) async throws -> Void
    /// V.13b-4a — per-request wall-clock deadline applied to EACH upstream
    /// attempt's `URLRequest.timeoutInterval`. `retryPolicy.maxTotalWait`
    /// bounds only the backoff SLEEP between attempts — NOT a per-attempt
    /// round-trip — so the serve consumer (b-4c) sets this to keep a slow /
    /// hung upstream from parking the listener thread past a real deadline.
    /// nil = URLSession's default (60s).
    private let requestTimeout: TimeInterval?

    public init(
        apiKey: String,
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        anthropicVersion: String = "2023-06-01",
        maxTokens: Int = 4096,
        retryPolicy: RetryPolicy = .default,
        sleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        requestTimeout: TimeInterval? = nil
    ) {
        self.apiKey = apiKey
        self.session = session
        self.endpoint = endpoint
        self.anthropicVersion = anthropicVersion
        self.maxTokens = maxTokens
        self.retryPolicy = retryPolicy
        self.sleeper = sleeper
        self.requestTimeout = requestTimeout
    }

    public func chat(
        model: String,
        messages: [ChatCompletionRequest.Message],
        tools: [ChatCompletionRequest.Tool]
    ) async throws -> OpenAIChatHandler.Completion {
        try await chat(model: model, messages: messages, tools: tools, cacheControl: nil)
    }

    /// V.13b prompt-caching A — extended `chat(...)` that takes the
    /// `ChatCompletionRequest.cacheControl` opt-in flag. The protocol
    /// `chat(model:messages:tools:)` above delegates here with `nil`. The
    /// serve-side dispatcher passes through `request.cacheControl` so the
    /// Anthropic arm honors the operator's opt-in. Engines that don't
    /// model caching (MLX, OpenAI proxy) ignore the field by never being
    /// called through this path.
    public func chat(
        model: String,
        messages: [ChatCompletionRequest.Message],
        tools: [ChatCompletionRequest.Tool],
        cacheControl: CacheControlMode?
    ) async throws -> OpenAIChatHandler.Completion {
        // 1. Accept-list gate BEFORE any I/O. No DNS, no connect.
        guard ClaudeAPIChatEngine_AcceptList.models.contains(model) else {
            throw ClaudeAPIChatEngineError.upstreamModelUnavailable(model: model)
        }

        // 2. Build Anthropic request body.
        let wireModel = ClaudeAPIChatEngine.wireModelID(for: model)
        let (system, anthropicMessages) = try ClaudeAPIChatEngine.splitMessages(messages)
        let anthropicTools = tools.isEmpty ? nil : tools.map(ClaudeAPIChatEngine.mapTool(_:))
        let systemField = ClaudeAPIChatEngine.buildSystemField(system: system, cacheControl: cacheControl)
        let cachingEnabled = ClaudeAPIChatEngine.systemFieldCarriesCacheControl(systemField)

        let bodyData: Data
        do {
            let req = AnthropicMessagesRequest(
                model: wireModel,
                max_tokens: maxTokens,
                system: systemField,
                messages: anthropicMessages,
                tools: anthropicTools,
                stream: false
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            bodyData = try encoder.encode(req)
        } catch {
            throw ClaudeAPIChatEngineError.decodeError(reason: "request-encode")
        }

        // 3. Wire request. Built ONCE; re-sent verbatim on each retry —
        //    `URLRequest` is a value type and `httpBody` is `Data`, so
        //    every `session.data(for:)` resends the same bytes (no body
        //    consumption across retries).
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // V.13b prompt-caching A — beta header IFF the encoded body carries
        // a cache_control block. Linked emission rule (Lauret P0): header
        // and body cache_control are bound together; never one without the
        // other.
        if cachingEnabled {
            request.setValue(Self.promptCachingBetaHeader, forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = bodyData
        // V.13b-4a — per-attempt wall-clock deadline (serve consumer sets it).
        if let requestTimeout { request.timeoutInterval = requestTimeout }

        // 4 & 5. Fire with bounded backoff on 429/529 (V.13b-2b). Returns
        //    the 200 body; throws `.networkError` / `.upstreamError`
        //    (non-retryable non-200) / `.rateLimited` (retries exhausted) /
        //    `CancellationError` (task cancelled mid-backoff).
        let data = try await fireWithRetry(request)

        // 6. Decode 200 body → Anthropic Messages response.
        let decoded: AnthropicMessagesResponse
        do {
            decoded = try JSONDecoder().decode(AnthropicMessagesResponse.self, from: data)
        } catch {
            throw ClaudeAPIChatEngineError.decodeError(reason: "response-decode")
        }

        // 7. Map to OpenAI Completion shape.
        var textPieces: [String] = []
        var toolCalls: [OpenAIToolCall] = []
        for block in decoded.content {
            switch block {
            case .text(let s):
                textPieces.append(s)
            case .toolUse(let id, let name, let input):
                let argsString = ClaudeAPIChatEngine.encodeJSONValueAsString(input)
                toolCalls.append(OpenAIToolCall(
                    id: id,
                    type: "function",
                    function: .init(name: name, arguments: argsString)
                ))
            case .unknown:
                // Forward-compat: skip unknown block types so a new
                // Anthropic block (e.g. `thinking`) doesn't poison sibling
                // text/tool_use blocks already valid in this response.
                continue
            }
        }
        var content = textPieces.joined()
        // Truncation visibility: if Anthropic stopped because we hit
        // max_tokens, surface that in the content so an OpenAI-shaped
        // caller doesn't silently believe the model finished naturally.
        if decoded.stop_reason == "max_tokens" {
            content += "\n\n[truncated: max_tokens reached]"
        }

        // Heuristic counts (consistent with the existing MLX adapter
        // pattern: heuristic fallback + tokenizer-accurate real-* when
        // available). Prompt heuristic is over the joined user/assistant/
        // system content; response heuristic is over the returned text.
        let promptForHeuristic = messages.map(\.content).joined(separator: "\n")
        let heuristicPrompt = OpenAIChatHandler.estimateTokens(promptForHeuristic)
        let heuristicCompletion = OpenAIChatHandler.estimateTokens(content)

        // V.13b prompt-caching A — wire the Anthropic-decoded
        // `cache_creation_input_tokens` + `cache_read_input_tokens` through
        // to `Completion`. Pass `.some(0)` UNNORMALIZED; the writer in
        // `OpenAIRequestLogStore.record(...)` collapses `.some(0) → nil` so
        // canonical-hash distinction stays at one trust boundary (Schneier
        // P1 — Child B's writer-side invariant).
        let realCacheCreation = decoded.usage?.cache_creation_input_tokens
        let realCacheRead = decoded.usage?.cache_read_input_tokens

        // V.13b prompt-caching A — Schneier P2: when opt-in was requested
        // but the upstream response carries NEITHER cache_* field, fire a
        // once-per-process stderr warning. Defensive signal that the beta
        // header may be deprecated / rejected by Anthropic. Capped to once
        // so log spam is bounded.
        if cachingEnabled, realCacheCreation == nil, realCacheRead == nil {
            Self.warnAboutMissingCacheTokensOnceIfNeeded()
        }

        return OpenAIChatHandler.Completion(
            content: content,
            toolCalls: toolCalls,
            promptTokens: heuristicPrompt,
            completionTokens: heuristicCompletion,
            realPromptTokens: decoded.usage?.input_tokens,
            realCompletionTokens: decoded.usage?.output_tokens,
            realCacheCreationTokens: realCacheCreation,
            realCacheReadTokens: realCacheRead
        )
    }

    /// V.13b prompt-caching A — build the `AnthropicSystem` field for the
    /// outgoing request body.
    ///
    /// Default code path (`cacheControl == nil`, even when system text is
    /// many thousands of tokens) emits `.legacy(text)` which encodes as a
    /// BARE JSON STRING — byte-identical with today's `system: "..."`
    /// wire. Existing v13b-2 + sse-A fixtures pass unchanged.
    ///
    /// Opt-in path (`cacheControl == .ephemeral`, system text non-nil)
    /// wraps the text in a single `AnthropicSystemBlock(type: "text", text:
    /// system, cache_control: ephemeral)` carried inside `.blocks([...])`.
    /// When system is nil under opt-in, we return nil (no system field at
    /// all on the wire) — opt-in with no system content has nothing to
    /// cache.
    static func buildSystemField(system: String?, cacheControl: CacheControlMode?) -> AnthropicSystem? {
        switch (cacheControl, system) {
        case (.ephemeral, .some(let s)):
            return .blocks([
                AnthropicSystemBlock(
                    type: "text",
                    text: s,
                    cache_control: AnthropicCacheControl(type: "ephemeral")
                )
            ])
        case (.ephemeral, .none):
            // V.13b-4c follow-up — Schneier P2 silent-opt-in-drop notice.
            // Opt-in requested but no system content → the typed-block
            // system field is omitted entirely on the wire, so caching is
            // a no-op for this request. Surface a once-per-process stderr
            // notice so operators learn the opt-in was silently dropped
            // (separate lock + flag from beta-deprecation warning).
            warnAboutSilentOptInDropOnceIfNeeded()
            return nil
        case (nil, .some(let s)):
            return .legacy(s)
        case (nil, .none):
            return nil
        }
    }

    /// V.13b prompt-caching A — Lauret P0: "header IFF body carries
    /// cache_control" rule. Inspect the built system field rather than the
    /// opt-in flag so the linked emission can't drift.
    static func systemFieldCarriesCacheControl(_ field: AnthropicSystem?) -> Bool {
        guard case .blocks(let blocks) = field else { return false }
        return blocks.contains { $0.cache_control != nil }
    }

    // MARK: - Retry / backoff (V.13b-2b)

    /// Issue `request`, retrying ONLY `429`/`529` with bounded backoff per
    /// `retryPolicy`. Returns the `200` body data. Throws `.networkError`
    /// (URLSession), `.decodeError("non-http-response")`, `.upstreamError`
    /// (non-retryable non-200, body discarded), `.rateLimited` (retry count
    /// or wait budget exhausted on a rate-limit status), or
    /// `CancellationError` (hosting task cancelled mid-backoff).
    private func fireWithRetry(_ request: URLRequest) async throws -> Data {
        let capSeconds = Int(retryPolicy.maxTotalWait.components.seconds)
        var attempt = 0
        var accumulated: Duration = .zero
        while true {
            // Cooperative cancellation: stop before firing another upstream
            // call if the hosting task was cancelled mid-backoff. Propagates
            // `CancellationError`, NOT a `ClaudeAPIChatEngineError`.
            try Task.checkCancellation()

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let urlError as URLError {
                // Transient URLError (connection drop / timeout) is NOT
                // retried in this item — single-shot, as before. Connection-
                // level retry is out of scope for V.13b-2b.
                throw ClaudeAPIChatEngineError.networkError(code: urlError.code.rawValue)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Any other Error is collapsed to a fixed sentinel — never
                // `String(describing:)` since that could echo userInfo.
                throw ClaudeAPIChatEngineError.networkError(code: -1)
            }

            guard let http = response as? HTTPURLResponse else {
                throw ClaudeAPIChatEngineError.decodeError(reason: "non-http-response")
            }

            if http.statusCode == 200 { return data }

            guard Self.isRetryableStatus(http.statusCode) else {
                // Non-retryable non-200 → discard body, surface status + type.
                let parsedType = Self.extractAnthropicErrorType(from: data)
                throw ClaudeAPIChatEngineError.upstreamError(status: http.statusCode, type: parsedType)
            }

            // Retryable (429/529). Parse + validate + clamp Retry-After.
            let retryAfter = Self.parseRetryAfterSeconds(http, capSeconds: capSeconds)

            // Exhaustion guards (BEFORE sleeping): retry count, then budget.
            if attempt >= retryPolicy.maxRetries {
                throw ClaudeAPIChatEngineError.rateLimited(retryAfter: retryAfter)
            }
            let remaining = retryPolicy.maxTotalWait - accumulated
            if remaining <= .zero {
                throw ClaudeAPIChatEngineError.rateLimited(retryAfter: retryAfter)
            }
            let delay = Self.backoffDelay(attempt: attempt, retryAfter: retryAfter, base: retryPolicy.baseDelay)
            let clamped = min(delay, remaining)
            try await sleeper(clamped)
            accumulated += clamped
            attempt += 1
        }
    }

    /// Retryable upstream statuses (V.13b-2b): `429` (rate_limit) and `529`
    /// (overloaded) ONLY — both mean the request was NOT processed, so
    /// retrying a non-idempotent billable POST is safe. Everything else
    /// (`500/502/503`, other 4xx) is surfaced immediately as
    /// `.upstreamError` (ambiguous side-effect state; no idempotency key).
    static func isRetryableStatus(_ status: Int) -> Bool {
        status == 429 || status == 529
    }

    /// Parse + HARDEN the `Retry-After` RESPONSE header. Accepts ONLY a
    /// non-negative base-10 integer of delta-seconds; the legitimate RFC
    /// 7231 HTTP-date form, floats, negatives, signs, and any other garbage
    /// resolve to `nil` (caller falls back to exponential backoff). The
    /// header is fully attacker/MITM-controllable (the engine egresses
    /// directly until b-4 wires the EgressProxy), so the value is CLAMPED
    /// into `[0, capSeconds]` before it can drive a sleep or be surfaced on
    /// `.rateLimited` — a hostile `Retry-After: 999999` can neither hang
    /// the thread past the wall budget nor be re-emitted unbounded into
    /// senkani's own `Retry-After` response header by b-4.
    static func parseRetryAfterSeconds(_ http: HTTPURLResponse, capSeconds: Int) -> Int? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        // Strict: digits only — rejects "-5", "1.5", "1e9", "0x10", and the
        // HTTP-date form ("Wed, 21 Oct 2025 07:28:00 GMT").
        guard raw.allSatisfy(\.isNumber), let parsed = Int(raw) else { return nil }
        return max(0, min(parsed, max(0, capSeconds)))
    }

    /// Backoff delay for `attempt` (0-indexed). Honors a validated
    /// `Retry-After` verbatim (the server's explicit instruction); else
    /// FULL-JITTERED exponential `base * 2^attempt` — uniformly random in
    /// `[0, base*2^attempt]` to break the synchronized retry-storm that
    /// lock-step backoff produces against an already-overloaded upstream.
    /// A validated `Retry-After` of `0` floors to `base` so the loop cannot
    /// tight-spin.
    static func backoffDelay(attempt: Int, retryAfter: Int?, base: Duration) -> Duration {
        if let retryAfter {
            return retryAfter == 0 ? base : .seconds(retryAfter)
        }
        // `min(attempt, 30)` guards a pathological custom `RetryPolicy`
        // (maxRetries ≳ 63) from overflowing the `Int` shift; shipped
        // presets cap `attempt` at 2 (1<<2 = 4), so this never bites them.
        let exp = base * Double(1 << min(attempt, 30))
        return exp * Double.random(in: 0...1)
    }

    /// Render an exhausted-rate-limit (`.rateLimited`) as the OpenAI wire
    /// shape: HTTP `429` with
    /// `{"error":{…,"type":"rate_limit_error","code":"rate_limit_exceeded"}}`
    /// plus a `Retry-After` header when a validated upstream hint is
    /// present. The machine-readable `{type,code}` tokens are byte-identical
    /// to `OpenAIAuthGate`'s LOCAL rate-limit `429`, so an OpenAI client
    /// sees ONE rate-limit contract whether the limit tripped locally or
    /// upstream. b-4 wires this into the serve error path; `.rateLimited`
    /// is the structured signal it translates.
    public static func openAIRateLimitResponse(retryAfter: Int?) -> Data {
        let headers = retryAfter.map { ["Retry-After": "\($0)"] } ?? [:]
        return OpenAIChatHandler.errorResponse(
            code: 429,
            httpMessage: "Too Many Requests",
            message: "upstream rate limit exceeded",
            type: "rate_limit_error",
            errorCode: "rate_limit_exceeded",
            extraHeaders: headers
        )
    }

    /// V.13b-4c — single static mapper from every `ClaudeAPIChatEngineError`
    /// variant to its OpenAI-shaped (httpStatus, wire bytes) pair. The serve
    /// arm calls this once per error so the wire shape is rendered in
    /// EXACTLY ONE place (and audit-row status mirrors the same table). The
    /// info-leak guard from the engine's throw site (no raw body, no
    /// `String(describing:)`) is preserved here — every message string is
    /// hand-assembled from short fixed identifiers and small integers.
    public static func openAIWireResponse(_ error: ClaudeAPIChatEngineError) -> (httpStatus: Int, data: Data) {
        switch error {
        case .rateLimited(let retryAfter):
            return (429, openAIRateLimitResponse(retryAfter: retryAfter))
        case .upstreamError(let status, let type):
            if status == 401 {
                return (502, OpenAIChatHandler.errorResponse(
                    code: 502, httpMessage: "Bad Gateway",
                    message: "upstream authentication failed; the operator-provided anthropic-key was rejected by api.anthropic.com — rotate the key with `senkani vault add anthropic-key`",
                    type: "upstream_auth_error",
                    errorCode: "upstream_auth_error"
                ))
            }
            return (502, OpenAIChatHandler.errorResponse(
                code: 502, httpMessage: "Bad Gateway",
                message: "upstream error \(status) \(type ?? "unknown")",
                type: "upstream_error",
                errorCode: "upstream_error"
            ))
        case .decodeError(let reason):
            return (502, OpenAIChatHandler.errorResponse(
                code: 502, httpMessage: "Bad Gateway",
                message: "upstream response decode failed: \(reason)",
                type: "upstream_decode_error",
                errorCode: "upstream_decode_error"
            ))
        case .networkError(let code):
            return (502, OpenAIChatHandler.errorResponse(
                code: 502, httpMessage: "Bad Gateway",
                message: "upstream network error (URLError code \(code)); check the egress daemon via `senkani egress`",
                type: "upstream_network_error",
                errorCode: "upstream_network_error"
            ))
        case .upstreamModelUnavailable(let model):
            return (400, OpenAIChatHandler.errorResponse(
                code: 400, httpMessage: "Bad Request",
                message: "model `\(model)` is not in the senkani Anthropic accept-list",
                type: "invalid_request_error",
                errorCode: "model_not_found"
            ))
        }
    }

    // MARK: - Translation helpers

    /// Senkani-side shortname → canonical Anthropic API model ID. The
    /// shortnames in `ModelTier.claudeModelValue` (`claude-haiku-3.5`,
    /// `claude-sonnet-4`, `claude-opus-4`) are NOT valid Anthropic API
    /// IDs on the wire; Anthropic accepts dated identifiers (or `-latest`
    /// pointers). This map is the single source of truth.
    public static func wireModelID(for shortname: String) -> String {
        switch shortname {
        case "claude-haiku-3.5": return "claude-3-5-haiku-latest"
        case "claude-sonnet-4":  return "claude-sonnet-4-0"
        case "claude-opus-4":    return "claude-opus-4-0"
        default:                 return shortname
        }
    }

    /// Pull `role:"system"` messages out into a joined string; emit the
    /// rest as Anthropic `messages[]` preserving order. Multiple system
    /// turns concatenate with `"\n\n"`.
    ///
    /// Parallel tool-result coalescing (Kleppmann re-audit): consecutive
    /// `role:"tool"` follow-ups (the OpenAI shape for a multi-tool-call
    /// turn) are merged into a SINGLE Anthropic user message carrying
    /// multiple `tool_result` blocks — Anthropic's documented convention.
    /// Emitting them as separate user messages is technically accepted but
    /// fragile and can mis-pair `tool_use_id`s under parallel tool-use.
    ///
    /// Local validation (Kleppmann re-audit P3): a `role:"tool"` message
    /// without a `tool_call_id` throws `.decodeError(reason:
    /// "missing-tool-call-id")` BEFORE any wire egress, so the caller
    /// sees the failure point clearly rather than an opaque upstream 400.
    static func splitMessages(_ msgs: [ChatCompletionRequest.Message]) throws
        -> (system: String?, messages: [AnthropicMessage])
    {
        var systems: [String] = []
        var out: [AnthropicMessage] = []
        var pendingToolResults: [AnthropicContentBlock] = []

        func flushPendingToolResults() {
            guard !pendingToolResults.isEmpty else { return }
            out.append(.init(role: "user", content: .blocks(pendingToolResults)))
            pendingToolResults.removeAll(keepingCapacity: false)
        }

        for m in msgs {
            // Any non-tool message ends a tool-result run.
            if m.role != "tool" { flushPendingToolResults() }

            if m.role == "system" {
                if !m.content.isEmpty { systems.append(m.content) }
                continue
            }
            if m.role == "tool" {
                guard let toolId = m.toolCallId, !toolId.isEmpty else {
                    throw ClaudeAPIChatEngineError.decodeError(reason: "missing-tool-call-id")
                }
                pendingToolResults.append(.toolResult(toolUseId: toolId, content: m.content))
                continue
            }
            if m.role == "assistant" {
                let priorToolCalls = m.toolCalls ?? []
                if !priorToolCalls.isEmpty {
                    var blocks: [AnthropicContentBlock] = []
                    // Mixed-block: assistant text BEFORE its tool_use
                    // blocks (the model's pre-tool reasoning context).
                    // Anthropic accepts heterogeneous content arrays.
                    if !m.content.isEmpty {
                        blocks.append(.text(m.content))
                    }
                    for tc in priorToolCalls {
                        let input = ClaudeAPIChatEngine.decodeJSONValueFromArgumentsString(tc.function.arguments)
                        blocks.append(.toolUse(id: tc.id, name: tc.function.name, input: input))
                    }
                    out.append(.init(role: "assistant", content: .blocks(blocks)))
                } else {
                    out.append(.init(role: "assistant", content: .text(m.content)))
                }
                continue
            }
            // user (and any other role we don't model specially)
            out.append(.init(role: m.role, content: .text(m.content)))
        }
        flushPendingToolResults()
        return (systems.isEmpty ? nil : systems.joined(separator: "\n\n"), out)
    }

    static func mapTool(_ tool: ChatCompletionRequest.Tool) -> AnthropicTool {
        AnthropicTool(
            name: tool.function.name,
            description: tool.function.description,
            input_schema: tool.function.parameters ?? .object([:])
        )
    }

    /// Encode a JSONValue as an OpenAI-style arguments STRING — a JSON
    /// document. Sorted keys for determinism in tests.
    static func encodeJSONValueAsString(_ v: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(v), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }

    /// Decode an OpenAI tool-call arguments string (a JSON document) back
    /// into a JSONValue for Anthropic's structured `input`. On malformed
    /// input we surface the original string wrapped as a JSON string so
    /// the upstream tool sees the literal bytes — caller history that's
    /// partial / streamed mid-tool-call survives the round-trip rather
    /// than throwing.
    static func decodeJSONValueFromArgumentsString(_ s: String) -> JSONValue {
        guard let data = s.data(using: .utf8),
              let v = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return .string(s)
        }
        return v
    }

    /// Best-effort extraction of `error.type` from an Anthropic error
    /// envelope. On any parse failure (non-JSON body, wrong shape, missing
    /// field) returns nil — the body is never echoed.
    static func extractAnthropicErrorType(from data: Data) -> String? {
        struct Envelope: Decodable {
            struct Inner: Decodable { let type: String? }
            let error: Inner?
        }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.error?.type
    }
}

// MARK: - Anthropic wire shapes (internal)

struct AnthropicMessagesRequest: Codable {
    let model: String
    let max_tokens: Int
    /// V.13b prompt-caching A — sum-type system field. Encodes as a BARE
    /// JSON STRING for the legacy form (byte-identical with the pre-
    /// prompt-caching wire) and as a JSON ARRAY for the typed-block opt-in
    /// form. Default code paths build `.legacy(...)` so existing fixtures
    /// pass unchanged.
    let system: AnthropicSystem?
    let messages: [AnthropicMessage]
    let tools: [AnthropicTool]?
    let stream: Bool
}

/// V.13b prompt-caching A — sum-type for the Anthropic `system` field.
///
/// `.legacy(String)` encodes as a BARE JSON STRING (no object wrapper).
/// `.blocks([AnthropicSystemBlock])` encodes as a JSON ARRAY.
///
/// Lauret P0 — sum-type wire round-trip: encoding `.legacy("hi")` MUST
/// produce JSON `"hi"` and decoding `"hi"` MUST return `.legacy("hi")`.
/// Likewise `.blocks([...])` ↔ `[...]`. The single-value-container pattern
/// makes this transparent.
public enum AnthropicSystem: Codable, Sendable, Equatable {
    case legacy(String)
    case blocks([AnthropicSystemBlock])

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .legacy(let s):    try c.encode(s)
        case .blocks(let arr):  try c.encode(arr)
        }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .legacy(s); return }
        // V.13b-4c follow-up — clarified decoder error so a malformed
        // input that is NEITHER a bare JSON string NOR a JSON array
        // surfaces a debug-friendly message rather than the inner
        // typeMismatch from `[AnthropicSystemBlock].self`.
        if let arr = try? c.decode([AnthropicSystemBlock].self) {
            self = .blocks(arr)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "AnthropicSystem: expected bare JSON string or JSON array of system blocks"
        )
    }

    /// Convenience: pull the text content regardless of variant. Used by
    /// audit / debug surfaces that want a plain string view.
    ///
    /// V.13b-4c follow-up (Schneier P3) — multi-block join uses `"\n\n"`
    /// instead of empty separator so the assembled text matches what
    /// `splitMessages` produces when multiple system turns are joined
    /// (which uses `"\n\n"` at line 670). Audit/debug surfaces that read
    /// `systemText` see the same paragraph boundary either way.
    public var systemText: String? {
        switch self {
        case .legacy(let s): return s
        case .blocks(let arr):
            let texts = arr.map(\.text)
            return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
        }
    }
}

/// V.13b prompt-caching A — typed system block (Anthropic's
/// `{"type":"text","text":"...","cache_control":{...}}`). Today only
/// `type: "text"` is modeled — Anthropic may add more block types in
/// future; we'll widen when they ship.
public struct AnthropicSystemBlock: Codable, Sendable, Equatable {
    public let type: String         // always "text" today
    public let text: String
    public let cache_control: AnthropicCacheControl?
    public init(type: String, text: String, cache_control: AnthropicCacheControl? = nil) {
        self.type = type
        self.text = text
        self.cache_control = cache_control
    }
}

/// V.13b prompt-caching A — typed `cache_control` discriminator
/// (Anthropic's `{"type":"ephemeral"}`). Only `ephemeral` is modeled
/// today.
///
/// V.13b-4c follow-up (Schneier P2 namespace rename) — renamed from
/// `CacheControl` to `AnthropicCacheControl` to match the
/// `AnthropicSystem` / `AnthropicSystemBlock` naming convention in the
/// same file. The `Codable` synthesis depends only on field names + types
/// (not the Swift type name), so the JSON wire shape
/// `{"type":"ephemeral"}` is byte-identical with the prior `CacheControl`
/// emission. Lauret P0 wire-byte invariant preserved.
public struct AnthropicCacheControl: Codable, Sendable, Equatable {
    public let type: String         // always "ephemeral" today
    public init(type: String) {
        self.type = type
    }
}

struct AnthropicMessage: Codable {
    let role: String   // "user" | "assistant"
    let content: AnthropicMessageContent
}

/// Anthropic `content` accepts EITHER a bare string OR an array of typed
/// blocks. We encode as a string when there's a single text payload and
/// no tool blocks; otherwise an array.
enum AnthropicMessageContent: Codable {
    case text(String)
    case blocks([AnthropicContentBlock])

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let s):       try c.encode(s)
        case .blocks(let parts): try c.encode(parts)
        }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .text(s); return }
        let arr = try c.decode([AnthropicContentBlock].self)
        self = .blocks(arr)
    }
}

enum AnthropicContentBlock: Codable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseId: String, content: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case id
        case name
        case input
        case tool_use_id
        case content
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try c.encode("text", forKey: .type)
            try c.encode(s, forKey: .text)
        case .toolUse(let id, let name, let input):
            try c.encode("tool_use", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(input, forKey: .input)
        case .toolResult(let toolUseId, let content):
            try c.encode("tool_result", forKey: .type)
            try c.encode(toolUseId, forKey: .tool_use_id)
            try c.encode(content, forKey: .content)
        }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try c.decode(String.self, forKey: .text))
        case "tool_use":
            self = .toolUse(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .name),
                input: try c.decode(JSONValue.self, forKey: .input)
            )
        case "tool_result":
            self = .toolResult(
                toolUseId: try c.decode(String.self, forKey: .tool_use_id),
                content: try c.decode(String.self, forKey: .content)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "unknown Anthropic content block type \(type)"
            )
        }
    }
}

struct AnthropicTool: Codable {
    let name: String
    let description: String?
    let input_schema: JSONValue
}

struct AnthropicMessagesResponse: Codable {
    let id: String?
    let type: String?
    let role: String?
    let content: [AnthropicResponseBlock]
    let stop_reason: String?
    let usage: AnthropicUsage?
}

/// Forward-compat (Kleppmann re-audit): an unknown block `type`
/// (Anthropic may introduce `thinking`, `server_tool_use`, etc.) must
/// NOT abort decoding of the whole response — valid sibling blocks
/// would be lost. Unknown types decode to `.unknown` and are skipped
/// by the chat() consumer; encoding `.unknown` is unsupported (and
/// unnecessary — we never round-trip a response block back to the wire).
enum AnthropicResponseBlock: Codable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey {
        case type, text, id, name, input
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try c.decode(String.self, forKey: .text))
        case "tool_use":
            self = .toolUse(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .name),
                input: try c.decode(JSONValue.self, forKey: .input)
            )
        default:
            self = .unknown(type: type)
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try c.encode("text", forKey: .type)
            try c.encode(s, forKey: .text)
        case .toolUse(let id, let name, let input):
            try c.encode("tool_use", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(input, forKey: .input)
        case .unknown(let type):
            try c.encode(type, forKey: .type)
        }
    }
}

struct AnthropicUsage: Codable {
    let input_tokens: Int
    let output_tokens: Int
    /// V.13b prompt-caching A — Anthropic-reported cache write tokens (the
    /// "cold path" cost of seeding the cache on this turn). Absent when
    /// the request did NOT opt into caching; absent ALSO when the beta
    /// header was rejected / deprecated (defensive once-per-process stderr
    /// warning fires in that case).
    let cache_creation_input_tokens: Int?
    /// V.13b prompt-caching A — Anthropic-reported cache read tokens (the
    /// "warm path" cost when the cache hit). Same absence semantics as
    /// `cache_creation_input_tokens`.
    let cache_read_input_tokens: Int?

    enum CodingKeys: String, CodingKey {
        case input_tokens, output_tokens
        case cache_creation_input_tokens, cache_read_input_tokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input_tokens = try c.decode(Int.self, forKey: .input_tokens)
        output_tokens = try c.decode(Int.self, forKey: .output_tokens)
        cache_creation_input_tokens = try c.decodeIfPresent(Int.self, forKey: .cache_creation_input_tokens)
        cache_read_input_tokens = try c.decodeIfPresent(Int.self, forKey: .cache_read_input_tokens)
    }

    /// Encoder is retained for forward-compat — production code only
    /// decodes this shape — but kept symmetric so test fixtures can encode
    /// canonical Anthropic usage envelopes.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(input_tokens, forKey: .input_tokens)
        try c.encode(output_tokens, forKey: .output_tokens)
        try c.encodeIfPresent(cache_creation_input_tokens, forKey: .cache_creation_input_tokens)
        try c.encodeIfPresent(cache_read_input_tokens, forKey: .cache_read_input_tokens)
    }
}

// MARK: - V.13b-sse-a — typed streaming events (Child A)

/// Typed event yielded by `ClaudeAPIChatEngine.chatStream(...)` (Child A of
/// the v13b-sse decomposition). The parser
/// (`AnthropicSSEFrameParser`) is the single authority that lifts
/// SSE frame bytes into one of these variants. Children B and C
/// translate this into the OpenAI SSE wire shape (`OpenAIChatStream`) and
/// the listener wire respectively; this Child carries ONLY the engine-side
/// primitive.
///
/// Info-leak guard (Schneier r10): the `.error(type:)` payload is the
/// short `error.type` identifier ONLY — never `error.message`, which can
/// echo prompt content / key fragments / upstream guidance. The parser
/// enforces this redaction at the SSE-frame boundary.
public enum AnthropicStreamEvent: Sendable, Equatable {
    case messageStart(id: String, inputTokens: Int?)
    case contentBlockStart(index: Int, block: AnthropicStreamBlockStart)
    case contentBlockDelta(index: Int, delta: AnthropicStreamBlockDelta)
    case contentBlockStop(index: Int)
    case messageDelta(stopReason: String?, outputTokens: Int?)
    case messageStop
    /// Anthropic `event: error` frame — short identifier ONLY
    /// (`overloaded_error`, `rate_limit_error`, …). `error.message` is
    /// dropped at the parser boundary.
    case error(type: String)
}

public enum AnthropicStreamBlockStart: Sendable, Equatable {
    case text
    case toolUse(id: String, name: String)
}

public enum AnthropicStreamBlockDelta: Sendable, Equatable {
    case textDelta(String)
    case inputJsonDelta(String)
}

// MARK: - V.13b-sse-a — chatStream entrypoint (Child A)

extension ClaudeAPIChatEngine {

    /// Streaming counterpart of `chat(...)`: opens `POST /v1/messages` with
    /// `stream: true`, drives `URLSession.bytes(for:)` AsyncBytes through
    /// `AnthropicSSEFrameParser`, and yields typed
    /// `AnthropicStreamEvent`s.
    ///
    /// Scope carves (Child A of the v13b-sse decomposition):
    ///   - This file ONLY exposes the engine-side primitive. Translator
    ///     (chunk-deltas → OpenAI SSE wire), listener wiring, and the
    ///     `surface=.chatStream` 501-lift are children B / C / D.
    ///   - No retry MID-STREAM. `RetryPolicy.serveSafe` governs the OPEN-
    ///     side decision only: if the upstream returns `429` / `529` BEFORE
    ///     any bytes flow, `fireStreamOpenWithRetry` honors the same
    ///     bounded backoff as `chat()`. Once the stream has begun yielding
    ///     events, a mid-stream URLError is surfaced verbatim — translator
    ///     B handles in-flight rollback.
    ///
    /// `requestTimeout` semantics for streams: when set, the per-attempt
    /// `URLRequest.timeoutInterval` acts as the IDLE timeout (inter-byte),
    /// NOT end-to-end. The session will fire `URLError.timedOut` if no
    /// bytes arrive within the interval. End-to-end deadlines must be
    /// enforced by the listener (Child C).
    ///
    /// Cancellation: the returned `AsyncThrowingStream`'s `onTermination`
    /// cancels the producer Task, which cancels the URLSession AsyncBytes
    /// iterator. URLSession.bytes(for:)'s native cancellation propagates to
    /// the underlying data task — see
    /// `AnthropicSSEFrameParserTests.cancelPropagatesToURLProtocolStopLoading`
    /// for the observable contract.
    public func chatStream(
        model: String,
        messages: [ChatCompletionRequest.Message],
        tools: [ChatCompletionRequest.Tool]
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        chatStream(model: model, messages: messages, tools: tools, cacheControl: nil)
    }

    /// V.13b prompt-caching A — extended `chatStream(...)` taking the
    /// opt-in flag. Symmetric to `chat(...)` (Lauret P0): a wire-shape
    /// regression in one path but not the other would silently bifurcate
    /// the caching surface. The serve dispatcher passes
    /// `request.cacheControl` here just as it does for `chat(...)`.
    public func chatStream(
        model: String,
        messages: [ChatCompletionRequest.Message],
        tools: [ChatCompletionRequest.Tool],
        cacheControl: CacheControlMode?
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        // Shared mutable handle on the in-flight URLSessionDataTask. The
        // stream's `onTermination` reaches into this box to call
        // `dataTask.cancel()` directly — `URLSession.bytes(for:)`'s native
        // cancellation propagation through the AsyncBytes iterator alone
        // proved too slow to meet the v13b-sse-a cancel-propagation SLA
        // (Karpathy r10 P1). Explicit dataTask.cancel() is the documented
        // teardown seam and surfaces as `stopLoading()` on the URLProtocol.
        let cancelBox = CancelBox()

        return AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    // 1. Accept-list gate BEFORE any I/O.
                    guard ClaudeAPIChatEngine_AcceptList.models.contains(model) else {
                        throw ClaudeAPIChatEngineError.upstreamModelUnavailable(model: model)
                    }

                    // 2. Build request body (mirror chat() EXCEPT stream:true).
                    let wireModel = ClaudeAPIChatEngine.wireModelID(for: model)
                    let (system, anthropicMessages) = try ClaudeAPIChatEngine.splitMessages(messages)
                    let anthropicTools = tools.isEmpty ? nil : tools.map(ClaudeAPIChatEngine.mapTool(_:))
                    let systemField = ClaudeAPIChatEngine.buildSystemField(system: system, cacheControl: cacheControl)
                    let cachingEnabled = ClaudeAPIChatEngine.systemFieldCarriesCacheControl(systemField)

                    let bodyData: Data
                    do {
                        let req = AnthropicMessagesRequest(
                            model: wireModel,
                            max_tokens: self.maxTokens,
                            system: systemField,
                            messages: anthropicMessages,
                            tools: anthropicTools,
                            stream: true
                        )
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.sortedKeys]
                        bodyData = try encoder.encode(req)
                    } catch {
                        throw ClaudeAPIChatEngineError.decodeError(reason: "request-encode")
                    }

                    // 3. Wire request.
                    var request = URLRequest(url: self.endpoint)
                    request.httpMethod = "POST"
                    request.setValue(self.apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue(self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
                    request.setValue("application/json", forHTTPHeaderField: "content-type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "accept")
                    // V.13b prompt-caching A — beta header IFF the encoded
                    // body carries a cache_control block. Same linked-emission
                    // rule as chat() (Lauret P0).
                    if cachingEnabled {
                        request.setValue(Self.promptCachingBetaHeader, forHTTPHeaderField: "anthropic-beta")
                    }
                    request.httpBody = bodyData
                    // Per-attempt IDLE timeout for streams (doc-noted above).
                    if let t = self.requestTimeout { request.timeoutInterval = t }

                    // 4. Open with bounded backoff on 429/529. Returns the
                    //    open AsyncBytes; throws upstreamError / rateLimited /
                    //    networkError just like chat()'s pre-stream path.
                    let bytes = try await fireStreamOpenWithRetry(request)

                    // Stash the underlying data task so onTermination can
                    // cancel it directly.
                    cancelBox.set(bytes.task)

                    // 5. Pipe AsyncBytes through the parser, yielding events.
                    for try await event in AnthropicSSEFrameParser.parseFrames(bytes) {
                        continuation.yield(event)
                        if Task.isCancelled { break }
                    }
                    // V.13b-4c follow-up — Schneier P2 warning-symmetry
                    // chatStream hook. Mirror the chat() non-stream guard:
                    // if opt-in was requested but the stream completed with
                    // NEITHER cache_creation_input_tokens NOR
                    // cache_read_input_tokens observed (the SSE parser does
                    // not currently surface either field via
                    // `AnthropicStreamEvent`, so the stream-side observation
                    // is always "both nil"), fire the once-per-process
                    // beta-deprecation warning. Same lock-guarded flag as
                    // chat() — a single emission per process across BOTH
                    // entry points.
                    if cachingEnabled {
                        Self.warnAboutMissingCacheTokensOnceIfNeeded()
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                // Two-pronged teardown:
                //   (a) cancel the consumer-loop Task so any subsequent
                //       `for try await` iteration of the parser exits.
                //   (b) cancel the URLSessionDataTask directly so the
                //       URLProtocol observes `stopLoading()` immediately —
                //       AsyncBytes' iterator alone can stall on a pending
                //       chunk read for too long to satisfy the SLA.
                cancelBox.cancel()
                task.cancel()
            }
        }
    }

    // MARK: - Private streaming-open backoff loop

    /// Open the streaming POST, retrying ONLY `429`/`529` with bounded
    /// backoff per `retryPolicy`. The body bytes (AsyncBytes) of the first
    /// `200` response are returned to the caller. NO retry mid-stream once
    /// bytes are flowing.
    private func fireStreamOpenWithRetry(_ request: URLRequest) async throws -> URLSession.AsyncBytes {
        let capSeconds = Int(self.retryPolicy.maxTotalWait.components.seconds)
        var attempt = 0
        var accumulated: Duration = .zero
        while true {
            try Task.checkCancellation()

            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await self.session.bytes(for: request)
            } catch let urlError as URLError {
                throw ClaudeAPIChatEngineError.networkError(code: urlError.code.rawValue)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ClaudeAPIChatEngineError.networkError(code: -1)
            }

            guard let http = response as? HTTPURLResponse else {
                throw ClaudeAPIChatEngineError.decodeError(reason: "non-http-response")
            }

            if http.statusCode == 200 { return bytes }

            // Non-200: drain bytes (but never echo them) and discard.
            // We do NOT await drain — the connection will be torn down by
            // ARC when `bytes` goes out of scope. Anthropic non-200s carry
            // small JSON envelopes; the next attempt opens a fresh
            // connection regardless.

            guard ClaudeAPIChatEngine.isRetryableStatus(http.statusCode) else {
                // Pull a small bounded prefix of body bytes to feed the
                // existing error-type extractor. Cap at 8 KiB.
                let bodyData = (try? await Self.drainBounded(bytes, max: 8 * 1024)) ?? Data()
                let parsedType = ClaudeAPIChatEngine.extractAnthropicErrorType(from: bodyData)
                throw ClaudeAPIChatEngineError.upstreamError(status: http.statusCode, type: parsedType)
            }

            // Retryable.
            let retryAfter = ClaudeAPIChatEngine.parseRetryAfterSeconds(http, capSeconds: capSeconds)
            if attempt >= self.retryPolicy.maxRetries {
                throw ClaudeAPIChatEngineError.rateLimited(retryAfter: retryAfter)
            }
            let remaining = self.retryPolicy.maxTotalWait - accumulated
            if remaining <= .zero {
                throw ClaudeAPIChatEngineError.rateLimited(retryAfter: retryAfter)
            }
            let delay = ClaudeAPIChatEngine.backoffDelay(
                attempt: attempt,
                retryAfter: retryAfter,
                base: self.retryPolicy.baseDelay
            )
            let clamped = min(delay, remaining)
            try await self.sleeper(clamped)
            accumulated += clamped
            attempt += 1
        }
    }

    /// Drain at most `max` bytes from an AsyncBytes; return Data. Never
    /// throws — best-effort body capture for the non-200 error path.
    private static func drainBounded(_ bytes: URLSession.AsyncBytes, max: Int) async throws -> Data {
        var out = Data()
        out.reserveCapacity(min(max, 1024))
        for try await b in bytes {
            out.append(b)
            if out.count >= max { break }
        }
        return out
    }

}

/// Sendable holder for the in-flight `URLSessionDataTask`. The
/// `chatStream(...)` Task fills it once the stream opens; the
/// `onTermination` handler reads it and calls `.cancel()` directly to
/// force the URLProtocol's `stopLoading()` immediately.
///
/// `URLSession.bytes(for:)`'s native cancellation propagation through the
/// AsyncBytes iterator alone is too slow to satisfy the v13b-sse-a
/// cancel-propagation SLA (Karpathy r10 P1 — observable contract on
/// `MockSSEStreamProtocol.observedStopLoading`). Explicit
/// `dataTask.cancel()` is the documented teardown seam.
private final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled: Bool = false
    func set(_ t: URLSessionDataTask) {
        lock.lock(); defer { lock.unlock() }
        if cancelled {
            t.cancel()
            return
        }
        task = t
    }
    func cancel() {
        lock.lock()
        let t = task
        cancelled = true
        lock.unlock()
        t?.cancel()
    }
}

