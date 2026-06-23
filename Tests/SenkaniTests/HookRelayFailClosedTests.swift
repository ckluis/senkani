import Testing
import Foundation
@testable import HookRelay

/// Carve 2 (the posture fix) for
/// `t6-hook-relay-5ms-deadline-drops-deny-decisions-2026-06-22`.
///
/// On a read-poll timeout for a DENY-CAPABLE hook (PreToolUse), the relay now
/// fails CLOSED — escalating to the human gate with `permissionDecision:"ask"`
/// — instead of silently approving (`{}`). Never-deny hooks and nil/unparseable
/// names stay fail-open; `SENKANI_HOOK_FAILCLOSED=off` disables it.
///
/// `run()` itself is structurally un-unit-testable (hardcoded socket path +
/// FileHandle stdio), so — exactly as `HookRelayHandshakeTests` /
/// `HookRelayDropCounterTests` do — these drive the PURE helpers the timeout
/// branch calls, never the live socket relay. No timing dependency.
@Suite("HookRelay fail-closed posture (carve 2)")
struct HookRelayFailClosedTests {

    // MARK: - isDenyCapable

    @Test func onlyPreToolUseIsDenyCapable() {
        #expect(HookRelay.isDenyCapable("PreToolUse") == true)
        #expect(HookRelay.isDenyCapable(nil) == false, "unparseable name → fail-OPEN (deliberate)")
        #expect(HookRelay.isDenyCapable("PostToolUse") == false)
        #expect(HookRelay.isDenyCapable("Notification") == false)
        #expect(HookRelay.isDenyCapable("Stop") == false)
        #expect(HookRelay.isDenyCapable("SubagentStop") == false)
    }

    // MARK: - timeoutAction (the read-timeout decision)

    @Test func failsClosedOnlyForDenyCapableWithSwitchOn() {
        #expect(HookRelay.timeoutAction(denyCapable: true,  failClosedEnabled: true)  == .failClosedAsk)
        #expect(HookRelay.timeoutAction(denyCapable: true,  failClosedEnabled: false) == .passthrough,
                "SENKANI_HOOK_FAILCLOSED=off → keep historical fail-open (headless/autonomous escape)")
        #expect(HookRelay.timeoutAction(denyCapable: false, failClosedEnabled: true)  == .passthrough,
                "never-deny hooks always pass through on timeout")
        #expect(HookRelay.timeoutAction(denyCapable: false, failClosedEnabled: false) == .passthrough)
    }

    // MARK: - pollDeadlineMs (the split deadline)

    @Test func denyCapableHooksGetTheLargerDeadline() {
        #expect(HookRelay.pollDeadlineMs(denyCapable: true,  override: nil) == 250,
                "deny-capable default deadline is 250ms — common case gets the real verdict")
        #expect(HookRelay.pollDeadlineMs(denyCapable: false, override: nil) == 5,
                "never-deny hooks keep the 5ms imperceptible deadline")
        #expect(HookRelay.pollDeadlineMs(denyCapable: true,  override: 1000) == 1000,
                "SENKANI_HOOK_DENY_DEADLINE_MS override applies to deny-capable hooks")
        #expect(HookRelay.pollDeadlineMs(denyCapable: false, override: 1000) == 5,
                "the override never lengthens a never-deny hook's deadline")
    }

    // MARK: - failClosedAskBody (the emitted JSON)

    @Test func failClosedBodyIsValidAskJSON() throws {
        let body = HookRelay.failClosedAskBody(eventName: nil)
        let obj = try #require(
            try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let hso = try #require(obj["hookSpecificOutput"] as? [String: Any])
        #expect(hso["permissionDecision"] as? String == "ask",
                "fail-closed escalates to the human gate, never fabricates a 'deny'")
        #expect(hso["hookEventName"] as? String == "PreToolUse",
                "nil event name defaults to PreToolUse in the emitted body")
        let reason = try #require(hso["permissionDecisionReason"] as? String)
        #expect(!reason.isEmpty)
        #expect(reason.contains("SENKANI_HOOK_FAILCLOSED"),
                "the reason tells the operator how to disable / tune")
    }

    @Test func failClosedBodyEchoesEventName() throws {
        let body = HookRelay.failClosedAskBody(eventName: "PreToolUse")
        let obj = try #require(
            try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let hso = try #require(obj["hookSpecificOutput"] as? [String: Any])
        #expect(hso["hookEventName"] as? String == "PreToolUse")
    }

    @Test func failClosedBodyEscapesInjectionInEventName() throws {
        // A hostile/garbled event name with an embedded quote must still
        // produce parseable JSON with the name round-tripping intact.
        let body = HookRelay.failClosedAskBody(eventName: #"weird"name\x"#)
        let obj = try #require(
            try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
            "escaped body must still be valid JSON")
        let hso = try #require(obj["hookSpecificOutput"] as? [String: Any])
        #expect(hso["hookEventName"] as? String == #"weird"name\x"#)
        #expect(hso["permissionDecision"] as? String == "ask")
    }
}
