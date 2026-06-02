import Testing
import Foundation
import SQLite3
@testable import Core

/// V.13b prompt-caching A — wire-side cache_control + opt-in flag tests
/// (Lauret P0 sum-type round-trip; Lauret P0 header-IFF-body; Lauret P0
/// chat()/chatStream() symmetry; Schneier P1 default-OFF privacy posture;
/// Schneier P2 once-per-process beta-deprecation warning; .some(0)
/// pass-through to writer normalize).
///
/// Test register (≥4 required by spec):
///
///   1. Wire-shape opt-in OFF (back-compat) — chat() AND chatStream() emit
///      the legacy bare-string `system: "..."` form, NO anthropic-beta
///      header.
///   2. Wire-shape opt-in ON — chat() AND chatStream() emit the typed-
///      block array form WITH cache_control:{type:"ephemeral"} AND the
///      anthropic-beta header is set.
///   3. Response decode WITH cache_* fields — Completion fields populated;
///      writer-side .some(0) → nil normalize on persisted row.
///   4. Response decode WITHOUT cache_* fields — Completion fields nil;
///      once-per-process stderr warning flag flips.
///
/// Plus a sum-type round-trip canary for AnthropicSystem (Lauret P0 — JSON
/// `"hi"` ↔ `.legacy("hi")`; JSON `[...]` ↔ `.blocks([...])`).

// MARK: - Mock helpers (mirrors the pattern in ClaudeAPIChatEngineTests.swift)

private let promptCachingAnthropicURL = URL(string: "https://api.anthropic.com/v1/messages")!

private func makePromptCachingEngine(apiKey: String = "ak-pc-test") -> ClaudeAPIChatEngine {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: config)
    return ClaudeAPIChatEngine(
        apiKey: apiKey,
        session: session,
        endpoint: promptCachingAnthropicURL,
        sleeper: { _ in }
    )
}

private func makePromptCachingStreamingEngine(apiKey: String = "ak-pc-stream-test") -> ClaudeAPIChatEngine {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockSSEStreamProtocol.self]
    let session = URLSession(configuration: config)
    return ClaudeAPIChatEngine(
        apiKey: apiKey,
        session: session,
        endpoint: promptCachingAnthropicURL,
        sleeper: { _ in },
        requestTimeout: 5.0
    )
}

private func capturedChatBody() -> String {
    guard let req = MockURLProtocol.lastRequest else { return "" }
    if let body = req.httpBody { return String(data: body, encoding: .utf8) ?? "" }
    guard let stream = req.httpBodyStream else { return "" }
    stream.open(); defer { stream.close() }
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let n = stream.read(&buf, maxLength: buf.count)
        if n <= 0 { break }
        out.append(buf, count: n)
    }
    return String(data: out, encoding: .utf8) ?? ""
}

private func capturedStreamBody() -> String {
    guard let req = MockSSEStreamProtocol.lastRequest else { return "" }
    if let body = req.httpBody { return String(data: body, encoding: .utf8) ?? "" }
    guard let stream = req.httpBodyStream else { return "" }
    stream.open(); defer { stream.close() }
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let n = stream.read(&buf, maxLength: buf.count)
        if n <= 0 { break }
        out.append(buf, count: n)
    }
    return String(data: out, encoding: .utf8) ?? ""
}

/// Minimal SSE body that drives chatStream() to completion without yielding
/// any cache_* metadata. Used by the opt-in OFF / ON wire-shape tests.
private let minimalSSE = """
event: message_start
data: {"type":"message_start","message":{"id":"msg_pc","usage":{"input_tokens":2}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}

event: message_stop
data: {"type":"message_stop"}


"""

// MARK: - Sum-type round-trip canary (Lauret P0)

@Suite("AnthropicSystem — sum-type wire round-trip (Lauret P0)", .serialized)
struct AnthropicSystemRoundTripTests {

    @Test func legacyVariantEncodesAsBareJSONString() throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(AnthropicSystem.legacy("hi"))
        let s = String(data: data, encoding: .utf8) ?? ""
        // BARE JSON STRING — no object wrapper, no array wrapper.
        #expect(s == "\"hi\"")
    }

    @Test func legacyVariantDecodesFromBareJSONString() throws {
        let data = Data("\"hello world\"".utf8)
        let decoded = try JSONDecoder().decode(AnthropicSystem.self, from: data)
        #expect(decoded == .legacy("hello world"))
    }

    @Test func blocksVariantEncodesAsJSONArray() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let blocks = AnthropicSystem.blocks([
            AnthropicSystemBlock(type: "text", text: "ctx", cache_control: CacheControl(type: "ephemeral"))
        ])
        let data = try encoder.encode(blocks)
        let s = String(data: data, encoding: .utf8) ?? ""
        #expect(s == "[{\"cache_control\":{\"type\":\"ephemeral\"},\"text\":\"ctx\",\"type\":\"text\"}]")
    }

    @Test func blocksVariantDecodesFromJSONArray() throws {
        let json = "[{\"type\":\"text\",\"text\":\"ctx\",\"cache_control\":{\"type\":\"ephemeral\"}}]"
        let decoded = try JSONDecoder().decode(AnthropicSystem.self, from: Data(json.utf8))
        #expect(decoded == .blocks([
            AnthropicSystemBlock(type: "text", text: "ctx", cache_control: CacheControl(type: "ephemeral"))
        ]))
    }
}

// MARK: - chat() wire-shape — opt-in OFF (back-compat) + ON

@Suite("ClaudeAPIChatEngine — prompt-caching wire shape (chat)", .serialized, .urlProtocolGate)
struct ClaudeAPIChatEnginePromptCachingChatWireTests {

    @Test func optInOffEmitsLegacyBareStringSystemAndOmitsBetaHeader() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let body = """
        {"id":"x","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
        """
        MockURLProtocol.register(url: promptCachingAnthropicURL, status: 200, body: Data(body.utf8))

        let engine = makePromptCachingEngine()
        _ = try await engine.chat(
            model: "claude-haiku-3.5",
            messages: [
                .init(role: "system", content: "be concise"),
                .init(role: "user", content: "hi"),
            ],
            tools: [],
            cacheControl: nil   // explicit default-OFF
        )

        // Wire body — bare-string `system` form, byte-identical with pre-
        // prompt-caching wire.
        let bodyStr = capturedChatBody()
        #expect(bodyStr.contains("\"system\":\"be concise\""))
        // Defensive: the typed-block array form must NOT appear.
        #expect(!bodyStr.contains("\"cache_control\""))
        #expect(!bodyStr.contains("\"system\":["))

        // anthropic-beta header MUST be absent.
        let req = MockURLProtocol.lastRequest
        #expect(req?.value(forHTTPHeaderField: "anthropic-beta") == nil)
    }

    @Test func optInEphemeralEmitsTypedBlockSystemAndSetsBetaHeader() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let body = """
        {"id":"x","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":512,"cache_read_input_tokens":0}}
        """
        MockURLProtocol.register(url: promptCachingAnthropicURL, status: 200, body: Data(body.utf8))

        let engine = makePromptCachingEngine()
        _ = try await engine.chat(
            model: "claude-haiku-3.5",
            messages: [
                .init(role: "system", content: "project-instructions"),
                .init(role: "user", content: "hi"),
            ],
            tools: [],
            cacheControl: .ephemeral
        )

        // Wire body — typed-block array `system` form with cache_control.
        let bodyStr = capturedChatBody()
        #expect(bodyStr.contains("\"system\":["))
        #expect(bodyStr.contains("\"cache_control\":{\"type\":\"ephemeral\"}"))
        #expect(bodyStr.contains("\"text\":\"project-instructions\""))
        #expect(bodyStr.contains("\"type\":\"text\""))
        // Defensive: bare-string form must NOT appear in this wire body.
        #expect(!bodyStr.contains("\"system\":\"project-instructions\""))

        // anthropic-beta header MUST be present, pinned to the constant.
        let req = MockURLProtocol.lastRequest
        #expect(req?.value(forHTTPHeaderField: "anthropic-beta") == ClaudeAPIChatEngine.promptCachingBetaHeader)
        #expect(req?.value(forHTTPHeaderField: "anthropic-beta") == "prompt-caching-2024-07-31")
    }
}

// MARK: - chatStream() wire-shape — symmetry with chat() (Lauret P0)

@Suite("ClaudeAPIChatEngine — prompt-caching wire shape (chatStream)", .serialized, .urlProtocolGate)
struct ClaudeAPIChatEnginePromptCachingStreamWireTests {

    @Test func chatStreamOptInOffEmitsLegacyBareStringAndOmitsBetaHeader() async throws {
        MockSSEStreamProtocol.reset(); defer { MockSSEStreamProtocol.reset() }
        MockSSEStreamProtocol.register(url: promptCachingAnthropicURL, chunks: [Data(minimalSSE.utf8)])

        let engine = makePromptCachingStreamingEngine()
        let stream = engine.chatStream(
            model: "claude-haiku-3.5",
            messages: [
                .init(role: "system", content: "be concise"),
                .init(role: "user", content: "yo"),
            ],
            tools: [],
            cacheControl: nil   // explicit default-OFF
        )
        for try await _ in stream { /* drain */ }

        let bodyStr = capturedStreamBody()
        #expect(bodyStr.contains("\"system\":\"be concise\""))
        #expect(!bodyStr.contains("\"cache_control\""))
        #expect(!bodyStr.contains("\"system\":["))

        let req = MockSSEStreamProtocol.lastRequest
        #expect(req?.value(forHTTPHeaderField: "anthropic-beta") == nil)
    }

    @Test func chatStreamOptInEphemeralEmitsTypedBlockAndSetsBetaHeader() async throws {
        MockSSEStreamProtocol.reset(); defer { MockSSEStreamProtocol.reset() }
        MockSSEStreamProtocol.register(url: promptCachingAnthropicURL, chunks: [Data(minimalSSE.utf8)])

        let engine = makePromptCachingStreamingEngine()
        let stream = engine.chatStream(
            model: "claude-haiku-3.5",
            messages: [
                .init(role: "system", content: "project-instructions"),
                .init(role: "user", content: "yo"),
            ],
            tools: [],
            cacheControl: .ephemeral
        )
        for try await _ in stream { /* drain */ }

        let bodyStr = capturedStreamBody()
        #expect(bodyStr.contains("\"system\":["))
        #expect(bodyStr.contains("\"cache_control\":{\"type\":\"ephemeral\"}"))
        #expect(bodyStr.contains("\"text\":\"project-instructions\""))
        #expect(!bodyStr.contains("\"system\":\"project-instructions\""))

        let req = MockSSEStreamProtocol.lastRequest
        #expect(req?.value(forHTTPHeaderField: "anthropic-beta") == ClaudeAPIChatEngine.promptCachingBetaHeader)
    }
}

// MARK: - Response decode — Completion fields populated + writer normalize

@Suite("ClaudeAPIChatEngine — prompt-caching response decode + writer pass-through", .serialized, .urlProtocolGate)
struct ClaudeAPIChatEnginePromptCachingResponseTests {

    private static func tempDBPath() -> String {
        let dir = NSTemporaryDirectory() + "senkani-v13b-prompt-caching-a-tests/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "openai-request-log-prompt-caching-a-\(UUID().uuidString).db"
    }

    @Test func decodedCacheTokensPopulateCompletionAndWriterNormalizesZeroToNil() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let body = """
        {"id":"x","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":1024,"cache_read_input_tokens":0}}
        """
        MockURLProtocol.register(url: promptCachingAnthropicURL, status: 200, body: Data(body.utf8))

        let engine = makePromptCachingEngine()
        let completion = try await engine.chat(
            model: "claude-haiku-3.5",
            messages: [
                .init(role: "system", content: "project"),
                .init(role: "user", content: "hi"),
            ],
            tools: [],
            cacheControl: .ephemeral
        )

        // Completion-side: engine populates BOTH cache fields, including the
        // .some(0) — the engine MUST NOT pre-normalize (Schneier P1: the
        // normalize lives at the writer trust boundary, not the engine).
        #expect(completion.realCacheCreationTokens == 1024)
        #expect(completion.realCacheReadTokens == 0)

        // Writer-side: persisted row has 1024 for cache_creation_input_tokens
        // and nil for cache_read_input_tokens (writer collapsed .some(0) → nil).
        let path = Self.tempDBPath()
        defer { TempSessionDatabase.cleanup(path: path) }
        let db = SessionDatabase(path: path)
        defer { db.close() }
        #expect(db.recordOpenAIRequest(
            ts: Date(timeIntervalSince1970: 1_900_200_000),
            surface: .chat, status: 200,
            keyLabel: "k", modelLogged: "claude-haiku-3.5", resolvedTier: "cloud",
            inputTokens: 10, outputTokens: 5, upstreamResponseId: "req_a_1",
            cacheCreationInputTokens: completion.realCacheCreationTokens,
            cacheReadInputTokens: completion.realCacheReadTokens
        ))

        let rows = db.recentOpenAIRequests(limit: 1)
        guard let row = rows.first else {
            Issue.record("expected one persisted row"); return
        }
        #expect(row.cacheCreationInputTokens == 1024)
        #expect(row.cacheReadInputTokens == nil, "writer must normalize .some(0) → nil at the trust boundary")
    }

    @Test func responseWithoutCacheFieldsLeavesCompletionNilAndFiresWarning() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        // Reset the once-per-process warning flag so this test deterministically
        // observes the flag flip on this run, regardless of test ordering.
        ClaudeAPIChatEngine.resetCacheTokenAbsenceWarningForTesting()
        defer { ClaudeAPIChatEngine.resetCacheTokenAbsenceWarningForTesting() }

        let body = """
        {"id":"x","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":5}}
        """
        MockURLProtocol.register(url: promptCachingAnthropicURL, status: 200, body: Data(body.utf8))

        // Sanity precondition: warning has not yet fired.
        #expect(ClaudeAPIChatEngine.hasWarnedAboutCacheTokenAbsenceForTesting() == false)

        let engine = makePromptCachingEngine()
        let completion = try await engine.chat(
            model: "claude-haiku-3.5",
            messages: [
                .init(role: "system", content: "project"),
                .init(role: "user", content: "hi"),
            ],
            tools: [],
            cacheControl: .ephemeral
        )

        #expect(completion.realCacheCreationTokens == nil)
        #expect(completion.realCacheReadTokens == nil)

        // Schneier P2: once-per-process warning flag flipped exactly once.
        #expect(ClaudeAPIChatEngine.hasWarnedAboutCacheTokenAbsenceForTesting() == true)

        // Persisted row carries NULL in both cache columns.
        let path = Self.tempDBPath()
        defer { TempSessionDatabase.cleanup(path: path) }
        let db = SessionDatabase(path: path)
        defer { db.close() }
        #expect(db.recordOpenAIRequest(
            ts: Date(timeIntervalSince1970: 1_900_200_001),
            surface: .chat, status: 200,
            keyLabel: "k", modelLogged: "claude-haiku-3.5", resolvedTier: "cloud",
            inputTokens: 10, outputTokens: 5, upstreamResponseId: "req_a_2",
            cacheCreationInputTokens: completion.realCacheCreationTokens,
            cacheReadInputTokens: completion.realCacheReadTokens
        ))
        let rows = db.recentOpenAIRequests(limit: 1)
        guard let row = rows.first else {
            Issue.record("expected one persisted row"); return
        }
        #expect(row.cacheCreationInputTokens == nil)
        #expect(row.cacheReadInputTokens == nil)
    }

    @Test func warningFiresOnlyOncePerProcessLifetime() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        ClaudeAPIChatEngine.resetCacheTokenAbsenceWarningForTesting()
        defer { ClaudeAPIChatEngine.resetCacheTokenAbsenceWarningForTesting() }

        let body = """
        {"id":"x","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
        """
        MockURLProtocol.register(url: promptCachingAnthropicURL, status: 200, body: Data(body.utf8))

        let engine = makePromptCachingEngine()

        // First call flips the flag.
        _ = try await engine.chat(
            model: "claude-haiku-3.5",
            messages: [.init(role: "user", content: "hi")],
            tools: [],
            cacheControl: .ephemeral
        )
        #expect(ClaudeAPIChatEngine.hasWarnedAboutCacheTokenAbsenceForTesting() == true)

        // Second call sees the flag already set and is a no-op for the
        // warning side — verified by the helper's once-per-process guard.
        // (We can't observe "did NOT print to stderr" structurally here,
        // but the lock-guarded helper has only one branch that prints, and
        // it short-circuits when the flag is already true.)
        _ = try await engine.chat(
            model: "claude-haiku-3.5",
            messages: [.init(role: "user", content: "hi again")],
            tools: [],
            cacheControl: .ephemeral
        )
        #expect(ClaudeAPIChatEngine.hasWarnedAboutCacheTokenAbsenceForTesting() == true)
    }

    @Test func optInOffDoesNotFireWarningEvenWhenResponseLacksCacheFields() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        ClaudeAPIChatEngine.resetCacheTokenAbsenceWarningForTesting()
        defer { ClaudeAPIChatEngine.resetCacheTokenAbsenceWarningForTesting() }

        let body = """
        {"id":"x","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
        """
        MockURLProtocol.register(url: promptCachingAnthropicURL, status: 200, body: Data(body.utf8))

        let engine = makePromptCachingEngine()
        _ = try await engine.chat(
            model: "claude-haiku-3.5",
            messages: [.init(role: "user", content: "hi")],
            tools: [],
            cacheControl: nil   // opt-in OFF
        )

        // Schneier P2: warning is gated on the OPT-IN side. If the operator
        // never opted in, an absent cache_* field carries no information.
        #expect(ClaudeAPIChatEngine.hasWarnedAboutCacheTokenAbsenceForTesting() == false)
    }
}
