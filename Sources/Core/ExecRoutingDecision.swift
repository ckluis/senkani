import Foundation

/// T.3b-1 child (iv) — the v2 routing decision for `senkani_exec`.
///
/// **Operator decision (RATIFIED 2026-06-05 via `AskUserQuestion`, recorded
/// in `phase-t3b-1-input-shape-decision`).** `senkani_exec` `.userSupplied`
/// execution is re-scoped to **DENY-BY-DEFAULT / FAIL-CLOSED**. The host
/// `/bin/sh` path is reserved for EXPLICITLY-TRUSTED callers
/// (`.toolInternal`). NO third-party wasm shell is vendored, so there is no
/// sandboxed surface a user-supplied script could run on: a wasm/WASI guest
/// cannot fork/exec host binaries, so a vendored shell could never run the
/// host tools `senkani_exec` exists for. Meanwhile user-supplied scripts run
/// UNSANDBOXED on the host TODAY (`ExecTool.handle` → Foundation `Process`
/// `/bin/sh -c`). Fail-CLOSED closes that gap.
///
/// **Why a pure decision type.** Pulling the dispatch out of
/// `ExecTool.handle` (which needs a live `MCPSession` + spawns a real
/// `Process`) lets the security-load-bearing branch be unit-tested in
/// isolation — the deny-path tests assert `.userSupplied` → `.deny` (ZERO
/// host `Process` reachable) and the `.toolInternal` regression guard
/// asserts `.host`, without any MCP plumbing or subprocess.
///
/// **FAIL-CLOSED invariant.** A `.userSupplied` caller NEVER resolves to
/// `.host`. There is no code path — not a missing-sandbox fallback, not an
/// error branch — that downgrades a user-supplied script to the Foundation
/// `Process` host shell. The deny is the security deliverable, modeled on
/// `WasmtimeRunnerError.wasmtime_missing`: a structured refusal, never a
/// silent fallback. (See `WasmtimeSubprocessRuntime`.)
public enum ExecRoute: Equatable, Sendable {
    /// Run on the host via Foundation `Process` (`/bin/sh -c`). Reserved
    /// for EXPLICITLY-TRUSTED `.toolInternal` callers. This is today's
    /// path, unchanged.
    case host
    /// Refuse to execute. Returned for every `.userSupplied` caller under
    /// the ratified DENY-BY-DEFAULT posture, and for any future caller
    /// whose execution-sandbox runtime is unavailable. The associated
    /// `ExecDenyReason` drives the structured refusal + audit row at the
    /// `ExecTool.handle` boundary. NEVER falls back to `.host`.
    case deny(ExecDenyReason)
}

/// Structured reason a `senkani_exec` invocation was denied. Surfaced in
/// the MCP refusal text and the `exec.routing.denied` audit row so an
/// operator can tell a fail-CLOSED security deny apart from an ordinary
/// command failure.
public enum ExecDenyReason: String, Equatable, Sendable {
    /// `.userSupplied` caller under DENY-BY-DEFAULT. No sandboxed shell
    /// exists to run the command, and host `/bin/sh` is reserved for
    /// trusted callers — so the only safe action is to refuse. RCE-blocker:
    /// this is the row that proves an untrusted script did NOT reach the
    /// host shell.
    case userSuppliedDenyByDefault = "user_supplied_deny_by_default"
    /// A caller that WOULD route to the execution sandbox, but the sandbox
    /// runtime (`wasmtime`) is missing/unavailable. Modeled on
    /// `WasmtimeRunnerError.wasmtime_missing`. Reserved for the future
    /// trusted-opt-in-to-wasm path (t3b-2); today no caller reaches it,
    /// but the routing function fails CLOSED rather than falling back to
    /// the host if it ever does.
    case sandboxRuntimeUnavailable = "sandbox_runtime_unavailable"

    /// Operator-facing one-liner for the MCP refusal text.
    public var operatorMessage: String {
        switch self {
        case .userSuppliedDenyByDefault:
            return "user-supplied command refused: senkani_exec runs user-supplied scripts fail-CLOSED (DENY-BY-DEFAULT). Host execution is reserved for explicitly-trusted callers."
        case .sandboxRuntimeUnavailable:
            return "command refused: the execution sandbox runtime is unavailable and senkani_exec will not fall back to unsandboxed host execution."
        }
    }
}

/// Pure router for `ExecTool.handle`. The single place the v2 routing
/// branch decides host-vs-deny. `ExecTool.handle` calls `route(...)` and
/// switches on the result — it does NOT re-derive the policy inline.
public enum ExecRoutingDecision {

    /// Decide how to handle an `ExecTool` invocation.
    ///
    /// - `.userSupplied` → ALWAYS `.deny(.userSuppliedDenyByDefault)`. The
    ///   `sandboxAvailable` flag is irrelevant for user-supplied callers
    ///   under the ratified posture (no wasm shell is vendored, so even a
    ///   present `wasmtime` cannot run a host shell command) — fail CLOSED.
    /// - `.toolInternal` → `.host`. Trusted in-process callers keep today's
    ///   Foundation `Process` path. (A future trusted-opt-in-to-wasm path
    ///   under t3b-2 would route `.toolInternal` to the sandbox and, if
    ///   `sandboxAvailable == false`, deny via `.sandboxRuntimeUnavailable`
    ///   rather than fall back — see `sandboxAvailable` handling below.)
    ///
    /// - Parameters:
    ///   - callerKind: the classified caller (see `ExecCallerClassifier`).
    ///   - sandboxAvailable: whether the execution-sandbox runtime
    ///     (`wasmtime`) is present. Defaults `true`. Only consulted for a
    ///     caller that opts into the sandbox; today no caller does, so this
    ///     parameter exists to model the fail-CLOSED-on-missing-runtime
    ///     contract for the future t3b-2 trusted-wasm path. A `.toolInternal`
    ///     caller that has NOT opted into wasm ignores it and routes `.host`.
    ///   - wantsSandbox: whether the (trusted) caller has opted into wasm
    ///     dispatch via HandManifest. Defaults `false` (t3b-2 wires the
    ///     opt-in). When `true` and the runtime is missing, the router
    ///     fails CLOSED with `.sandboxRuntimeUnavailable` — NEVER `.host`.
    public static func route(
        callerKind: ExecCallerKind,
        sandboxAvailable: Bool = true,
        wantsSandbox: Bool = false
    ) -> ExecRoute {
        switch callerKind {
        case .userSupplied:
            // DENY-BY-DEFAULT. No fallback to host. No dependence on
            // sandbox availability — there is no shell module to run.
            return .deny(.userSuppliedDenyByDefault)
        case .toolInternal:
            if wantsSandbox {
                // Future t3b-2 trusted-opt-in-to-wasm path: route to the
                // sandbox if available, else FAIL CLOSED — never host.
                return sandboxAvailable ? .host : .deny(.sandboxRuntimeUnavailable)
                // NOTE: `.host` here is a placeholder for "dispatch to the
                // wasm runtime" until t3b-2 wires WasmtimeSubprocessRuntime
                // for trusted callers. The load-bearing property TODAY is
                // the fail-CLOSED on `!sandboxAvailable`; no untrusted
                // caller reaches this arm.
            }
            // Trusted caller, no wasm opt-in: today's host path, unchanged.
            return .host
        }
    }
}
