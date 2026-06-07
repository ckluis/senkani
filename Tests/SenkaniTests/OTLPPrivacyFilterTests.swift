import Testing
import Foundation
@testable import Core

/// V.18a-4 — privacy-filter tests. Cover the three acceptance bullets
/// from `spec/autonomous/backlog/phase-v18a-4-privacy-filter.md`:
///
///   1. `.metadata` mode (default) drops HTTP/RPC body+header+env
///      attribute keys at receive while preserving span name /
///      duration / status / non-sensitive attributes — and
///      SecretDetector scans every kept value so an accidentally-
///      embedded API key in `url.full` still gets redacted.
///   2. `.redactedBodies` mode captures the body/header/env keys but
///      routes every value (sensitive and otherwise) through
///      SecretDetector before persist.
///   3. `.full` mode passes attributes verbatim AND
///      `HandManifestLinter` warns when `runtime_telemetry.capture`
///      is `.full` and `validated_fields` is empty — the
///      per-field operator review must be declared explicitly.
@Suite("OTLPPrivacyFilter (V.18a-4)")
struct OTLPPrivacyFilterTests {

    private static let realisticAttrs: [String: String] = [
        // Non-sensitive metadata (kept across all modes):
        "http.method": "POST",
        "http.url": "https://api.example.com/v1/messages",
        "http.status_code": "200",
        "db.system": "postgresql",
        // Sensitive — should be dropped in .metadata, redacted in
        // .redactedBodies, passed through in .full:
        "http.request.body": "{\"prompt\":\"sk-ant-aaaabbbbccccddddeeeeffff1234567890\"}",
        "http.request.header.authorization": "Bearer sk-proj-zzzzyyyyxxxxwwwwvvvvuuuu99887766",
        "http.response.body": "{\"ok\":true}",
        "process.env.OPENAI_API_KEY": "sk-aaaa1111bbbb2222cccc3333dddd4444",
        // Sneaky: API key embedded in an otherwise-non-sensitive
        // attribute. .metadata mode must still SecretDetector-scan
        // every kept value so this doesn't leak.
        "messaging.consumer.id": "consumer-AKIAIOSFODNN7EXAMPLE",
    ]

    @Test("metadata mode drops sensitive keys + SecretDetector-scans kept values")
    func metadataModeDropsAndScansKeptValues() {
        let out = OTLPPrivacyFilter.filter(
            attributes: Self.realisticAttrs,
            mode: .metadata)

        // Sensitive keys gone entirely.
        #expect(out["http.request.body"] == nil)
        #expect(out["http.request.header.authorization"] == nil)
        #expect(out["http.response.body"] == nil)
        #expect(out["process.env.OPENAI_API_KEY"] == nil)

        // Non-sensitive metadata kept verbatim where no secret pattern
        // matches.
        #expect(out["http.method"] == "POST")
        #expect(out["http.url"] == "https://api.example.com/v1/messages")
        #expect(out["http.status_code"] == "200")
        #expect(out["db.system"] == "postgresql")

        // Non-sensitive value WITH embedded secret pattern is kept
        // but redacted by SecretDetector. The AWS access key pattern
        // is `AKIA[0-9A-Z]{16}` so the consumer.id should turn into
        // `consumer-[REDACTED:AWS_ACCESS_KEY_ID]`.
        let consumer = out["messaging.consumer.id"] ?? ""
        #expect(consumer.contains("[REDACTED:AWS_ACCESS_KEY_ID]"))
        #expect(!consumer.contains("AKIAIOSFODNN7EXAMPLE"))
    }

    @Test("redactedBodies mode keeps sensitive keys with SecretDetector-redacted values")
    func redactedBodiesModeKeepsButRedacts() {
        let out = OTLPPrivacyFilter.filter(
            attributes: Self.realisticAttrs,
            mode: .redactedBodies)

        // Sensitive keys retained.
        #expect(out["http.request.body"] != nil)
        #expect(out["http.request.header.authorization"] != nil)
        #expect(out["http.response.body"] != nil)
        #expect(out["process.env.OPENAI_API_KEY"] != nil)

        // But the secret values inside them are redacted.
        let reqBody = out["http.request.body"] ?? ""
        #expect(reqBody.contains("[REDACTED:ANTHROPIC_API_KEY]"))
        #expect(!reqBody.contains("sk-ant-aaaabbbbccccddddeeeeffff1234567890"))

        let auth = out["http.request.header.authorization"] ?? ""
        // OPENAI_PROJECT_KEY pattern wins over generic OPENAI_API_KEY
        // by ordering in SecretDetector.patterns.
        #expect(auth.contains("[REDACTED:OPENAI_PROJECT_KEY]"))
        #expect(!auth.contains("sk-proj-zzzzyyyyxxxxwwwwvvvvuuuu99887766"))

        let env = out["process.env.OPENAI_API_KEY"] ?? ""
        #expect(env.contains("[REDACTED:OPENAI_API_KEY]"))
        #expect(!env.contains("sk-aaaa1111bbbb2222cccc3333dddd4444"))

        // http.response.body had no secret → kept verbatim.
        #expect(out["http.response.body"] == "{\"ok\":true}")

        // Non-sensitive attributes preserved exactly the same way as
        // .metadata mode (and still SecretDetector-scanned).
        #expect(out["http.method"] == "POST")
        #expect(out["db.system"] == "postgresql")
        let consumer = out["messaging.consumer.id"] ?? ""
        #expect(consumer.contains("[REDACTED:AWS_ACCESS_KEY_ID]"))
    }

    @Test("full mode passes through and HandManifestLinter warns on missing validated_fields")
    func fullModePassesThroughAndLinterWarns() {
        // 3.a) full mode is a pass-through — verbatim values.
        let out = OTLPPrivacyFilter.filter(
            attributes: Self.realisticAttrs,
            mode: .full)
        #expect(out == Self.realisticAttrs)
        let env = out["process.env.OPENAI_API_KEY"] ?? ""
        #expect(env == "sk-aaaa1111bbbb2222cccc3333dddd4444")
        #expect(!env.contains("REDACTED"))

        // 3.b) HandManifestLinter warns when capture=full and
        // validated_fields is empty.
        let manifestEmpty = HandManifest(
            name: "demo-skill",
            description: "demo",
            version: "0.1.0",
            systemPrompt: HandSystemPrompt(phases: [HandPromptPhase(name: "p", body: "b")]),
            runtimeTelemetry: HandRuntimeTelemetry(capture: .full))
        let issuesEmpty = HandManifestLinter.lint(manifestEmpty)
        #expect(issuesEmpty.contains { issue in
            issue.severity == .warning
                && issue.path == "runtime_telemetry.validated_fields"
                && issue.message.contains("validated_fields is empty")
        })

        // 3.c) Linter is quiet when capture=full and validated_fields
        // covers each captured key with a non-empty reason.
        let manifestOk = HandManifest(
            name: "demo-skill",
            description: "demo",
            version: "0.1.0",
            systemPrompt: HandSystemPrompt(phases: [HandPromptPhase(name: "p", body: "b")]),
            runtimeTelemetry: HandRuntimeTelemetry(
                capture: .full,
                validatedFields: [
                    "http.request.body": "endpoint is rate-limited + audited",
                    "process.env.OPENAI_API_KEY": "redacted upstream by reverse proxy",
                ]))
        let issuesOk = HandManifestLinter.lint(manifestOk)
        #expect(!issuesOk.contains { $0.path.hasPrefix("runtime_telemetry") })

        // 3.d) Linter warns per-key when a validated_fields entry has
        // an empty reason — the audit trail demands a non-empty note.
        let manifestEmptyReason = HandManifest(
            name: "demo-skill",
            description: "demo",
            version: "0.1.0",
            systemPrompt: HandSystemPrompt(phases: [HandPromptPhase(name: "p", body: "b")]),
            runtimeTelemetry: HandRuntimeTelemetry(
                capture: .full,
                validatedFields: ["http.request.body": "  "]))
        let issuesEmptyReason = HandManifestLinter.lint(manifestEmptyReason)
        #expect(issuesEmptyReason.contains { issue in
            issue.severity == .warning
                && issue.path == "runtime_telemetry.validated_fields[http.request.body]"
        })
    }
}
