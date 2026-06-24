import Foundation

/// Decides whether an `senkani autorun` run should force the hook relay's
/// **fail-OPEN** posture (`SENKANI_HOOK_FAILCLOSED=off`) into the environment it
/// spawns its children (and, in a later leg, the `claude` agent) under.
///
/// ## Why this exists
///
/// The hook relay's carve-2 posture (parent
/// `t6-hook-relay-5ms-deadline-drops-deny-decisions-2026-06-22`) makes the
/// deny-capable gate fail **closed** on a read-timeout by emitting
/// `permissionDecision: "ask"` (default on via `SENKANI_HOOK_FAILCLOSED`). For an
/// **interactive** operator an `ask` correctly pauses for their decision. But in
/// an **unattended** run there is nobody to answer it, so the `ask` becomes an
/// effective BLOCK — a slow `HookRouter.handle()` on a `PreToolUse` would wedge
/// the overnight loop instead of proceeding.
///
/// The relay cannot detect "is there an operator," but the autorun loop KNOWS
/// when it is running unattended (no TTY on stdin — the same condition that
/// already gates the supervise-first refusal). So the loop is the right place to
/// downgrade the relay to fail-open, scoped to genuinely-unattended runs only.
///
/// ## Posture (Schneier / Allspaw / Kleppmann)
///
/// Failing OPEN is a security downgrade, so it is deliberately narrow — only an
/// **unattended** run is ever touched:
///
/// - **Attended (TTY present)** → never override, whatever the env says. A
///   fail-closed `ask` is answerable, so the strong posture stays.
/// - **Unattended AND the variable is unset** → force `"off"` so the loop
///   exports the historical fail-open passthrough and cannot wedge.
/// - **Unattended AND the value normalizes to off-intent** (`"off"`, `"OFF"`,
///   `" off "`, …) → rewrite to the canonical `"off"`. The relay's read is a
///   STRICT, case-sensitive `(env ?? "on") != "off"`, so a non-canonical `"OFF"`
///   would be read as fail-CLOSED and still wedge — honoring the operator's
///   *intent* (not the raw bytes) closes that gap. (Already-canonical `"off"`
///   is left untouched.)
/// - **Unattended AND any other explicit value** (`"on"`, `""`, garbage) → never
///   override. That is a deliberate non-off choice; the unattended default is
///   overridable, and every non-`off` value lands the relay on its SAFE
///   (fail-closed) side, so respecting it can never make the run less safe.
///
/// ## Propagation contract (for the deferred `claude`-spawn leg)
///
/// The CLI applies the result via process-wide `setenv` before any child spawns,
/// so descendants inherit it. The relay (`HookRelay`, zero-dep, cannot import
/// Core per Lesson #12) reads the SAME `SENKANI_HOOK_FAILCLOSED` key from
/// `ProcessInfo.environment`. TODAY the only descendants are the `/bin/sh -c`
/// gate commands; the `claude` agent + its hook-relay subprocess arrive in a
/// LATER leg. Whoever wires that spawn MUST keep `claude` a child of the autorun
/// process and MUST NOT rebuild a curated `process.environment` dict that drops
/// this key (the `process.environment = …` idiom several other commands use),
/// or the override is silently lost and the wedge returns.
///
/// The decision is a pure function so the safety-critical branch is unit-tested
/// without touching `setenv`/`isatty` — mirroring `ProcessSupervisionPrompt.classify`
/// and `AutorunLoopDriver.unattendedRefusalReason`.
public enum AutorunHookFailClosedPolicy {
    /// The relay environment variable this policy governs.
    public static let envVarName = "SENKANI_HOOK_FAILCLOSED"

    /// The canonical value the relay reads as fail-open. MUST stay byte-equal to
    /// the literal `HookRelay` compares against (`!= "off"`); the cross-module
    /// posture test pins the two together.
    public static let failOpenValue = "off"

    /// Returns the value to set for ``envVarName`` in the autorun process's
    /// environment, or `nil` to leave the environment untouched.
    ///
    /// - Parameters:
    ///   - attendedOnTTY: `true` when an operator is on the stdin TTY (an `ask`
    ///     can be answered). Mirrors `isatty(STDIN_FILENO) == 1` in the CLI.
    ///   - existingValue: the current value of ``envVarName`` in the process
    ///     environment (`nil` when unset).
    /// - Returns: `"off"` for an unattended run that is unset or carries
    ///   off-intent in a non-canonical form; `nil` otherwise (attended, already
    ///   canonical `"off"`, or an explicit non-off value).
    public static func overrideValue(attendedOnTTY: Bool, existingValue: String?) -> String? {
        // Attended → the fail-closed `ask` is answerable; never touch the env.
        if attendedOnTTY { return nil }

        // Unattended AND unset → force fail-open so a slow PreToolUse can't wedge.
        guard let existingValue else { return failOpenValue }

        // Unattended AND explicitly set. Honor off-INTENT despite the relay's
        // case-sensitive contract: a value that normalizes to "off" but is not
        // already canonical is rewritten so the relay actually reads fail-open.
        let normalized = existingValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == failOpenValue {
            return existingValue == failOpenValue ? nil : failOpenValue
        }

        // Any other explicit value is a deliberate non-off choice → respect it.
        return nil
    }
}
