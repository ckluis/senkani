import Testing
import Foundation
@testable import Core

/// T.3b-5a — `classifyKill` arm-ordering fix (pure-function carve of the
/// blocked escape-attempt suite `phase-t3b-5-escape-attempt-suite`).
///
/// The bug (shipped before this fix): `classifyKill` checked the
/// timeout/interrupt/epoch stderr arm BEFORE the capability-denial
/// (escape) arm. A genuine WASI capability-denial whose stderr happened
/// to also contain the substring "timeout" or "interrupt" misclassified
/// as `.epoch`. That is the worst audit failure mode (Schneier P1): an
/// escape that reads as a benign timeout silently undercounts escapes in
/// the eventual zero-escape suite.
///
/// The fix re-orders the arms so the capability-denial markers
/// (`permission denied` / `not allowed` / `wasi … denied` / `unknown
/// import` / `capability`) are checked BEFORE the timeout/interrupt/epoch
/// markers. `fuel` stays first (a self-terminating soft cap, never an
/// escape); `watchdogFired` short-circuits to `.epoch` above the stderr
/// inspection (the host watchdog only arms past the wall-time deadline,
/// so a watchdog kill is by construction an epoch deadline, not a
/// denial).
@Suite("WasmtimeSubprocessRuntime — T.3b-5a classifyKill arm-ordering")
struct WasmClassifyKillArmOrderingTests {

    /// Test 1 (the bug-fix): a denial whose stderr ALSO contains
    /// "timeout"/"interrupt" classifies `.escape`, never `.epoch`.
    @Test("denial markers win over timeout/interrupt substrings ⇒ .escape (silent-undercount fix)")
    func denialBeatsTimeoutSubstring() {
        // permission-denial + "timeout" substring — was misclassified .epoch.
        #expect(
            WasmtimeSubprocessRuntime.classifyKill(
                stderr: "wasi: permission denied (operation timed out waiting on socket)",
                watchdogFired: false
            ) == .escape
        )
        // not-allowed + "interrupt" substring.
        #expect(
            WasmtimeSubprocessRuntime.classifyKill(
                stderr: "fd_write not allowed; guest interrupt followed",
                watchdogFired: false
            ) == .escape
        )
        // wasi … denied + "timeout".
        #expect(
            WasmtimeSubprocessRuntime.classifyKill(
                stderr: "wasi sock_connect denied — connection timeout",
                watchdogFired: false
            ) == .escape
        )
        // unknown import (the classic escape signal) + "timeout".
        #expect(
            WasmtimeSubprocessRuntime.classifyKill(
                stderr: "error: unknown import: `env::__exec` — timeout while linking",
                watchdogFired: false
            ) == .escape
        )
        // capability marker + "interrupt".
        #expect(
            WasmtimeSubprocessRuntime.classifyKill(
                stderr: "capability not granted for path; interrupt signal raised",
                watchdogFired: false
            ) == .escape
        )
    }

    /// Test 2 (no regression): a pure timeout/interrupt/epoch with NO
    /// denial marker still classifies `.epoch`.
    @Test("pure timeout/interrupt/epoch with no denial marker ⇒ .epoch (no regression)")
    func pureTimeoutStillEpoch() {
        #expect(
            WasmtimeSubprocessRuntime.classifyKill(
                stderr: "wasm trap: interrupt",
                watchdogFired: false
            ) == .epoch
        )
        #expect(
            WasmtimeSubprocessRuntime.classifyKill(
                stderr: "execution exceeded timeout",
                watchdogFired: false
            ) == .epoch
        )
        #expect(
            WasmtimeSubprocessRuntime.classifyKill(
                stderr: "epoch deadline reached",
                watchdogFired: false
            ) == .epoch
        )
    }

    /// Test 3 (arm coverage): watchdog short-circuit, fuel, and crash
    /// fallback all still classify correctly.
    @Test("watchdog ⇒ .epoch regardless of stderr; fuel ⇒ .fuel; unrecognized ⇒ .crash")
    func armCoverage() {
        // watchdogFired short-circuits to .epoch even when stderr carries a
        // denial marker (the host watchdog only arms past the wall-time
        // deadline — by construction an epoch deadline, not a denial).
        #expect(
            WasmtimeSubprocessRuntime.classifyKill(
                stderr: "wasi: permission denied",
                watchdogFired: true
            ) == .epoch
        )
        // fuel marker ⇒ .fuel (self-terminating soft cap, never an escape).
        #expect(
            WasmtimeSubprocessRuntime.classifyKill(
                stderr: "all fuel consumed by WebAssembly",
                watchdogFired: false
            ) == .fuel
        )
        // fuel takes precedence even if a denial marker is also present
        // (fuel exhaustion is a self-terminating cap, not a host syscall).
        #expect(
            WasmtimeSubprocessRuntime.classifyKill(
                stderr: "all fuel consumed; permission denied side note",
                watchdogFired: false
            ) == .fuel
        )
        // unrecognized stderr ⇒ .crash fallback (unchanged).
        #expect(
            WasmtimeSubprocessRuntime.classifyKill(
                stderr: "segmentation fault in host glue",
                watchdogFired: false
            ) == .crash
        )
        // empty stderr ⇒ .crash.
        #expect(
            WasmtimeSubprocessRuntime.classifyKill(
                stderr: "",
                watchdogFired: false
            ) == .crash
        )
    }
}
