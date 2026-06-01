import Testing
import Foundation
@testable import Core

// V.13b-4b (Option B) — serve-arm egress allow-rule detection + hint.
// Deny-on-miss MUST stay the default (no built-in allow rule); the hint is
// the only autonomous deliverable, the rule itself is the operator's edit.

@Suite("EgressPolicy serve-allow detection + hint (V.13b-4b, Option B)")
struct EgressPolicyServeAllowTests {

    private func policyAllowing(_ host: String, mode: PaneMode = .general) -> EgressPolicy {
        let rule = EgressRule(id: "serve-anthropic", pattern: host, mode: .exact, decision: .allow)
        return EgressPolicy(engines: [mode: EgressRuleEngine(rules: [rule])])
    }

    @Test func defaultsDenyAnthropicAndEmitHint() {
        // Deny-on-miss posture is UNCHANGED — no built-in allow rule shipped.
        let p = EgressPolicy.defaults()
        #expect(p.allows(host: "api.anthropic.com") == false)
        let hint = p.serveEgressAllowHint()
        #expect(hint != nil)
        #expect(hint?.contains("api.anthropic.com") == true)
        #expect(hint?.contains("egress-policy.json") == true)
    }

    @Test func operatorAllowRuleUnderServeModeSilencesHint() {
        let p = policyAllowing("api.anthropic.com", mode: .general)
        #expect(p.allows(host: "api.anthropic.com") == true)
        #expect(p.serveEgressAllowHint() == nil)
        // Host-specific: an unrelated host stays denied (deny-on-miss).
        #expect(p.allows(host: "evil.example.com") == false)
    }

    @Test func allowRuleUnderWrongModeStillDeniesServe() {
        // A rule under research mode does NOT satisfy the serve (general) path.
        let p = policyAllowing("api.anthropic.com", mode: .research)
        #expect(p.allows(host: "api.anthropic.com", mode: .general) == false)
        #expect(p.serveEgressAllowHint() != nil)
    }

    @Test func loadedFromFileExercisesRealLoaderPath() throws {
        let dir = NSTemporaryDirectory() + "v13b4b-\(UInt64.random(in: .min ... .max))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/egress-policy.json"
        let json = """
        {"modes":{"general":[{"id":"serve-anthropic","pattern":"api.anthropic.com","mode":"exact","decision":"allow"}]}}
        """
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        let (policy, degraded) = EgressPolicy.load(from: path)
        #expect(degraded == nil)
        #expect(policy.allows(host: "api.anthropic.com") == true)
        #expect(policy.serveEgressAllowHint() == nil)
    }

    @Test func missingPolicyFileFallsBackToDefaultsDenyWithHint() {
        // Absent egress-policy.json -> defaults() -> deny-on-miss -> hint.
        let absent = NSTemporaryDirectory() + "v13b4b-absent-\(UInt64.random(in: .min ... .max))/egress-policy.json"
        let (policy, degraded) = EgressPolicy.load(from: absent)
        #expect(degraded == nil)
        #expect(policy.allows(host: "api.anthropic.com") == false)
        #expect(policy.serveEgressAllowHint() != nil)
    }
}
