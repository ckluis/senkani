import Testing
import Foundation
@testable import Core

#if canImport(Darwin)
import Darwin
#endif

/// V.13a-3 — POST /v1/chat/completions (non-streaming) + per-key preset
/// routing + T.5 audit-chain entry. Covers the acceptance checklist from
/// `spec/autonomous/backlog/phase-v13a-3-chat-nonstream-routing-audit.md`:
///
///   1. chat-shape
///   2. preset-wins-over-request-model
///   3. response-model-is-actual
///   4. model_logged-in-telemetry distinct from resolved_tier
///   5. audit-entry-shape
///   6. audit-bodies-off-by-default
///   7. audit-bodies-on
///   8. single-link-integrity (+ tamper detection)
///   + decode 400 paths, preset fallback, live listener round-trip
@Suite("OpenAI chat non-streaming routing + audit (V.13a-3)")
struct OpenAIChatRoutingAuditTests {

    // A deterministic engine: echoes the routed model + fixed token counts.
    private static func stubEngine(content: String = "hello from the stub") -> OpenAIChatHandler.Engine {
        OpenAIChatHandler.Engine { _, _ in
            OpenAIChatHandler.Completion(content: content, promptTokens: 7, completionTokens: 4)
        }
    }

    private static func request(model: String, prompt: String = "say hi") -> ChatCompletionRequest {
        ChatCompletionRequest(model: model, messages: [.init(role: "user", content: prompt)])
    }

    private static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - 1. chat-shape

    @Test("response is a well-formed OpenAI chat.completion object")
    func chatShape() {
        let result = OpenAIChatHandler.handle(
            request: Self.request(model: "gpt-4o"),
            recordPreset: "quick", keyLabel: "ci",
            engine: Self.stubEngine(), now: Self.fixedNow, id: "chatcmpl-test1"
        )
        let r = result.response
        #expect(r.id == "chatcmpl-test1")
        #expect(r.object == "chat.completion")
        #expect(r.created == Int(Self.fixedNow.timeIntervalSince1970))
        #expect(r.choices.count == 1)
        #expect(r.choices[0].index == 0)
        #expect(r.choices[0].message.role == "assistant")
        #expect(r.choices[0].message.content == "hello from the stub")
        #expect(r.choices[0].finishReason == "stop")
        #expect(r.usage.promptTokens == 7)
        #expect(r.usage.completionTokens == 4)
        #expect(r.usage.totalTokens == 11)

        // Encoded JSON carries the OpenAI keys.
        let framed = OpenAIChatHandler.encodeResponse(r)
        let text = String(decoding: framed, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK"))
        #expect(text.contains("\"object\":\"chat.completion\""))
        #expect(text.contains("\"finish_reason\":\"stop\""))
        #expect(text.contains("\"total_tokens\":11"))
    }

    // MARK: - 2. preset wins over request model

    @Test("per-key preset wins; request model is logged but does not route")
    func presetWinsOverRequestModel() {
        // Key preset Quick → Haiku tier, regardless of the requested gpt-4o.
        let routing = OpenAIChatHandler.route(request: Self.request(model: "gpt-4o"), recordPreset: "quick")
        #expect(routing.presetUsed == .quick)
        #expect(routing.resolvedTier == .quick)
        #expect(routing.modelLogged == "gpt-4o")        // logged, not routed
        #expect(routing.actualModel == ModelTier.quick.claudeModelValue)

        // A different requested model against the SAME preset routes
        // identically — the request model never changes routing.
        let routing2 = OpenAIChatHandler.route(request: Self.request(model: "o3-mini"), recordPreset: "quick")
        #expect(routing2.resolvedTier == .quick)
        #expect(routing2.actualModel == routing.actualModel)
        #expect(routing2.modelLogged == "o3-mini")

        // A Research-preset key routes to the frontier tier.
        let research = OpenAIChatHandler.route(request: Self.request(model: "gpt-4o"), recordPreset: "research")
        #expect(research.resolvedTier == .frontier)
        #expect(research.actualModel == ModelTier.frontier.claudeModelValue)
    }

    // MARK: - 3. response model is the actual model used

    @Test("response.model reports the actual model, not the requested one")
    func responseModelIsActual() {
        let result = OpenAIChatHandler.handle(
            request: Self.request(model: "gpt-4o"),
            recordPreset: "quick", keyLabel: nil,
            engine: Self.stubEngine(), now: Self.fixedNow, id: "x"
        )
        #expect(result.response.model == ModelTier.quick.claudeModelValue)
        #expect(result.response.model != "gpt-4o")
    }

    // MARK: - 4. telemetry: model_logged distinct from resolved_tier

    @Test("telemetry surfaces model_logged distinct from resolved_tier")
    func telemetryModelLoggedDistinct() {
        let result = OpenAIChatHandler.handle(
            request: Self.request(model: "gpt-4o"),
            recordPreset: "quick", keyLabel: nil,
            engine: Self.stubEngine(), now: Self.fixedNow, id: "x"
        )
        let t = result.telemetry
        #expect(t.surface == "chat")
        #expect(t.modelLogged == "gpt-4o")
        #expect(t.resolvedTier == ModelTier.quick.rawValue)   // "quick"
        #expect(t.modelLogged != t.resolvedTier)
        // The same distinction appears in the audit fields.
        #expect(result.auditFields.modelLogged == "gpt-4o")
        #expect(result.auditFields.resolvedTier == "quick")
        #expect(result.auditFields.modelLogged != result.auditFields.resolvedTier)
    }

    // MARK: - 5. audit-entry shape

    @Test("each request produces exactly one audit entry with the documented shape")
    func auditEntryShape() {
        let result = OpenAIChatHandler.handle(
            request: Self.request(model: "gpt-4o"),
            recordPreset: "quick", keyLabel: "team-key",
            engine: Self.stubEngine(), now: Self.fixedNow, id: "x"
        )
        let chain = OpenAIAuditChain()
        chain.append(result.auditFields, bodies: nil)
        #expect(chain.count == 1)

        let entry = chain.entries[0]
        #expect(entry.fields.keyLabel == "team-key")
        #expect(entry.fields.surface == "chat")
        #expect(entry.fields.modelLogged == "gpt-4o")
        #expect(entry.fields.presetUsed == "quick")
        #expect(entry.fields.resolvedTier == "quick")
        #expect(entry.fields.promptTokenCount == 7)
        #expect(entry.fields.completionTokenCount == 4)
        #expect(entry.fields.status == "ok")
        #expect(entry.prev == nil)               // first link

        // Canonical columns carry exactly the documented keys (no bodies).
        let cols = OpenAIAuditChain.canonicalColumns(fields: result.auditFields, bodies: nil)
        let keys = Set(cols.keys)
        #expect(keys == [
            "ts", "key_label", "surface", "model_logged", "preset_used",
            "resolved_tier", "prompt_token_count", "completion_token_count", "status",
        ])
    }

    // MARK: - 6. audit-bodies off by default

    @Test("audit bodies off by default — no body columns, and hash differs from bodies-on")
    func auditBodiesOffByDefault() {
        let result = OpenAIChatHandler.handle(
            request: Self.request(model: "gpt-4o", prompt: "secret prompt text"),
            recordPreset: "quick", keyLabel: nil,
            engine: Self.stubEngine(content: "secret response text"),
            now: Self.fixedNow, id: "x"
        )
        let colsOff = OpenAIAuditChain.canonicalColumns(fields: result.auditFields, bodies: nil)
        #expect(colsOff["request_body"] == nil)
        #expect(colsOff["response_body"] == nil)

        // Off-chain bytes do not contain the prompt/response text.
        let off = ChainHasher.canonicalBytes(table: OpenAIAuditChain.table, columns: colsOff)
        let offText = String(decoding: off, as: UTF8.self)
        #expect(!offText.contains("secret prompt text"))
        #expect(!offText.contains("secret response text"))

        // Bodies-on changes the hash domain (extra columns).
        let chainOff = OpenAIAuditChain()
        chainOff.append(result.auditFields, bodies: nil)
        let chainOn = OpenAIAuditChain()
        chainOn.append(result.auditFields, bodies: result.auditBodies)
        #expect(chainOff.entries[0].entryHash != chainOn.entries[0].entryHash)
    }

    // MARK: - 7. audit bodies on

    @Test("audit bodies on stores request/response bodies in the chain")
    func auditBodiesOn() {
        let result = OpenAIChatHandler.handle(
            request: Self.request(model: "gpt-4o"),
            recordPreset: "quick", keyLabel: nil,
            engine: Self.stubEngine(content: "stored response"),
            now: Self.fixedNow, id: "x"
        )
        let chain = OpenAIAuditChain()
        chain.append(result.auditFields, bodies: result.auditBodies)
        let entry = chain.entries[0]
        #expect(entry.bodies?.responseBody == "stored response")
        #expect(entry.bodies?.requestBody.contains("model=gpt-4o") == true)

        let cols = OpenAIAuditChain.canonicalColumns(fields: result.auditFields, bodies: result.auditBodies)
        #expect(cols["request_body"] != nil)
        #expect(cols["response_body"] != nil)
        // The entry still verifies with bodies present.
        #expect(chain.verify() == .ok(count: 1))
    }

    // MARK: - 8. single-link integrity + tamper detection

    @Test("audit chain verifies after each request and detects tampering")
    func singleLinkIntegrityAndTamper() {
        let chain = OpenAIAuditChain()
        #expect(chain.verify() == .empty)

        // Append three requests; chain stays internally consistent.
        for i in 0..<3 {
            let result = OpenAIChatHandler.handle(
                request: Self.request(model: "gpt-4o", prompt: "msg \(i)"),
                recordPreset: "quick", keyLabel: nil,
                engine: Self.stubEngine(), now: Self.fixedNow.addingTimeInterval(Double(i)), id: "id-\(i)"
            )
            chain.append(result.auditFields, bodies: nil)
        }
        #expect(chain.verify() == .ok(count: 3))

        // Linkage: each entry's prev equals the prior entry's hash.
        let entries = chain.entries
        #expect(entries[0].prev == nil)
        #expect(entries[1].prev == entries[0].entryHash)
        #expect(entries[2].prev == entries[1].entryHash)

        // Tamper: corrupt the stored hash of the middle entry → brokenAt(1).
        var tampered = entries
        tampered[1] = OpenAIAuditChain.Entry(
            fields: entries[1].fields, bodies: entries[1].bodies,
            prev: entries[1].prev, entryHash: "deadbeef"
        )
        guard case .linkBrokenAt(let li) = OpenAIAuditChain.verify(entries: tampered) else {
            // A corrupted hash breaks the *next* entry's prev linkage first
            // (entry 2's prev no longer equals entry 1's stored hash). Either
            // a content mismatch at 1 or a link break at 2 is an acceptable
            // first-failure; assert one of them fires.
            if case .brokenAt(let bi, _, _) = OpenAIAuditChain.verify(entries: tampered) {
                #expect(bi == 1)
                return
            }
            Issue.record("expected tamper to be detected, got \(OpenAIAuditChain.verify(entries: tampered))")
            return
        }
        #expect(li == 2)
    }

    // MARK: - decode + 400 paths

    @Test("decode round-trips a valid request and rejects malformed bodies")
    func decodePaths() {
        let valid = Data(#"{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}"#.utf8)
        let decoded = OpenAIChatHandler.decodeRequest(valid)
        #expect(decoded?.model == "gpt-4o")
        #expect(decoded?.messages.first?.content == "hi")

        // Array-valued content is unsupported in v13a-3 → nil (→ 400).
        let arrayContent = Data(#"{"model":"x","messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}"#.utf8)
        #expect(OpenAIChatHandler.decodeRequest(arrayContent) == nil)

        // Garbage → nil.
        #expect(OpenAIChatHandler.decodeRequest(Data("not json".utf8)) == nil)
    }

    // MARK: - preset fallback (provider name → auto)

    @Test("a non-ModelPreset stored preset (provider name) falls back to auto")
    func presetFallbackToAuto() {
        #expect(OpenAIChatHandler.preset(forRecordPreset: "openai") == .auto)
        #expect(OpenAIChatHandler.preset(forRecordPreset: "anthropic") == .auto)
        #expect(OpenAIChatHandler.preset(forRecordPreset: "QUICK") == .quick)
        #expect(OpenAIChatHandler.preset(forRecordPreset: "build") == .build)
    }

    // MARK: - body framing helpers

    @Test("listener body framing splits head/body and detects completeness")
    func bodyFraming() {
        let full = Data("POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello".utf8)
        #expect(OpenAIListener.requestComplete(full) == true)
        #expect(String(decoding: OpenAIListener.bodyBytes(full), as: UTF8.self) == "hello")

        // Head present but body short of Content-Length → not complete.
        let partial = Data("POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 10\r\n\r\nhel".utf8)
        #expect(OpenAIListener.requestComplete(partial) == false)

        // No header boundary yet → not complete, empty body.
        let headOnly = Data("POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 5".utf8)
        #expect(OpenAIListener.requestComplete(headOnly) == false)
        #expect(OpenAIListener.bodyBytes(headOnly).isEmpty)
    }

    // MARK: - live listener round-trip (Network)

    #if canImport(Network)
    @Test("live listener serves a chat.completion for an authorized POST")
    func liveChatRoundTrip() throws {
        let key = "sk-senkani-livechat"
        let record = OpenAIKeyRecord(
            keyHash: OpenAIAuthGate.hash(key),
            preset: "quick", scope: ["chat"], rateLimit: 60,
            createdAt: Date(), expiresAt: nil, label: "live"
        )
        let limiter = OpenAIRateLimiter()
        let authenticator = OpenAIListener.Authenticator { _, path, headers in
            OpenAIAuthGate.decide(
                authorizationHeader: headers["authorization"],
                requestedSurface: OpenAIAuthGate.surface(forPath: path),
                now: Date(), records: [record], rateLimiter: limiter
            )
        }
        let chain = OpenAIAuditChain()
        let engine = Self.stubEngine(content: "live ok")
        let chatHandler = OpenAIListener.ChatHandler { _, _, headers, body in
            guard let request = OpenAIChatHandler.decodeRequest(body) else { return nil }
            let token = OpenAIAuthGate.bearerToken(fromHeader: headers["authorization"])
            let rec = token.flatMap { OpenAIAuthGate.matchRecord(presentedKey: $0, records: [record]) }
            let result = OpenAIChatHandler.handle(
                request: request, recordPreset: rec?.preset ?? "auto",
                keyLabel: rec?.label, engine: engine, now: Date(), id: "chatcmpl-live"
            )
            chain.append(result.auditFields, bodies: nil)
            return OpenAIChatHandler.encodeResponse(result.response)
        }

        let listener = OpenAIListener(
            config: .init(bind: "127.0.0.1", port: 0),
            authenticator: authenticator, chatHandler: chatHandler
        )
        try listener.start()
        defer { listener.stop() }
        let port = listener.port
        #expect(port > 0)

        let bodyJSON = #"{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}"#
        let requestText =
            "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            + "Authorization: Bearer \(key)\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(bodyJSON.utf8.count)\r\n"
            + "Connection: close\r\n\r\n\(bodyJSON)"
        let request = Data(requestText.utf8)
        let fd = try #require(connectToLocalhost(port: port))
        defer { close(fd) }
        #expect(writeAllToFD(fd, request))
        shutdown(fd, Int32(SHUT_WR))
        let response = String(decoding: readAllUntilEOF(fd), as: UTF8.self)

        #expect(response.hasPrefix("HTTP/1.1 200 OK"))
        #expect(response.contains("\"object\":\"chat.completion\""))
        #expect(response.contains("\"content\":\"live ok\""))
        // Response model is the actual (Quick→Haiku) model, not gpt-4o.
        #expect(response.contains(ModelTier.quick.claudeModelValue))
        // Exactly one audit entry, and it verifies.
        #expect(chain.count == 1)
        #expect(chain.verify() == .ok(count: 1))
    }
    #endif
}
