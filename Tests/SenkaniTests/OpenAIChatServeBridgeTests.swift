import Testing
import Foundation
@testable import Core

/// V.13 real-chat (sub-item 3) — covers the two pre-dispatch 503 gates
/// `ServeCommand` runs after routing: `backendNotConfiguredResponse`
/// (non-local tier deny) and `readinessResponse` (registered chat
/// handler + no installed Gemma 4 tier). Mirrors
/// `EmbeddingEngineRegistrationTests`'s readiness-gate suite.
///
/// No real model required — both helpers are pure functions over
/// `ModelTier` and `Bool`. The end-to-end wiring inside
/// `ServeCommand` is exercised by `OpenAIChatRealEngineTests` against
/// the registered handler when MCP is active.
@Suite("V.13 real-chat sub-item 3 — ServeBridge 503 gates")
struct OpenAIChatServeBridgeTests {

    // MARK: - 1. backend_not_configured tier gate

    @Test("non-local quick tier returns 503 backend_not_configured")
    func testNonLocalTier503BackendNotConfigured() {
        for tier: ModelTier in [.quick, .balanced, .frontier] {
            let response = OpenAIChatServeBridge.backendNotConfiguredResponse(tier: tier)
            #expect(response != nil, "tier=\(tier) should deny pre-dispatch")
            let text = String(decoding: response!, as: UTF8.self)
            #expect(text.hasPrefix("HTTP/1.1 503 Service Unavailable"))
            #expect(text.contains("\"type\":\"backend_not_configured\""))
            // Operator-grade message points at the filed Claude-API child
            // item + `senkani vault add anthropic-key` — not a generic
            // "try again later".
            #expect(text.contains("phase-v13-real-chat-engine-claude-api-arm-2026-05-28"))
            #expect(text.contains("senkani vault add anthropic-key"))
            // Names the resolved tier so the operator can correlate which
            // request was denied.
            #expect(text.contains(tier.rawValue))
        }
    }

    @Test("local tier returns nil — continue to dispatch")
    func testLocalTierAllowsDispatch() {
        let response = OpenAIChatServeBridge.backendNotConfiguredResponse(tier: .local)
        #expect(response == nil)
    }

    // MARK: - 2. model_not_available readiness gate

    @Test("readiness gate returns 503 model_not_available when no Gemma installed")
    func testModelNotAvailable503WhenModelMissing() {
        let response = OpenAIChatServeBridge.readinessResponse(
            modelTier: .local, isReady: false
        )
        #expect(response != nil)
        let text = String(decoding: response!, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 503 Service Unavailable"))
        #expect(text.contains("\"type\":\"model_not_available\""))
        // Mirrors v13c embeddings — the operator-grade install hint
        // points at the Models pane / `senkani doctor`.
        #expect(text.contains("Models pane") || text.contains("senkani doctor"))
        // Names the tier (`local`) so the message is unambiguous.
        #expect(text.contains("local"))
    }

    @Test("readiness gate returns nil when the registered handler is ready")
    func testReadinessGateReady() {
        let response = OpenAIChatServeBridge.readinessResponse(
            modelTier: .local, isReady: true
        )
        #expect(response == nil)
    }
}
