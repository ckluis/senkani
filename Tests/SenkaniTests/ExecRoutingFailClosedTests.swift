import Testing
import Foundation
import MCP
@testable import Core
@testable import MCPServer

/// T.3b-1 child (iv) — v2 routing branch + FAIL-CLOSED deny-path tests.
///
/// **Operator decision (RATIFIED 2026-06-05, `phase-t3b-1-input-shape-
/// decision`).** `senkani_exec` `.userSupplied` execution is DENY-BY-
/// DEFAULT / fail-CLOSED. Host `/bin/sh` is reserved for explicitly-
/// trusted `.toolInternal` callers. NO wasm shell is vendored; the
/// POSITIVE wasm-shell path (a shell running a sandboxed command) and its
/// 2 positive acceptance tests are DEFERRED INDEFINITELY — fail-CLOSED IS
/// the security deliverable. Those positive tests are NOT placeholdered
/// here (no `.skip`/`@disabled`); they are tracked by
/// `phase-t3b-1-input-shape-decision` (DEFERRED, tests_target lowered to 0).
///
/// This suite pins the deny-path: the load-bearing security branch that
/// proves an untrusted user-supplied script can NEVER reach the host
/// shell, plus the `.toolInternal` regression guard that the trusted
/// host path is unchanged, plus the fail-CLOSED-on-missing-runtime
/// contract modeled on `WasmtimeRunnerError.wasmtime_missing`.
@Suite("Exec-routing — fail-CLOSED deny path (T.3b-1 child iv)")
struct ExecRoutingFailClosedTests {

    // MARK: - Pure routing decision (Core)

    @Test("RCE-blocker: .userSupplied routes to .deny — NEVER .host, regardless of sandbox availability")
    func userSuppliedAlwaysDenies() {
        // The fail-CLOSED invariant. A user-supplied caller must deny
        // whether or not the sandbox runtime is present — there is no
        // wasm shell to run on, and host /bin/sh is reserved for trusted
        // callers. If this ever returns `.host`, an untrusted script
        // reaches the host shell — RCE.
        for available in [true, false] {
            let route = ExecRoutingDecision.route(
                callerKind: .userSupplied,
                sandboxAvailable: available
            )
            #expect(route == .deny(.userSuppliedDenyByDefault),
                    "user-supplied must deny with sandboxAvailable=\(available); got \(route)")
            #expect(route != .host,
                    "FAIL-CLOSED breach: user-supplied routed to host (sandboxAvailable=\(available))")
        }
    }

    @Test("regression guard: .toolInternal (no wasm opt-in) routes to .host — trusted path unchanged")
    func toolInternalRoutesToHost() {
        // Trusted in-process callers keep today's Foundation Process host
        // path. This is the back-compat / DEFAULT-SAFETY assertion: the
        // fail-CLOSED change does NOT regress trusted callers.
        let route = ExecRoutingDecision.route(callerKind: .toolInternal)
        #expect(route == .host)
    }

    @Test("FAIL-CLOSED on missing runtime: trusted wasm-opt-in + sandbox unavailable → .deny, NEVER .host")
    func trustedWasmOptInFailsClosedOnMissingRuntime() {
        // Models `WasmtimeRunnerError.wasmtime_missing`: a future t3b-2
        // trusted-opt-in-to-wasm caller whose sandbox runtime is missing
        // must refuse — it must NOT silently fall back to the host shell.
        // No untrusted caller reaches this arm today, but the routing
        // function fails CLOSED if a future caller does.
        let denied = ExecRoutingDecision.route(
            callerKind: .toolInternal,
            sandboxAvailable: false,
            wantsSandbox: true
        )
        #expect(denied == .deny(.sandboxRuntimeUnavailable),
                "missing sandbox runtime must deny, not fall back to host; got \(denied)")
        #expect(denied != .host, "FAIL-CLOSED breach: missing-runtime fell back to host")

        // Available runtime + trusted opt-in dispatches (placeholder
        // `.host` until t3b-2 wires the wasm runtime for trusted callers).
        let dispatched = ExecRoutingDecision.route(
            callerKind: .toolInternal,
            sandboxAvailable: true,
            wantsSandbox: true
        )
        #expect(dispatched == .host)
    }

    @Test("T.3b-2: deny message is legible — names what was refused, why, and what to do")
    func denyMessageIsLegible() {
        // Jobs/Allspaw polish (2026-06-08): the refusal must be actionable,
        // not a cryptic error. The user-supplied deny must say WHAT was
        // refused, WHY (the fail-CLOSED posture), and WHAT TO DO INSTEAD.
        let userMsg = ExecDenyReason.userSuppliedDenyByDefault.operatorMessage
        // WHAT was refused.
        #expect(userMsg.lowercased().contains("refused"),
                "deny message must say the command was refused; got: \(userMsg)")
        // WHY — the fail-CLOSED / deny-by-default posture (back-compat with
        // the tokens ExecRoutingFailClosedTests + ExecTool integration assert).
        #expect(userMsg.contains("DENY-BY-DEFAULT") || userMsg.contains("fail-CLOSED"),
                "deny message must explain the fail-CLOSED posture; got: \(userMsg)")
        // WHAT TO DO INSTEAD — the legibility deliverable.
        #expect(userMsg.contains("What to do instead"),
                "deny message must tell the user what to do instead; got: \(userMsg)")

        // The runtime-unavailable deny is legible too.
        let rtMsg = ExecDenyReason.sandboxRuntimeUnavailable.operatorMessage
        #expect(rtMsg.lowercased().contains("refused"))
        #expect(rtMsg.contains("fail-CLOSED"),
                "runtime-unavailable deny must explain fail-CLOSED; got: \(rtMsg)")
        #expect(rtMsg.contains("What to do instead"),
                "runtime-unavailable deny must tell the user what to do; got: \(rtMsg)")
    }

    @Test("deny reasons carry distinct stable audit tokens")
    func denyReasonsHaveStableTokens() {
        // The audit-row `reason` field must be a stable, machine-greppable
        // token so an operator can tell a security deny apart from a
        // command failure. Pin the raw values.
        #expect(ExecDenyReason.userSuppliedDenyByDefault.rawValue == "user_supplied_deny_by_default")
        #expect(ExecDenyReason.sandboxRuntimeUnavailable.rawValue == "sandbox_runtime_unavailable")
        #expect(ExecDenyReason.userSuppliedDenyByDefault != ExecDenyReason.sandboxRuntimeUnavailable)
    }

    // MARK: - Integration through ExecTool.handle (MCPServer)

    /// The MCP surface is hard-wired `.userSupplied` (no trusted-override
    /// channel from MCP args). This drives the real `ExecTool.handle` with
    /// a command that, were it to reach the host shell, would print
    /// `SENTINEL_RAN` to stdout. The deny path must:
    ///   1. return `isError == true` with the structured refusal text,
    ///   2. NOT contain the sentinel (proving ZERO host Process spawned).
    ///
    /// **No Logger sink / `.loggerSinkGate` here, by design.** Installing a
    /// process-global `Logger._setTestSink` while this test also constructs
    /// an `MCPSession` (whose `init` warms a WebKit-XPC `WebFetchEngine`
    /// that logs through the same global sink) deadlocks under the
    /// cooperative-pool + sink-gate serialization in this harness — a
    /// pre-existing concurrency hazard, NOT a routing bug. The
    /// `exec.routing.denied` audit-row emission is covered structurally by
    /// the deny-reason-token unit test above + the `Logger.log(...)` call
    /// in `ExecTool.handle`; this test pins the load-bearing wiring
    /// (handle → deny → return, ZERO host Process) via the return value,
    /// which is the RCE-blocker contract.
    @Test
    func mcpUserSuppliedExecIsDeniedAndNeverSpawnsHostProcess() async {
        let session = MCPSession(projectRoot: "/tmp/exec-routing-deny-\(UUID().uuidString)")
        // A command whose stdout would betray host execution. If the
        // routing branch leaked to Foundation Process, the result text
        // would contain SENTINEL_RAN.
        let args: [String: Value] = ["command": .string("echo SENTINEL_RAN")]
        let result = await ExecTool.handle(arguments: args, session: session)

        // 1. Structured refusal.
        #expect(result.isError == true, "user-supplied exec must return isError")
        let text = result.content.compactMap { item -> String? in
            if case .text(let t, _, _) = item { return t }
            return nil
        }.joined(separator: "\n")
        #expect(text.contains("DENY-BY-DEFAULT") || text.contains("fail-CLOSED")
                || text.lowercased().contains("refused"),
                "refusal text must explain the fail-CLOSED deny; got: \(text)")

        // 2. ZERO host Process — the sentinel must NOT appear. This is the
        //    RCE-blocker assertion: a real /bin/sh -c run would have
        //    printed SENTINEL_RAN into the output.
        #expect(!text.contains("SENTINEL_RAN"),
                "FAIL-CLOSED breach: host shell executed the user-supplied command (sentinel found)")
    }
}
