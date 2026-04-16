import Testing
import Foundation
import MCP
@testable import MCPServer

/// P2-10: unit tests for the argument vocabulary shim.
/// Exercises the pure `ArgumentShim.normalize` function — no router, no session.
/// Session-scoped once-per-session semantics live in `MCPSession.noteDeprecation`,
/// tested separately.
@Suite("ArgumentShim")
struct ArgumentShimTests {

    // MARK: - knowledge + validate rename

    @Test func knowledgeDetailFullMapsToCanonicalFullTrue() {
        let n = ArgumentShim.normalize(
            toolName: "knowledge",
            arguments: ["action": .string("get"), "entity": .string("X"), "detail": .string("full")]
        )
        #expect(n.arguments?["full"]?.boolValue == true)
        #expect(n.arguments?["detail"] == nil, "deprecated name must be dropped from normalized args")
        #expect(n.deprecations.count == 1)
        #expect(n.deprecations.first?.key == "knowledge.detail")
    }

    @Test func knowledgeDetailSummaryMapsToFullFalse() {
        let n = ArgumentShim.normalize(
            toolName: "knowledge",
            arguments: ["action": .string("get"), "detail": .string("summary")]
        )
        #expect(n.arguments?["full"]?.boolValue == false)
        #expect(n.arguments?["detail"] == nil)
        #expect(n.deprecations.count == 1)
    }

    @Test func knowledgeDetailCaseInsensitive() {
        let n = ArgumentShim.normalize(
            toolName: "knowledge",
            arguments: ["detail": .string("Full")]
        )
        #expect(n.arguments?["full"]?.boolValue == true)
        #expect(n.deprecations.count == 1)
    }

    @Test func knowledgeDetailUnknownValueLeftAlone() {
        let n = ArgumentShim.normalize(
            toolName: "knowledge",
            arguments: ["detail": .string("garbage")]
        )
        // Unknown values are NOT translated; left in args but a deprecation is emitted.
        #expect(n.arguments?["full"] == nil, "no mapping for unknown value — full must not be set")
        #expect(n.deprecations.count == 1)
        #expect(n.deprecations.first?.message.contains("not a recognized value") == true)
    }

    @Test func knowledgeFullCanonicalNoDeprecation() {
        let n = ArgumentShim.normalize(
            toolName: "knowledge",
            arguments: ["action": .string("get"), "entity": .string("X"), "full": .bool(true)]
        )
        #expect(n.arguments?["full"]?.boolValue == true)
        #expect(n.deprecations.isEmpty, "canonical 'full' alone must not trigger a deprecation")
    }

    @Test func knowledgeBothDetailAndFullFullWins() {
        let n = ArgumentShim.normalize(
            toolName: "knowledge",
            arguments: ["detail": .string("summary"), "full": .bool(true)]
        )
        // Canonical `full` wins; `detail` is dropped and a conflict-flavored deprecation fires.
        #expect(n.arguments?["full"]?.boolValue == true)
        #expect(n.arguments?["detail"] == nil)
        #expect(n.deprecations.count == 1)
        #expect(n.deprecations.first?.message.contains("both") == true,
                "conflict message must mention both names, got: \(n.deprecations.first?.message ?? "")")
    }

    @Test func validateDetailFullMapsToCanonicalFullTrue() {
        let n = ArgumentShim.normalize(
            toolName: "validate",
            arguments: ["file": .string("Foo.swift"), "detail": .string("full")]
        )
        #expect(n.arguments?["full"]?.boolValue == true)
        #expect(n.deprecations.first?.key == "validate.detail")
    }

    // MARK: - non-target tools passthrough

    @Test func readToolDetailLeftUntouched() {
        // `read` doesn't use `detail` as an escape hatch; shim must not rewrite it.
        let n = ArgumentShim.normalize(
            toolName: "read",
            arguments: ["path": .string("Foo.swift"), "detail": .string("full")]
        )
        #expect(n.arguments?["detail"]?.stringValue == "full", "read passthrough: detail preserved")
        #expect(n.arguments?["full"] == nil, "read passthrough: no full synthesized")
        #expect(n.deprecations.isEmpty, "read not a target tool — no deprecation")
    }

    @Test func nilArgumentsPassthrough() {
        let n = ArgumentShim.normalize(toolName: "knowledge", arguments: nil)
        #expect(n.arguments == nil)
        #expect(n.deprecations.isEmpty)
    }

    // MARK: - session-scoped once-per-session

    @Test func noteDeprecationFirstSightTrueThenFalse() {
        let session = MCPSession(
            projectRoot: "/tmp/argument-shim-test-\(UUID().uuidString)",
            filterEnabled: false, secretsEnabled: false, indexerEnabled: false,
            cacheEnabled: false, terseEnabled: false, injectionGuardEnabled: false,
            sessionId: nil, paneId: nil
        )
        #expect(session.noteDeprecation("knowledge.detail") == true,
                "first sight must return true so the router appends the warning")
        #expect(session.noteDeprecation("knowledge.detail") == false,
                "second sight must return false so the warning is not repeated")
        #expect(session.noteDeprecation("validate.detail") == true,
                "different key is independent")
    }
}
