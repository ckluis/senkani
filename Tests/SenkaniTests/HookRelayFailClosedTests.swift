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

    // MARK: - env-flag parsing is trim + case-insensitive
    //   (hook-relay-env-flag-parsing-case-insensitive-2026-06-24)

    @Test func normalizeFlagValueTrimsAndLowercases() {
        #expect(HookRelay.normalizeFlagValue("OFF", default: "on") == "off")
        #expect(HookRelay.normalizeFlagValue("Off", default: "on") == "off")
        #expect(HookRelay.normalizeFlagValue(" off ", default: "on") == "off")
        #expect(HookRelay.normalizeFlagValue("\toff\n", default: "on") == "off")
        #expect(HookRelay.normalizeFlagValue("ON", default: "off") == "on")
        #expect(HookRelay.normalizeFlagValue(" On ", default: "off") == "on")
        #expect(HookRelay.normalizeFlagValue(nil, default: "on") == "on", "unset → default")
        #expect(HookRelay.normalizeFlagValue(nil, default: "off") == "off")
        #expect(HookRelay.normalizeFlagValue("", default: "on") == "", "explicit empty stays empty (not the default)")
        #expect(HookRelay.normalizeFlagValue("Garbage", default: "on") == "garbage")
    }

    @Test func failClosedIsCaseAndWhitespaceInsensitive() {
        // Default ON when unset; fail-OPEN ONLY for a normalized exact "off".
        #expect(HookRelay.isFailClosed(fromRaw: nil) == true, "unset defaults fail-CLOSED")
        #expect(HookRelay.isFailClosed(fromRaw: "off") == false)
        #expect(HookRelay.isFailClosed(fromRaw: "OFF") == false, "uppercase OFF now means fail-open (was the foot-gun)")
        #expect(HookRelay.isFailClosed(fromRaw: "Off") == false)
        #expect(HookRelay.isFailClosed(fromRaw: " off ") == false, "stray whitespace tolerated")
        #expect(HookRelay.isFailClosed(fromRaw: "on") == true)
        #expect(HookRelay.isFailClosed(fromRaw: "ON") == true)
        #expect(HookRelay.isFailClosed(fromRaw: "") == true, "empty → fail-CLOSED (safe side)")
        #expect(HookRelay.isFailClosed(fromRaw: "garbage") == true, "garbage → fail-CLOSED (safe side)")
    }

    @Test func activationIsCaseAndWhitespaceInsensitive() {
        // SENKANI_INTERCEPT or SENKANI_HOOK == "on" enables; both default off.
        #expect(HookRelay.isActivated(intercept: "on", hook: nil) == true)
        #expect(HookRelay.isActivated(intercept: "ON", hook: nil) == true)
        #expect(HookRelay.isActivated(intercept: " On ", hook: nil) == true)
        #expect(HookRelay.isActivated(intercept: nil, hook: "on") == true)
        #expect(HookRelay.isActivated(intercept: nil, hook: "ON") == true)
        #expect(HookRelay.isActivated(intercept: nil, hook: nil) == false, "both unset → off")
        #expect(HookRelay.isActivated(intercept: "off", hook: "off") == false)
        #expect(HookRelay.isActivated(intercept: " off ", hook: " off ") == false)
        #expect(HookRelay.isActivated(intercept: "garbage", hook: "garbage") == false, "only exact 'on' activates")
    }

    // MARK: - read-timeout drop-log reason (forced-fail-open marker)
    //   (hook-relay-forced-failopen-droplog-marker-2026-06-24)

    @Test func readTimeoutDropReasonDistinguishesForcedFailOpen() {
        // deny-capable + fail-closed → escalate to the human ask.
        #expect(HookRelay.readTimeoutDropReason(denyCapable: true, failClosedEnabled: true)
                == "read_timeout_failclosed_ask")
        // deny-capable + fail-OPEN → forced downgrade; DISTINCT from a normal
        // passthrough so an auditor can find auto-downgraded runs.
        #expect(HookRelay.readTimeoutDropReason(denyCapable: true, failClosedEnabled: false)
                == "read_timeout_failopen_forced")
        // never-deny hook → the historical generic passthrough reason (unchanged),
        // regardless of the FAILCLOSED posture.
        #expect(HookRelay.readTimeoutDropReason(denyCapable: false, failClosedEnabled: true)
                == "read_timeout")
        #expect(HookRelay.readTimeoutDropReason(denyCapable: false, failClosedEnabled: false)
                == "read_timeout")
    }
}
