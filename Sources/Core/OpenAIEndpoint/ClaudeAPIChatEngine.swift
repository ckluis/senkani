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

    public init(
        apiKey: String,
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        anthropicVersion: String = "2023-06-01",
        maxTokens: Int = 4096,
        retryPolicy: RetryPolicy = .default,
        sleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.apiKey = apiKey
        self.session = session
        self.endpoint = endpoint
        self.anthropicVersion = anthropicVersion
        self.maxTokens = maxTokens
        self.retryPolicy = retryPolicy
        self.sleeper = sleeper
    }

    public func chat(
        model: String,
        messages: [ChatCompletionRequest.Message],
        tools: [ChatCompletionRequest.Tool]
    ) async throws -> OpenAIChatHandler.Completion {
        // 1. Accept-list gate BEFORE any I/O. No DNS, no connect.
        guard ClaudeAPIChatEngine_AcceptList.models.contains(model) else {
            throw ClaudeAPIChatEngineError.upstreamModelUnavailable(model: model)
        }

        // 2. Build Anthropic request body.
        let wireModel = ClaudeAPIChatEngine.wireModelID(for: model)
        let (system, anthropicMessages) = try ClaudeAPIChatEngine.splitMessages(messages)
        let anthropicTools = tools.isEmpty ? nil : tools.map(ClaudeAPIChatEngine.mapTool(_:))

        let bodyData: Data
        do {
            let req = AnthropicMessagesRequest(
                model: wireModel,
                max_tokens: maxTokens,
                system: system,
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
        request.httpBody = bodyData

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

        return OpenAIChatHandler.Completion(
            content: content,
            toolCalls: toolCalls,
            promptTokens: heuristicPrompt,
            completionTokens: heuristicCompletion,
            realPromptTokens: decoded.usage?.input_tokens,
            realCompletionTokens: decoded.usage?.output_tokens
        )
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
    let system: String?
    let messages: [AnthropicMessage]
    let tools: [AnthropicTool]?
    let stream: Bool
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
}
