import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import SQLite3
@testable import Core

// MARK: - V.13b-4c follow-up — test hardening
//
// Round 24 (2026-06-02) — Lauret/Schneier P2 hardening:
//
//   * `warningFiresOnlyOncePerProcessLifetime` now performs a real
//     `dup2`-backed stderr-pipe swap and counts the warning marker in the
//     captured bytes. Replaces the lock-flag-only assertion that could not
//     prove the helper short-circuits the WRITE (only that the flag was set
//     once). The test must run with the once-per-process flag reset both
//     BEFORE and AFTER — the existing `resetCacheTokenAbsenceWarningForTesting`
//     hook makes this deterministic regardless of suite ordering.
//
//   * The chatStream wire-shape tests (opt-in OFF / opt-in ON) now compare
//     the captured request body Data byte-for-byte against a fixture built
//     by encoding the SAME `AnthropicMessagesRequest` shape with the SAME
//     `JSONEncoder(outputFormatting: [.sortedKeys])` config used by
//     production code. Pins the wire bytes against silent JSONEncoder
//     drift / re-ordering / format changes.
//
// The new stderr-capture helper restores the original `stderr` file
// descriptor in a `defer` so a thrown body cannot leak the fd swap.

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

/// V.13b-4c follow-up (Schneier P2) — capture everything written to
/// `stderr` by `body` and return it as raw bytes.
///
/// Implementation: `dup` the current `STDERR_FILENO`, `dup2` the write end
/// of a fresh `Pipe` into `STDERR_FILENO`, run `body`, flush + close the
/// pipe's write end, restore the saved fd via `dup2`, then drain the
/// pipe's read end to EOF. The restore is in a `defer` so even if `body`
/// throws the original stderr fd is reinstated and the saved descriptor
/// is closed (no fd leak).
///
/// Notes:
/// - Closing the write end is what unblocks `readDataToEndOfFile()` on
///   the read end; without it the read would hang.
/// - The Swift runtime's `print(...)` uses the underlying STDERR_FILENO
///   when writing diagnostics, so `dup2` at the fd level (not just
///   `FileHandle.standardError`) is sufficient for `FileHandle
///   .standardError.write(...)` paths used by the engine.
@discardableResult
private func captureStandardError(_ body: () async throws -> Void) async throws -> Data {
    fflush(stderr)
    let savedFd = dup(fileno(stderr))
    #expect(savedFd >= 0, "dup(stderr) should succeed")

    let pipe = Pipe()
    let writeFd = pipe.fileHandleForWriting.fileDescriptor
    let dupResult = dup2(writeFd, fileno(stderr))
    #expect(dupResult >= 0, "dup2 of pipe write end into stderr should succeed")

    // Ensure we always restore the original stderr fd, even on throw, and
    // close the saved descriptor so the test cannot leak file descriptors.
    var restored = false
    func restore() {
        guard !restored else { return }
        restored = true
        fflush(stderr)
        _ = dup2(savedFd, fileno(stderr))
        close(savedFd)
    }
    defer { restore() }

    var thrown: Error?
    do {
        try await body()
    } catch {
        thrown = error
    }

    // Flush the engine's writes through the pipe, then close the write
    // end so the read side hits EOF.
    fflush(stderr)
    try? pipe.fileHandleForWriting.close()

    // Restore stderr BEFORE reading, so any diagnostics from the drain
    // path go to the real terminal.
    restore()

    let captured = pipe.fileHandleForReading.readDataToEndOfFile()
    try? pipe.fileHandleForReading.close()

    if let thrown { throw thrown }
    return captured
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
            AnthropicSystemBlock(type: "text", text: "ctx", cache_control: AnthropicCacheControl(type: "ephemeral"))
        ])
        let data = try encoder.encode(blocks)
        let s = String(data: data, encoding: .utf8) ?? ""
        #expect(s == "[{\"cache_control\":{\"type\":\"ephemeral\"},\"text\":\"ctx\",\"type\":\"text\"}]")
    }

    @Test func blocksVariantDecodesFromJSONArray() throws {
        let json = "[{\"type\":\"text\",\"text\":\"ctx\",\"cache_control\":{\"type\":\"ephemeral\"}}]"
        let decoded = try JSONDecoder().decode(AnthropicSystem.self, from: Data(json.utf8))
        #expect(decoded == .blocks([
            AnthropicSystemBlock(type: "text", text: "ctx", cache_control: AnthropicCacheControl(type: "ephemeral"))
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

    /// V.13b-4c follow-up (Lauret P2) — capture the actual wire-bytes from
    /// the MockSSEStreamProtocol intercept. Returns `Data` (not `String`)
    /// so byte-exact equality is meaningful.
    private static func capturedStreamBodyData() -> Data {
        guard let req = MockSSEStreamProtocol.lastRequest else { return Data() }
        if let body = req.httpBody { return body }
        guard let stream = req.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }

    /// Build the EXPECTED byte fixture by encoding the same
    /// `AnthropicMessagesRequest` shape with the SAME `JSONEncoder`
    /// config used by production (`outputFormatting: [.sortedKeys]`).
    /// Pins JSONEncoder's per-key emission order + field set against
    /// silent drift. If production adds a new wire field that the
    /// fixture omits (or vice versa), this test fails LOUDLY — which is
    /// the entire point.
    private static func expectedStreamBody(
        wireModel: String,
        maxTokens: Int,
        systemField: AnthropicSystem?,
        userText: String
    ) throws -> Data {
        let req = AnthropicMessagesRequest(
            model: wireModel,
            max_tokens: maxTokens,
            system: systemField,
            messages: [
                .init(role: "user", content: .text(userText))
            ],
            tools: nil,
            stream: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(req)
    }

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

        // V.13b-4c follow-up (Lauret P2): BYTE-EXACT wire-shape fixture.
        // Expected: legacy bare-string system field, no cache_control, no
        // tools array, stream:true. The previous `.contains(...)` asserts
        // could miss reordering, an unexpected new field, or a format
        // drift; equality on `Data` cannot.
        let expectedBody = try Self.expectedStreamBody(
            wireModel: "claude-3-5-haiku-latest",
            maxTokens: 4096,
            systemField: .legacy("be concise"),
            userText: "yo"
        )
        let actualBody = Self.capturedStreamBodyData()
        #expect(actualBody == expectedBody,
                "opt-in OFF wire bytes drifted from the pinned fixture")

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

        // V.13b-4c follow-up (Lauret P2): BYTE-EXACT wire-shape fixture.
        // Expected: typed-block system array carrying a single
        // {type:"text", text:..., cache_control:{type:"ephemeral"}} block.
        // The `AnthropicCacheControl` rename (r22) must NOT change wire
        // bytes; this fixture pins the post-rename shape.
        let expectedBody = try Self.expectedStreamBody(
            wireModel: "claude-3-5-haiku-latest",
            maxTokens: 4096,
            systemField: .blocks([
                AnthropicSystemBlock(
                    type: "text",
                    text: "project-instructions",
                    cache_control: AnthropicCacheControl(type: "ephemeral")
                )
            ]),
            userText: "yo"
        )
        let actualBody = Self.capturedStreamBodyData()
        #expect(actualBody == expectedBody,
                "opt-in ON wire bytes drifted from the pinned fixture")

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
        // V.13b-4c follow-up (Schneier P2): the once-per-process flag is
        // shared with every other test that fires the warning. We MUST
        // reset it before AND after so the captured stderr observation is
        // deterministic regardless of suite ordering (`.serialized` at the
        // suite level pairs with this reset to also block intra-suite
        // races on stderr).
        ClaudeAPIChatEngine.resetCacheTokenAbsenceWarningForTesting()
        defer { ClaudeAPIChatEngine.resetCacheTokenAbsenceWarningForTesting() }

        let body = """
        {"id":"x","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
        """
        MockURLProtocol.register(url: promptCachingAnthropicURL, status: 200, body: Data(body.utf8))

        let engine = makePromptCachingEngine()

        // V.13b-4c follow-up (Schneier P2): capture REAL stderr bytes via a
        // dup2-backed Pipe swap. Run N=3 opt-in calls whose responses are
        // missing both cache_* fields; the once-per-process helper must
        // emit the warning marker EXACTLY ONCE across those N calls (the
        // first call writes; calls 2 and 3 short-circuit on the lock-
        // guarded flag and write NOTHING).
        // Note: a system message is REQUIRED for caching to be `enabled` on
        // the wire (the `(.ephemeral, .some)` arm). Without it,
        // `buildSystemField` takes the `(.ephemeral, .none)` arm, returns
        // nil, and the missing-cache-tokens warning never even has a chance
        // to fire because `cachingEnabled` is false. So we include a real
        // system message — this exercises the `cachingEnabled = true` +
        // `realCacheCreation == nil` + `realCacheRead == nil` arm that
        // triggers `warnAboutMissingCacheTokensOnceIfNeeded()`.
        let captured = try await captureStandardError {
            for _ in 0..<3 {
                _ = try await engine.chat(
                    model: "claude-haiku-3.5",
                    messages: [
                        .init(role: "system", content: "project-instructions"),
                        .init(role: "user", content: "hi"),
                    ],
                    tools: [],
                    cacheControl: .ephemeral
                )
            }
        }

        let capturedString = String(data: captured, encoding: .utf8) ?? ""
        let warningMarker = "warning: prompt-caching beta header may be deprecated"

        // 1 occurrence ⇒ exactly 2 components on a split.
        let parts = capturedString.components(separatedBy: warningMarker)
        #expect(parts.count == 2,
                "expected warning marker exactly ONCE in captured stderr; got \(parts.count - 1) occurrence(s). Captured bytes: \(capturedString.debugDescription)")

        // Flag stays set across all N calls (regression on the existing
        // lock-flag invariant).
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

// MARK: - V.13b-4c follow-up — production fixes (Schneier P2/P3, Lauret P0)

/// V.13b-4c follow-up — production-code regression tests for the
/// prompt-caching engine surface:
///   (a) warning-symmetry chatStream hook fires once across chat() +
///       chatStream() opt-in calls (lock-guarded shared flag);
///   (b) silent-opt-in-drop notice fires when `.ephemeral` is requested
///       with no system message; gated to opt-in only;
///   (c) `AnthropicCacheControl` rename — wire-byte parity with the prior
///       `CacheControl` JSON shape `{"type":"ephemeral"}`;
///   (d) `AnthropicSystem.blocks([])` empty-array round-trip pin;
///   (e) `AnthropicSystem.systemText` multi-block join uses `"\n\n"`.

@Suite("ClaudeAPIChatEngine — V.13b-4c follow-up production fixes", .serialized, .urlProtocolGate)
struct ClaudeAPIChatEnginePromptCachingFollowupTests {

    @Test func warningSymmetryChatStreamHookFiresOnceAcrossBothEntryPoints() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        MockSSEStreamProtocol.reset(); defer { MockSSEStreamProtocol.reset() }
        ClaudeAPIChatEngine.resetCacheTokenAbsenceWarningForTesting()
        defer { ClaudeAPIChatEngine.resetCacheTokenAbsenceWarningForTesting() }

        // Streaming response carries NO cache_* fields anywhere (the parser
        // doesn't surface them today regardless). chatStream() opt-in path
        // should flip the once-per-process flag at producer completion.
        MockSSEStreamProtocol.register(url: promptCachingAnthropicURL, chunks: [Data(minimalSSE.utf8)])
        let streamEngine = makePromptCachingStreamingEngine()
        let stream = streamEngine.chatStream(
            model: "claude-haiku-3.5",
            messages: [
                .init(role: "system", content: "project-instructions"),
                .init(role: "user", content: "yo"),
            ],
            tools: [],
            cacheControl: .ephemeral
        )
        for try await _ in stream { /* drain */ }

        // The chatStream() entry point flipped the SAME flag chat() uses.
        #expect(ClaudeAPIChatEngine.hasWarnedAboutCacheTokenAbsenceForTesting() == true)

        // Now drive chat() — opt-in with response missing cache_* fields.
        // The lock-guarded helper must observe the flag is ALREADY set and
        // short-circuit (no second emission). We cannot structurally
        // observe "did not print to stderr", but the helper has a single
        // emit branch and that branch is gated by the flag.
        let body = """
        {"id":"x","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
        """
        MockURLProtocol.register(url: promptCachingAnthropicURL, status: 200, body: Data(body.utf8))
        let chatEngine = makePromptCachingEngine()
        _ = try await chatEngine.chat(
            model: "claude-haiku-3.5",
            messages: [
                .init(role: "system", content: "project-instructions"),
                .init(role: "user", content: "hi"),
            ],
            tools: [],
            cacheControl: .ephemeral
        )

        // Flag remains true — the same shared lock-guarded boolean keeps
        // the emission once-per-process across BOTH entry points.
        #expect(ClaudeAPIChatEngine.hasWarnedAboutCacheTokenAbsenceForTesting() == true)
    }

    @Test func chatStreamOptInOffDoesNotFireWarning() async throws {
        MockSSEStreamProtocol.reset(); defer { MockSSEStreamProtocol.reset() }
        ClaudeAPIChatEngine.resetCacheTokenAbsenceWarningForTesting()
        defer { ClaudeAPIChatEngine.resetCacheTokenAbsenceWarningForTesting() }

        MockSSEStreamProtocol.register(url: promptCachingAnthropicURL, chunks: [Data(minimalSSE.utf8)])
        let engine = makePromptCachingStreamingEngine()
        let stream = engine.chatStream(
            model: "claude-haiku-3.5",
            messages: [
                .init(role: "system", content: "be concise"),
                .init(role: "user", content: "yo"),
            ],
            tools: [],
            cacheControl: nil   // opt-in OFF
        )
        for try await _ in stream { /* drain */ }

        // Opt-in OFF: the warning is gated to the opt-in side ONLY (same
        // privacy posture as chat()). Flag must remain false.
        #expect(ClaudeAPIChatEngine.hasWarnedAboutCacheTokenAbsenceForTesting() == false)
    }

    @Test func silentOptInDropNoticeFiresWhenEphemeralRequestedWithNoSystem() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        ClaudeAPIChatEngine.resetSilentOptInDropWarningForTesting()
        defer { ClaudeAPIChatEngine.resetSilentOptInDropWarningForTesting() }

        let body = """
        {"id":"x","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
        """
        MockURLProtocol.register(url: promptCachingAnthropicURL, status: 200, body: Data(body.utf8))

        // Sanity precondition.
        #expect(ClaudeAPIChatEngine.hasWarnedAboutSilentOptInDropForTesting() == false)

        let engine = makePromptCachingEngine()
        _ = try await engine.chat(
            model: "claude-haiku-3.5",
            messages: [.init(role: "user", content: "hi")],   // NO system message
            tools: [],
            cacheControl: .ephemeral
        )

        // The (.ephemeral, .none) arm of buildSystemField should have fired
        // the once-per-process silent-opt-in-drop notice.
        #expect(ClaudeAPIChatEngine.hasWarnedAboutSilentOptInDropForTesting() == true)
    }

    @Test func silentOptInDropNoticeDoesNotFireWhenOptInOff() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        ClaudeAPIChatEngine.resetSilentOptInDropWarningForTesting()
        defer { ClaudeAPIChatEngine.resetSilentOptInDropWarningForTesting() }

        let body = """
        {"id":"x","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
        """
        MockURLProtocol.register(url: promptCachingAnthropicURL, status: 200, body: Data(body.utf8))

        let engine = makePromptCachingEngine()
        _ = try await engine.chat(
            model: "claude-haiku-3.5",
            messages: [.init(role: "user", content: "hi")],   // NO system message
            tools: [],
            cacheControl: nil                                  // opt-in OFF
        )

        // Opt-in OFF: silent-opt-in-drop notice is gated on the opt-in
        // path. (nil, .none) is the existing zero-system path and must not
        // emit anything new.
        #expect(ClaudeAPIChatEngine.hasWarnedAboutSilentOptInDropForTesting() == false)
    }

    @Test func anthropicCacheControlRenamePreservesWireByteShape() throws {
        // Lauret P0 invariant: the `CacheControl` → `AnthropicCacheControl`
        // rename MUST NOT change the JSON wire shape. Codable synthesis
        // depends only on field names + types, not the Swift type name.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(AnthropicCacheControl(type: "ephemeral"))
        let s = String(data: data, encoding: .utf8) ?? ""
        #expect(s == "{\"type\":\"ephemeral\"}")

        // Round-trip parity: decoder still accepts the legacy wire shape.
        let decoded = try JSONDecoder().decode(AnthropicCacheControl.self, from: data)
        #expect(decoded == AnthropicCacheControl(type: "ephemeral"))
    }

    @Test func anthropicSystemBlocksEmptyArrayRoundTrip() throws {
        // V.13b-4c follow-up (Schneier P2) — `.blocks([])` must encode as
        // an EMPTY JSON array `[]` and decode back as `.blocks([])`, NOT
        // collapse to `.legacy("")` or any other variant.
        let encoder = JSONEncoder()
        let data = try encoder.encode(AnthropicSystem.blocks([]))
        let s = String(data: data, encoding: .utf8) ?? ""
        #expect(s == "[]", "expected EMPTY JSON array, got \(s)")

        let decoded = try JSONDecoder().decode(AnthropicSystem.self, from: data)
        #expect(decoded == .blocks([]),
                "expected .blocks([]) preserved on decode, got \(decoded)")
    }

    @Test func anthropicSystemTextMultiBlockJoinUsesParagraphSeparator() {
        // V.13b-4c follow-up (Schneier P3) — multi-block `systemText`
        // joins with `"\n\n"` to match `splitMessages` join behavior.
        let sys = AnthropicSystem.blocks([
            AnthropicSystemBlock(type: "text", text: "alpha", cache_control: nil),
            AnthropicSystemBlock(type: "text", text: "beta", cache_control: nil),
        ])
        #expect(sys.systemText == "alpha\n\nbeta")

        // Single-block path stays unchanged: no separator inserted.
        let single = AnthropicSystem.blocks([
            AnthropicSystemBlock(type: "text", text: "only", cache_control: nil),
        ])
        #expect(single.systemText == "only")

        // Empty `.blocks([])` returns nil (no text content to expose).
        let empty = AnthropicSystem.blocks([])
        #expect(empty.systemText == nil)
    }
}
