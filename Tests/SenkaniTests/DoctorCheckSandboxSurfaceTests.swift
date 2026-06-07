import Testing
import Foundation
@testable import CLI
@testable import Core

/// `phase-t3b-6-doctor-check-sandbox-closeout` (re-scoped per the ratified
/// operator decision 2026-06-05).
///
/// The original acceptance (subprocess shim + corpus pass-rate, e.g.
/// 41/50) is MOOT under the ratified DENY-BY-DEFAULT / fail-CLOSED posture
/// (`ExecRoutingDecision`, commit ec72a1f): there is no positive sandboxed
/// surface, so there is no corpus to pass. The re-scoped surface,
/// `senkani doctor --check-sandbox`, instead reports the ACTUAL exec-
/// routing posture DERIVED from the live `ExecRoutingDecision` — not a
/// hardcoded string.
///
/// These tests pin that derivation: the posture lines must reflect what
/// `ExecRoutingDecision.route(...)` actually decides for each
/// `ExecCallerKind`, the headline must read "deny-by-default / fail-CLOSED",
/// and the fail-CLOSED breach flag (the exit-code driver) must be false
/// while the router denies user-supplied callers.
@Suite("Doctor --check-sandbox — deny-by-default posture (T.3b-6, re-scoped)")
struct DoctorCheckSandboxSurfaceTests {

    @Test("headline posture is deny-by-default / fail-CLOSED, no breach")
    func headlinePostureIsDenyByDefault() {
        let posture = Doctor.deriveSandboxPosture()

        #expect(!posture.failClosedBreached,
                "ExecRoutingDecision denies user-supplied callers — the fail-CLOSED invariant must hold (no breach)")

        let headline = posture.lines.first
        guard let headline else {
            Issue.record("expected a headline posture line, got none")
            return
        }
        #expect(headline.1.contains("deny-by-default"),
                "headline must state deny-by-default; got: \(headline.1)")
        #expect(headline.1.contains("fail-CLOSED"),
                "headline must state fail-CLOSED; got: \(headline.1)")
        // The headline is a PASS only because the router actually denies.
        if case .pass = headline.0 {} else {
            Issue.record("headline must be a PASS line when the router denies; got status \(headline.0)")
        }
    }

    @Test("posture names userSupplied-deny + toolInternal-host facts")
    func postureNamesUserSuppliedDenyAndToolInternalHost() {
        let posture = Doctor.deriveSandboxPosture()
        let joined = posture.lines.map(\.1).joined(separator: "\n")

        // user-supplied REFUSED, carrying the stable deny-reason token.
        #expect(joined.contains("user-supplied scripts: REFUSED"),
                "posture must name user-supplied scripts as REFUSED; got:\n\(joined)")
        #expect(joined.contains(ExecDenyReason.userSuppliedDenyByDefault.rawValue),
                "posture must carry the userSupplied deny-reason token; got:\n\(joined)")
        #expect(joined.contains("no host /bin/sh fallback"),
                "posture must state there is NO host fallback for user-supplied; got:\n\(joined)")

        // tool-internal → host path.
        #expect(joined.contains("tool-internal callers: host path"),
                "posture must name the tool-internal host path; got:\n\(joined)")

        // positive wasm path deferred / fails CLOSED.
        #expect(joined.contains("positive wasm sandbox path: deferred"),
                "posture must report the positive wasm path as deferred; got:\n\(joined)")
        #expect(joined.contains(ExecDenyReason.sandboxRuntimeUnavailable.rawValue),
                "posture must carry the sandbox-runtime-unavailable deny token; got:\n\(joined)")
    }

    @Test("posture is derived from ExecRoutingDecision (matches the live router)")
    func postureMatchesLiveRouter() {
        // The surface must not diverge from the source of truth. Re-probe
        // the router directly and assert the posture's PASS/SKIP statuses
        // track the actual routes — this is what makes the doctor output
        // honest rather than a hardcoded claim.
        let userSupplied = ExecRoutingDecision.route(callerKind: .userSupplied)
        let toolInternal = ExecRoutingDecision.route(callerKind: .toolInternal)

        #expect(userSupplied == .deny(.userSuppliedDenyByDefault),
                "precondition: router denies user-supplied (if this fails, the posture surface SHOULD report a breach)")
        #expect(toolInternal == .host,
                "precondition: router routes tool-internal to host")

        let posture = Doctor.deriveSandboxPosture()
        // Because the router denies user-supplied, the user-supplied fact
        // line must be a PASS (it is SKIP only if the router stopped
        // denying).
        let userLine = posture.lines.first { $0.1.contains("user-supplied scripts: REFUSED") }
        guard let userLine else {
            Issue.record("expected a user-supplied REFUSED line, got: \(posture.lines.map(\.1))")
            return
        }
        if case .pass = userLine.0 {} else {
            Issue.record("user-supplied line must be PASS while the router denies; got \(userLine.0)")
        }
    }

    @Test("no FAIL lines while the fail-CLOSED invariant holds")
    func noFailLinesWhenInvariantHolds() {
        let posture = Doctor.deriveSandboxPosture()
        let failLines = posture.lines.filter { line in
            if case .fail = line.0 { return true }
            return false
        }
        #expect(failLines.isEmpty,
                "no FAIL lines expected while ExecRoutingDecision denies user-supplied; got: \(failLines.map(\.1))")
    }
}
