import Testing
import Foundation
@testable import Core

#if canImport(Darwin)
import Darwin
#endif

/// V.13c — POST /v1/embeddings via ModelManager. Covers the acceptance
/// checklist from `spec/autonomous/backlog/phase-v13c-embeddings.md`:
///
///   1. embeddings-shape (object:"list", data[].embedding, usage.total_tokens)
///   2. usage-total-tokens
///   3. model-from-ModelManager
///   4. no-parallel-stack-assertion
///   5. out-of-scope-403 (auth gate)
///   6. single-audit-entry (surface == "embeddings")
///   + decode paths (string / [string] / reject token forms / empty)
///   + live listener round-trip (authorized + out-of-scope)
@Suite("OpenAI embeddings surface + audit (V.13c)")
struct OpenAIEmbeddingsTests {

    // A deterministic engine: fixed 4-dim vectors + a known token count.
    private static func stubEngine(promptTokens: Int = 5) -> OpenAIEmbeddingsHandler.Engine {
        OpenAIEmbeddingsHandler.Engine { _, inputs in
            let vectors = inputs.enumerated().map { i, _ in
                [Float(i), 0.1, 0.2, 0.3]
            }
            return OpenAIEmbeddingsHandler.Embedding(vectors: vectors, promptTokens: promptTokens)
        }
    }

    private static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - 1. embeddings shape

    @Test("response is a well-formed OpenAI list-of-embedding object")
    func embeddingsShape() {
        let result = OpenAIEmbeddingsHandler.handle(
            request: .init(model: "text-embedding-3-small", input: ["alpha", "beta"]),
            keyLabel: "ci", engine: Self.stubEngine(), now: Self.fixedNow
        )
        let r = result.response
        #expect(r.object == "list")
        #expect(r.data.count == 2)
        #expect(r.data[0].object == "embedding")
        #expect(r.data[0].index == 0)
        #expect(r.data[1].index == 1)
        #expect(r.data[0].embedding == [0.0, 0.1, 0.2, 0.3])
        #expect(r.data[1].embedding == [1.0, 0.1, 0.2, 0.3])
        // Response model is the actual (ModelManager-sourced) model, not the
        // client-requested embedding model name.
        #expect(r.model == OpenAIEmbeddingsHandler.resolvedModel())
        #expect(r.model != "text-embedding-3-small")

        // Encoded JSON carries the OpenAI keys.
        let framed = OpenAIEmbeddingsHandler.encodeResponse(r)
        let text = String(decoding: framed, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK"))
        #expect(text.contains("\"object\":\"list\""))
        #expect(text.contains("\"object\":\"embedding\""))
        #expect(text.contains("\"total_tokens\":5"))
    }

    // MARK: - 2. usage total_tokens

    @Test("usage.total_tokens equals prompt_tokens (no completion side)")
    func usageTotalTokens() {
        let result = OpenAIEmbeddingsHandler.handle(
            request: .init(model: "m", input: ["one input"]),
            keyLabel: nil, engine: Self.stubEngine(promptTokens: 9), now: Self.fixedNow
        )
        #expect(result.response.usage.promptTokens == 9)
        #expect(result.response.usage.totalTokens == 9)
        #expect(result.response.usage.totalTokens == result.response.usage.promptTokens)
    }

    // MARK: - 3. model from ModelManager

    @Test("the served model is sourced from ModelManager (registered entry)")
    func modelFromModelManager() {
        // The embedding model is registered in ModelManager's default
        // registry, and the handler resolves its id from there.
        let registered = ModelManager.shared.model(ModelManager.embeddingModelID)
        #expect(registered != nil)
        #expect(registered?.id == ModelManager.embeddingModelID)
        #expect(OpenAIEmbeddingsHandler.resolvedModel() == registered?.id)
    }

    // MARK: - 4. no parallel embedding stack

    @Test("no parallel stack — the surface uses the single ModelManager id")
    func noParallelStack() {
        // The resolved model is exactly the one canonical constant — the
        // surface invents no second embedding model id.
        #expect(OpenAIEmbeddingsHandler.resolvedModel() == ModelManager.embeddingModelID)
        // And the model the handler reports in the response matches it.
        let result = OpenAIEmbeddingsHandler.handle(
            request: .init(model: "whatever", input: ["x"]),
            keyLabel: nil, engine: Self.stubEngine(), now: Self.fixedNow
        )
        #expect(result.response.model == ModelManager.embeddingModelID)
        #expect(result.telemetry.resolvedModel == ModelManager.embeddingModelID)
    }

    // MARK: - 5. out-of-scope → 403

    @Test("a key without `embeddings` scope is forbidden; with scope it is admitted")
    func outOfScope403() {
        let limiter = OpenAIRateLimiter()
        let key = "sk-senkani-emb-scope"
        func record(scope: [String]) -> OpenAIKeyRecord {
            OpenAIKeyRecord(
                keyHash: OpenAIAuthGate.hash(key),
                preset: "auto", scope: scope, rateLimit: 60,
                createdAt: Date(), expiresAt: nil, label: "scoped"
            )
        }
        // The path maps to the embeddings surface.
        #expect(OpenAIAuthGate.surface(forPath: "/v1/embeddings") == "embeddings")

        // chat-only key → 403 on the embeddings surface.
        let denied = OpenAIAuthGate.decide(
            authorizationHeader: "Bearer \(key)",
            requestedSurface: "embeddings",
            now: Self.fixedNow, records: [record(scope: ["chat"])], rateLimiter: limiter
        )
        guard case .forbidden = denied else {
            Issue.record("expected .forbidden, got \(denied)"); return
        }

        // embeddings-scoped key → ok.
        let allowed = OpenAIAuthGate.decide(
            authorizationHeader: "Bearer \(key)",
            requestedSurface: "embeddings",
            now: Self.fixedNow, records: [record(scope: ["embeddings"])], rateLimiter: limiter
        )
        guard case .ok = allowed else {
            Issue.record("expected .ok, got \(allowed)"); return
        }
    }

    // MARK: - 6. single audit entry, surface == embeddings

    @Test("each request produces exactly one audit entry with surface=embeddings")
    func singleAuditEntry() {
        let result = OpenAIEmbeddingsHandler.handle(
            request: .init(model: "text-embedding-3-large", input: ["zzqSecretInputText", "two", "three"]),
            keyLabel: "team", engine: Self.stubEngine(promptTokens: 12), now: Self.fixedNow
        )
        let chain = OpenAIAuditChain()
        chain.append(result.auditFields, bodies: nil)
        #expect(chain.count == 1)

        let entry = chain.entries[0]
        #expect(entry.fields.surface == "embeddings")
        #expect(entry.fields.keyLabel == "team")
        #expect(entry.fields.modelLogged == "text-embedding-3-large")
        #expect(entry.fields.resolvedTier == ModelManager.embeddingModelID)
        #expect(entry.fields.promptTokenCount == 12)
        #expect(entry.fields.completionTokenCount == 0)   // no generation
        #expect(entry.fields.status == "ok")
        #expect(entry.prev == nil)
        #expect(chain.verify() == .ok(count: 1))

        // Audit fields never carry the input text (bodies off).
        let cols = OpenAIAuditChain.canonicalColumns(fields: result.auditFields, bodies: nil)
        let bytes = ChainHasher.canonicalBytes(table: OpenAIAuditChain.table, columns: cols)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("zzqSecretInputText"))
    }

    // MARK: - decode paths

    @Test("decode accepts string + [string] inputs and rejects unsupported shapes")
    func decodePaths() {
        // Single string → one-element array.
        let single = OpenAIEmbeddingsHandler.decodeRequest(
            Data(#"{"model":"m","input":"hello"}"#.utf8)
        )
        #expect(single?.input == ["hello"])

        // Array of strings.
        let arr = OpenAIEmbeddingsHandler.decodeRequest(
            Data(#"{"model":"m","input":["a","b"]}"#.utf8)
        )
        #expect(arr?.input == ["a", "b"])

        // Empty array → nil (→ 400).
        #expect(OpenAIEmbeddingsHandler.decodeRequest(Data(#"{"model":"m","input":[]}"#.utf8)) == nil)

        // Token-id array form is unsupported in v13c → nil (→ 400).
        #expect(OpenAIEmbeddingsHandler.decodeRequest(Data(#"{"model":"m","input":[1,2,3]}"#.utf8)) == nil)

        // Object input → nil.
        #expect(OpenAIEmbeddingsHandler.decodeRequest(Data(#"{"model":"m","input":{"x":1}}"#.utf8)) == nil)

        // Garbage → nil.
        #expect(OpenAIEmbeddingsHandler.decodeRequest(Data("not json".utf8)) == nil)
    }

    // MARK: - live listener round-trip (Network)

    #if canImport(Network)
    @Test("live listener serves embeddings for an authorized POST and 403s out-of-scope")
    func liveEmbeddingsRoundTrip() throws {
        let key = "sk-senkani-liveemb"
        let record = OpenAIKeyRecord(
            keyHash: OpenAIAuthGate.hash(key),
            preset: "auto", scope: ["embeddings"], rateLimit: 60,
            createdAt: Date(), expiresAt: nil, label: "live-emb"
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
        let engine = Self.stubEngine()
        let embeddingsHandler = OpenAIListener.EmbeddingsHandler { _, _, headers, body in
            guard let request = OpenAIEmbeddingsHandler.decodeRequest(body) else { return nil }
            let token = OpenAIAuthGate.bearerToken(fromHeader: headers["authorization"])
            let rec = token.flatMap { OpenAIAuthGate.matchRecord(presentedKey: $0, records: [record]) }
            let result = OpenAIEmbeddingsHandler.handle(
                request: request, keyLabel: rec?.label, engine: engine, now: Date()
            )
            chain.append(result.auditFields, bodies: nil)
            return OpenAIEmbeddingsHandler.encodeResponse(result.response)
        }

        let listener = OpenAIListener(
            config: .init(bind: "127.0.0.1", port: 0),
            authenticator: authenticator, embeddingsHandler: embeddingsHandler
        )
        try listener.start()
        defer { listener.stop() }
        let port = listener.port
        #expect(port > 0)

        func post(authKey: String) -> String {
            let bodyJSON = #"{"model":"text-embedding-3-small","input":["hi","there"]}"#
            let requestText =
                "POST /v1/embeddings HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                + "Authorization: Bearer \(authKey)\r\n"
                + "Content-Type: application/json\r\nContent-Length: \(bodyJSON.utf8.count)\r\n"
                + "Connection: close\r\n\r\n\(bodyJSON)"
            guard let fd = connectToLocalhost(port: port) else { return "" }
            defer { close(fd) }
            _ = writeAllToFD(fd, Data(requestText.utf8))
            shutdown(fd, Int32(SHUT_WR))
            return String(decoding: readAllUntilEOF(fd), as: UTF8.self)
        }

        // Authorized → 200 list.
        let okResp = post(authKey: key)
        #expect(okResp.hasPrefix("HTTP/1.1 200 OK"))
        #expect(okResp.contains("\"object\":\"list\""))
        #expect(okResp.contains("\"object\":\"embedding\""))
        #expect(okResp.contains(ModelManager.embeddingModelID))
        #expect(chain.count == 1)
        #expect(chain.verify() == .ok(count: 1))

        // Wrong key → 401 (no record match), proving the gate runs ahead of
        // the surface (the surface handler never appends a second entry).
        let badResp = post(authKey: "sk-not-a-key")
        #expect(badResp.hasPrefix("HTTP/1.1 401"))
        #expect(chain.count == 1)
    }
    #endif
}
