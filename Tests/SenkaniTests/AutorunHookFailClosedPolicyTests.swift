import Testing
@testable import Core

/// Coverage for `AutorunHookFailClosedPolicy.overrideValue` — the pure decision
/// behind the unattended-autorun fail-open guard
/// (`hook-relay-failclosed-autorun-unattended-optout-2026-06-22`). The helper is
/// a total pure function, so these tests are fully hermetic — no `setenv`,
/// `isatty`, process, or TTY. Mirrors the `unattendedRefusalReason` /
/// `ProcessSupervisionPrompt.classify` decision-table pattern.
@Suite("autorun hook fail-closed opt-out policy")
struct AutorunHookFailClosedPolicyTests {

    // MARK: - Cross-module relay-posture mirror

    /// Mirror of `HookRelay`'s posture predicate `(env ?? "on") != "off"`.
    /// HookRelay is zero-dep (cannot import Core, Lesson #12), so the literal is
    /// duplicated here on purpose — the posture tests below assert the helper's
    /// chosen value, once relayed through THIS predicate, yields the intended
    /// posture, so a drift between the two `"off"` literals turns a test red.
    private static func relayFailClosed(_ env: String?) -> Bool { (env ?? "on") != "off" }

    /// The env value a child actually inherits after the guard runs: the
    /// override if any, else the operator's existing value.
    private static func finalEnv(attendedOnTTY: Bool, existing: String?) -> String? {
        AutorunHookFailClosedPolicy.overrideValue(attendedOnTTY: attendedOnTTY, existingValue: existing) ?? existing
    }

    // MARK: - Decision table

    @Test("unattended + unset → forces fail-open (off)")
    func unattendedUnsetForcesOff() {
        #expect(
            AutorunHookFailClosedPolicy.overrideValue(attendedOnTTY: false, existingValue: nil)
                == AutorunHookFailClosedPolicy.failOpenValue
        )
        #expect(AutorunHookFailClosedPolicy.failOpenValue == "off")
    }

    @Test("attended → never override, whatever the env says (the `ask` is answerable)")
    func attendedNeverOverrides() {
        #expect(AutorunHookFailClosedPolicy.overrideValue(attendedOnTTY: true, existingValue: nil) == nil)
        #expect(AutorunHookFailClosedPolicy.overrideValue(attendedOnTTY: true, existingValue: "on") == nil)
        #expect(AutorunHookFailClosedPolicy.overrideValue(attendedOnTTY: true, existingValue: "off") == nil)
        #expect(AutorunHookFailClosedPolicy.overrideValue(attendedOnTTY: true, existingValue: "OFF") == nil)
    }

    @Test("unattended + already-canonical `off` → no override (relay already fail-open)")
    func unattendedCanonicalOffLeftAlone() {
        #expect(AutorunHookFailClosedPolicy.overrideValue(attendedOnTTY: false, existingValue: "off") == nil)
    }

    @Test("unattended + non-canonical off-intent (OFF / Off / ` off `) → normalized to `off`")
    func unattendedNormalizesOffIntent() {
        #expect(AutorunHookFailClosedPolicy.overrideValue(attendedOnTTY: false, existingValue: "OFF") == "off")
        #expect(AutorunHookFailClosedPolicy.overrideValue(attendedOnTTY: false, existingValue: "Off") == "off")
        #expect(AutorunHookFailClosedPolicy.overrideValue(attendedOnTTY: false, existingValue: "  off ") == "off")
    }

    @Test("unattended + explicit non-off value (on / garbage) → respected, never overridden")
    func unattendedExplicitNonOffRespected() {
        #expect(AutorunHookFailClosedPolicy.overrideValue(attendedOnTTY: false, existingValue: "on") == nil)
        #expect(AutorunHookFailClosedPolicy.overrideValue(attendedOnTTY: false, existingValue: "garbage") == nil)
    }

    @Test("unattended empty-string is an explicit non-off value → respected (relay stays fail-CLOSED, the safe side)")
    func unattendedEmptyStringRespected() {
        // Security-load-bearing: an injected empty value must NOT downgrade —
        // it is not off-intent, so the helper leaves it and the relay stays
        // fail-closed. Isolated so a future refactor cannot silently drop it.
        #expect(AutorunHookFailClosedPolicy.overrideValue(attendedOnTTY: false, existingValue: "") == nil)
        #expect(Self.relayFailClosed("") == true)
    }

    // MARK: - Cross-module posture (helper output × relay predicate)

    @Test("unattended off-intent → relay fail-OPEN; explicit non-off → relay fail-CLOSED")
    func unattendedRelayPosture() {
        // Off-intent (unset / canonical / case / whitespace) → relay fail-OPEN.
        for existing in [nil, "off", "OFF", "Off", "  off "] as [String?] {
            #expect(Self.relayFailClosed(Self.finalEnv(attendedOnTTY: false, existing: existing)) == false)
        }
        // Explicit non-off → relay fail-CLOSED (the operator's deliberate strict choice).
        for existing in ["on", "", "garbage"] as [String?] {
            #expect(Self.relayFailClosed(Self.finalEnv(attendedOnTTY: false, existing: existing)) == true)
        }
    }

    @Test("attended posture is whatever the operator set — the guard never changes it")
    func attendedRelayPostureUntouched() {
        // Attended: finalEnv == existing for every input (no override).
        for existing in [nil, "off", "OFF", "on", ""] as [String?] {
            #expect(Self.finalEnv(attendedOnTTY: true, existing: existing) == existing)
        }
    }

    @Test("env var name matches the relay's read key")
    func envVarNameContract() {
        #expect(AutorunHookFailClosedPolicy.envVarName == "SENKANI_HOOK_FAILCLOSED")
    }
}
