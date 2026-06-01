import Testing
import Foundation
@testable import Core

/// V.13b-1 — END-TO-END key-label propagation invariant for the Anthropic
/// serve arm. The plumbing already shipped in b-4c (commit f0867f8):
/// `AnthropicKeyProvisioner.loadSingle` returns `AnthropicKeyRecord{key,
/// label}`; `ServeCommand` extracts the label into
/// `anthropicKeyLabelForAudit` and threads it through
/// `ClaudeAPIServeDispatch.dispatch(...,keyLabel:)`; the dispatch builds
/// `Outcome.auditFields.keyLabel`; ServeCommand passes that to
/// `OpenAIServedRequestSink.record(...,fields:)`; the sink stores
/// `fields.keyLabel` into the persisted `key_label` column.
///
/// This suite CODIFIES that chain end-to-end with a single propagation
/// assertion that drives the live dispatch + sink + persisted-read path —
/// NOT via the openai-key path. If a future refactor breaks any link
/// (dispatch drops the parameter, sink fills the column from a different
/// source, store schema column renames), this test fails.
///
/// The negative assertion (`keyLabel: nil` → persisted row's
/// `key_label IS NULL`) proves the dispatch path doesn't surreptitiously
/// fall back to the openai-key matcher — the persisted label is sourced
/// EXCLUSIVELY from `AnthropicKeyRecord.label` → `dispatch keyLabel:` →
/// `Outcome.auditFields.keyLabel`.
@Suite("AnthropicArmKeyLabelPropagation — vault label reaches persisted key_label", .serialized, .urlProtocolGate)
struct AnthropicArmKeyLabelPropagationTests {

    private let anthropicURL = URL(string: "https://api.anthropic.com/v1/messages")!

    private func tempDB() -> SessionDatabase {
        let dir = NSTemporaryDirectory() + "senkani-anthropic-keylabel-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return SessionDatabase(path: dir + "senkani.db")
    }

    private func makeEngine() -> ClaudeAPIChatEngine {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return ClaudeAPIChatEngine(
            apiKey: "sk-ant-test",
            session: session,
            endpoint: anthropicURL,
            retryPolicy: .default,
            sleeper: { _ in }
        )
    }

    private func routing() -> OpenAIChatHandler.Routing {
        OpenAIChatHandler.Routing(
            presetUsed: .auto,
            resolvedTier: .quick,
            actualModel: ModelTier.quick.claudeModelValue,
            modelLogged: "gpt-4o"
        )
    }

    private func request() -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: "gpt-4o",
            messages: [.init(role: "user", content: "ping")]
        )
    }

    private func successBody() -> Data {
        Data("""
        {"id":"msg_01","type":"message","role":"assistant","content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn","usage":{"input_tokens":4,"output_tokens":2}}
        """.utf8)
    }

    /// PRIMARY invariant: the vault-provisioned label propagates all the
    /// way to the persisted `openai_request_log.key_label` column on a
    /// successful Anthropic-arm serve request.
    @Test("Vault label propagates to persisted key_label on successful Anthropic-arm dispatch")
    func vaultLabelReachesPersistedKeyLabel() async throws {
        // 1. Stand up the vault + provision a single Anthropic key with a
        //    distinctive label. `loadSingle` exercises the b-4c resolution
        //    path the live ServeCommand uses.
        let vault = CredentialVault(store: InMemoryKeychainStore())
        try await AnthropicKeyProvisioner.store(
            key: "sk-ant-test", label: "anthropic-work", vault: vault
        )
        let record = try await AnthropicKeyProvisioner.loadSingle(vault: vault)
        #expect(record?.label == "anthropic-work",
            "precondition: provisioner must round-trip the label")

        // 2. Mock the upstream Anthropic Messages 200 success response.
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        MockURLProtocol.register(url: anthropicURL, status: 200, body: successBody())

        // 3. Drive the dispatch in the same shape as ServeCommand — pass
        //    the vault label through the `keyLabel:` parameter.
        let outcome = ClaudeAPIServeDispatch.dispatch(
            engine: makeEngine(),
            request: request(),
            routing: routing(),
            keyLabel: record!.label,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            id: "chatcmpl-keylabel-propagation"
        )

        // 4. Mid-chain assertion: dispatch surfaces the label on
        //    AuditFields.keyLabel (this is the seam the sink reads).
        #expect(outcome.httpStatus == 200)
        #expect(outcome.auditFields.keyLabel == "anthropic-work",
            "dispatch must forward keyLabel: into Outcome.auditFields.keyLabel")

        // 5. Persist via the live sink + read back via the persistent
        //    store API. `db.recentOpenAIRequests(limit:)` is the canonical
        //    read seam (Sources/Core/SessionDatabase+OpenAIRequestLogAPI.swift:61).
        let db = tempDB()
        let chain = OpenAIAuditChain()
        let landed = OpenAIServedRequestSink.record(
            chain: chain,
            fields: outcome.auditFields,
            bodies: outcome.auditBodies,
            db: db,
            surface: .chat,
            httpStatus: outcome.httpStatus
        )
        #expect(landed, "persisted row must land (best-effort sink returned false)")

        // 6. The end-to-end invariant: the persisted column matches the
        //    vault's stored label.
        let rows = db.recentOpenAIRequests(limit: 10)
        #expect(rows.count == 1, "expected exactly one persisted row, got \(rows.count)")
        #expect(rows.first?.keyLabel == "anthropic-work",
            "persisted key_label must equal the vault-provisioned label; got \(String(describing: rows.first?.keyLabel))")
        // Bonus surface assertion — the row is attributed to chat, not other/embeddings.
        #expect(rows.first?.surface == "chat")
        #expect(rows.first?.status == 200)
    }

    /// NEGATIVE assertion (the acceptance contract's "NOT via the
    /// openai-key path" check): if dispatch is driven with `keyLabel: nil`
    /// the persisted column is SQL NULL — proving the label is sourced
    /// EXCLUSIVELY from the `keyLabel:` parameter, not via a fallback
    /// match against the OpenAI-record list.
    @Test("Nil dispatch keyLabel persists SQL NULL — no openai-key fallback path")
    func nilDispatchKeyLabelPersistsNull() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        MockURLProtocol.register(url: anthropicURL, status: 200, body: successBody())

        let outcome = ClaudeAPIServeDispatch.dispatch(
            engine: makeEngine(),
            request: request(),
            routing: routing(),
            keyLabel: nil,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            id: "chatcmpl-keylabel-nil"
        )
        #expect(outcome.httpStatus == 200)
        #expect(outcome.auditFields.keyLabel == nil)

        let db = tempDB()
        let chain = OpenAIAuditChain()
        let landed = OpenAIServedRequestSink.record(
            chain: chain,
            fields: outcome.auditFields,
            bodies: outcome.auditBodies,
            db: db,
            surface: .chat,
            httpStatus: outcome.httpStatus
        )
        #expect(landed)

        let rows = db.recentOpenAIRequests(limit: 10)
        #expect(rows.count == 1)
        #expect(rows.first?.keyLabel == nil,
            "nil dispatch keyLabel must persist as SQL NULL (no surreptitious openai-key fallback)")
    }
}
