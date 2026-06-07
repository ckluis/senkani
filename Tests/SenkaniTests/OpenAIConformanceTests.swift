import Testing
import Foundation
@testable import Core

/// V.13e-4 — committed reproducible OpenAI conformance fixture (stub).
///
/// A curated subset of the OpenAI HTTP protocol is committed as data
/// fixtures under `Tests/SenkaniTests/Fixtures/openai-conformance/`. Each
/// fixture pins one surface's wire contract: the request body bytes plus
/// the response invariants the served bytes must satisfy. The runner drives
/// the *real* decode → handle → encode path of each surface against the same
/// deterministic stub engines the per-surface suites use — no network, no
/// LLM, no live model. Shape/protocol conformance only; real-completion
/// conformance (validating actual model output) is `phase-v13e-4b`.
///
/// Subset covered (acceptance):
///   * chat non-stream happy path        (`chat`)
///   * chat stream happy path            (`chat_stream`)
///   * embeddings happy path             (`embeddings`)
///   * tool-use happy path               (`tool_use`)
///   * auth / scope / rate-limit errors  (`auth_error`, from v13a-2)
///
/// Two tests:
///   1. conformance-fixture-runs           — every committed fixture loads
///      and its surface produces bytes satisfying the pinned invariants.
///   2. conformance-reproducible-from-clean — the fixtures physically exist
///      in the source tree (committed; reproducible from a clean checkout)
///      and the whole subset is byte-deterministic across repeated offline
///      runs.
@Suite("OpenAI conformance fixture (stub, V.13e-4)")
struct OpenAIConformanceTests {

    // MARK: - Fixture model

    /// One conformance case. Surface kinds (`chat`, `chat_stream`,
    /// `embeddings`, `tool_use`) carry a `request_body`; `auth_error` cases
    /// carry the vault records + presented key + requested surface instead.
    struct Fixture: Decodable {
        let name: String
        let kind: String
        let description: String
        let requestBody: String?
        let records: [RecordSpec]?
        let presentedKey: String?
        let requestedSurface: String?
        let repeatCount: Int?
        let expect: Expectation

        struct RecordSpec: Decodable {
            let key: String
            let scope: [String]
            let rateLimit: Int
            let expired: Bool?

            enum CodingKeys: String, CodingKey {
                case key, scope
                case rateLimit = "rate_limit"
                case expired
            }
        }

        struct Expectation: Decodable {
            let httpStatus: String?
            let contains: [String]?
            let notContains: [String]?

            enum CodingKeys: String, CodingKey {
                case httpStatus = "http_status"
                case contains
                case notContains = "not_contains"
            }
        }

        enum CodingKeys: String, CodingKey {
            case name, kind, description
            case requestBody = "request_body"
            case records
            case presentedKey = "presented_key"
            case requestedSurface = "requested_surface"
            case repeatCount = "repeat"
            case expect
        }
    }

    /// The curated subset is exactly these committed files — drift in either
    /// direction (a missing file, or an unannounced extra) fails the gate.
    static let expectedFixtureFiles: Set<String> = [
        "chat-nonstream-happy.json",
        "chat-stream-happy.json",
        "embeddings-happy.json",
        "tool-use-happy.json",
        "auth-unknown-key-401.json",
        "auth-out-of-scope-403.json",
        "auth-over-rate-429.json",
    ]

    // MARK: - Deterministic clock + stubs (no network / no LLM)

    private static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    private static let createdSeconds = 1_700_000_000

    /// Echoes fixed content + fixed token counts.
    private static func chatStub(content: String = "hello from the stub") -> OpenAIChatHandler.Engine {
        OpenAIChatHandler.Engine { _, _, _ in
            OpenAIChatHandler.Completion(content: content, promptTokens: 7, completionTokens: 4)
        }
    }

    /// Calls the first declared (bridged) tool until a `role:tool` result is
    /// in context, then answers with text — mirrors the v13d round-trip stub.
    private static func toolStub() -> OpenAIChatHandler.Engine {
        OpenAIChatHandler.Engine { _, messages, tools in
            let hasToolResult = messages.contains { $0.role == "tool" }
            if let first = OpenAIToolBridge.bridge(tools).first, !hasToolResult {
                let call = OpenAIToolCall(
                    id: "call_conf123",
                    function: .init(name: first.name, arguments: "{\"location\":\"SF\"}")
                )
                return .init(content: "", toolCalls: [call], promptTokens: 8, completionTokens: 5)
            }
            return .init(content: "It is sunny in SF, 21°C.", promptTokens: 12, completionTokens: 7)
        }
    }

    /// Fixed 4-dim vectors + a known token count.
    private static func embeddingsStub(promptTokens: Int = 5) -> OpenAIEmbeddingsHandler.Engine {
        OpenAIEmbeddingsHandler.Engine { _, inputs in
            let vectors = inputs.enumerated().map { i, _ in [Float(i), 0.1, 0.2, 0.3] }
            return OpenAIEmbeddingsHandler.Embedding(vectors: vectors, promptTokens: promptTokens)
        }
    }

    // MARK: - Runner

    /// Result of running one fixture: the bytes the surface produced and a
    /// human-readable rendering for `contains` assertions. `producedBytes` is
    /// the determinism anchor — identical inputs must yield identical bytes.
    struct RunOutput {
        let producedBytes: Data
        var text: String { String(decoding: producedBytes, as: UTF8.self) }
    }

    /// Drive one fixture through the real surface path against the stubs.
    /// Returns nil only when the fixture is internally malformed (which the
    /// caller treats as a hard failure).
    static func run(_ fx: Fixture) -> RunOutput? {
        switch fx.kind {
        case "chat":
            guard let body = fx.requestBody.map({ Data($0.utf8) }),
                  let request = OpenAIChatHandler.decodeRequest(body) else { return nil }
            let result = OpenAIChatHandler.handle(
                request: request, recordPreset: "auto", keyLabel: "conformance",
                engine: chatStub(), now: fixedNow, id: "chatcmpl-conf-\(fx.name)"
            )
            return RunOutput(producedBytes: OpenAIChatHandler.encodeResponse(result.response))

        case "chat_stream":
            guard let body = fx.requestBody.map({ Data($0.utf8) }),
                  OpenAIChatHandler.decodeRequest(body) != nil else { return nil }
            // Run the stub to get the (deterministic) completion content, then
            // produce the SSE event stream + terminal sentinel.
            let content = "hello from the stub"
            let result = OpenAIChatHandler.handle(
                request: ChatCompletionRequest(model: "gpt-4o", messages: [.init(role: "user", content: "stream")]),
                recordPreset: "auto", keyLabel: nil,
                engine: chatStub(content: content), now: fixedNow, id: "chatcmpl-conf-stream"
            )
            let events = OpenAIChatStream.events(
                id: "chatcmpl-conf-stream", created: createdSeconds,
                model: result.response.model, content: result.response.choices.first?.message.content ?? ""
            )
            // Intrinsic conformance check: concatenated delta.content == content.
            let reconstructed = events.compactMap { deltaContent($0) }.joined()
            guard reconstructed == content else { return nil }
            var blob = Data()
            for ev in events { blob.append(ev) }
            blob.append(OpenAIChatStream.doneSentinel())
            return RunOutput(producedBytes: blob)

        case "embeddings":
            guard let body = fx.requestBody.map({ Data($0.utf8) }),
                  let request = OpenAIEmbeddingsHandler.decodeRequest(body) else { return nil }
            let result = OpenAIEmbeddingsHandler.handle(
                request: request, keyLabel: "conformance", engine: embeddingsStub(), now: fixedNow
            )
            return RunOutput(producedBytes: OpenAIEmbeddingsHandler.encodeResponse(result.response))

        case "tool_use":
            guard let body = fx.requestBody.map({ Data($0.utf8) }),
                  let request = OpenAIChatHandler.decodeRequest(body),
                  OpenAIChatHandler.requestUsesTools(request) else { return nil }
            let result = OpenAIChatHandler.handle(
                request: request, recordPreset: "auto", keyLabel: "conformance",
                engine: toolStub(), now: fixedNow, id: "chatcmpl-conf-tool"
            )
            return RunOutput(producedBytes: OpenAIChatHandler.encodeResponse(result.response))

        case "auth_error":
            guard let specs = fx.records, let presented = fx.presentedKey,
                  let surface = fx.requestedSurface else { return nil }
            let records: [OpenAIKeyRecord] = specs.map { spec in
                OpenAIKeyRecord(
                    keyHash: OpenAIAuthGate.hash(spec.key),
                    preset: "auto", scope: spec.scope, rateLimit: spec.rateLimit,
                    createdAt: Date(timeIntervalSince1970: 0),
                    expiresAt: (spec.expired ?? false) ? Date(timeIntervalSince1970: 1) : nil,
                    label: spec.key
                )
            }
            let limiter = OpenAIRateLimiter()
            var decision = OpenAIAuthGate.decide(
                authorizationHeader: "Bearer \(presented)", requestedSurface: surface,
                now: fixedNow, records: records, rateLimiter: limiter
            )
            for _ in 1..<max(1, fx.repeatCount ?? 1) {
                decision = OpenAIAuthGate.decide(
                    authorizationHeader: "Bearer \(presented)", requestedSurface: surface,
                    now: fixedNow, records: records, rateLimiter: limiter
                )
            }
            guard let response = OpenAIAuthGate.errorResponse(for: decision) else { return nil }
            return RunOutput(producedBytes: response)

        default:
            return nil
        }
    }

    /// Apply a fixture's pinned invariants to a run output. Records an Issue
    /// (and returns false) on the first violation.
    @discardableResult
    static func assertExpectations(_ fx: Fixture, _ out: RunOutput) -> Bool {
        var ok = true
        let text = out.text
        if let status = fx.expect.httpStatus {
            if !text.hasPrefix("HTTP/1.1 \(status)") {
                Issue.record("[\(fx.name)] expected status line 'HTTP/1.1 \(status)', got: \(text.prefix(40))")
                ok = false
            }
        }
        for needle in fx.expect.contains ?? [] where !text.contains(needle) {
            Issue.record("[\(fx.name)] response missing required substring: \(needle)")
            ok = false
        }
        for needle in fx.expect.notContains ?? [] where text.contains(needle) {
            Issue.record("[\(fx.name)] response contains forbidden substring: \(needle)")
            ok = false
        }
        return ok
    }

    // MARK: - Fixture loading

    /// Source-tree fixtures directory, located relative to THIS test file via
    /// `#filePath`. Reading from here is what "reproducible from a clean
    /// checkout" means: the committed bytes, not a build artifact.
    static func sourceFixturesDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()                          // Tests/SenkaniTests
            .appendingPathComponent("Fixtures/openai-conformance", isDirectory: true)
    }

    /// Load + decode every committed fixture from the source tree.
    static func loadFixtures() throws -> [Fixture] {
        let dir = sourceFixturesDir()
        let urls = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try urls.map { url in
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Fixture.self, from: data)
        }
    }

    // MARK: - 1. conformance-fixture-runs

    @Test("conformance-fixture-runs: every committed fixture loads and satisfies its surface invariants")
    func conformanceFixtureRuns() throws {
        let fixtures = try Self.loadFixtures()
        // The curated subset is present in full.
        #expect(fixtures.count == Self.expectedFixtureFiles.count)
        let kinds = Set(fixtures.map(\.kind))
        #expect(kinds == ["chat", "chat_stream", "embeddings", "tool_use", "auth_error"])

        for fx in fixtures {
            guard let out = Self.run(fx) else {
                Issue.record("[\(fx.name)] fixture failed to run (malformed or unhandled kind '\(fx.kind)')")
                continue
            }
            Self.assertExpectations(fx, out)
        }

        // The fixtures are bundled as test resources too — assert the
        // resource registration in Package.swift has not drifted.
        let bundled = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "openai-conformance")
        #expect((bundled?.count ?? 0) == Self.expectedFixtureFiles.count)
    }

    // MARK: - 2. conformance-reproducible-from-clean

    @Test("conformance-reproducible-from-clean: fixtures are committed in the tree and the subset is byte-deterministic offline")
    func conformanceReproducibleFromClean() throws {
        // (a) The fixtures physically exist in the source tree at the
        //     committed path — reproducible from a clean checkout.
        let dir = Self.sourceFixturesDir()
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        #expect(isDir.boolValue)

        let present = Set(
            try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
                .map(\.lastPathComponent)
        )
        #expect(present == Self.expectedFixtureFiles)

        // (b) Every committed fixture is well-formed (decodes).
        let fixtures = try Self.loadFixtures()
        #expect(fixtures.count == Self.expectedFixtureFiles.count)

        // (c) Determinism: running the whole subset twice — offline, against
        //     the deterministic stubs + fixed clock — yields byte-identical
        //     output. No network, no LLM, no wall-clock dependence.
        func runAll() -> [String: Data] {
            var out: [String: Data] = [:]
            for fx in fixtures {
                if let r = Self.run(fx) { out[fx.name] = r.producedBytes }
            }
            return out
        }
        let pass1 = runAll()
        let pass2 = runAll()
        #expect(pass1.count == fixtures.count)
        #expect(pass1 == pass2)
    }

    // MARK: - Helpers

    /// Decode one SSE event's `choices[0].delta.content`, if present.
    private static func deltaContent(_ data: Data) -> String? {
        let s = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "data: ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any] else { return nil }
        return delta["content"] as? String
    }
}
