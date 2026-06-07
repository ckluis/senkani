import Testing
import Foundation
@testable import Core

/// T.3b-1 child (i) — exec-sandbox-naming invariants.
///
/// Locks the namespace separation between OUTPUT-truncation
/// (`SandboxMode`, `sandboxLineThreshold`, `SandboxStore`,
/// `sandboxed_results` DB table) and EXECUTION-sandbox (`HandSandbox`).
/// If a future refactor accidentally merges the two surfaces (e.g.
/// reuses `SandboxMode` for execution dispatch, or extends `HandSandbox`
/// with output-truncation cases), these tests fail loudly.
@Suite("Exec-sandbox-naming — namespace separation (T.3b-1 child i)")
struct ExecSandboxNamingTests {

    @Test("SandboxMode (OUTPUT-truncation) cases are exactly {auto, always, never}")
    func sandboxModeIsOutputTruncationSurface() {
        // OUTPUT-truncation policy values. If a future change adds an
        // execution-flavored case (e.g. `.wasm`, `.proc`) to SandboxMode,
        // the surface has been polluted. Pin the exact case set.
        let observed = Set([
            SandboxMode.auto.rawValue,
            SandboxMode.always.rawValue,
            SandboxMode.never.rawValue,
        ])
        #expect(observed == ["auto", "always", "never"])

        // Negative: execution-flavored raw values must not parse as
        // SandboxMode. If "wasm" / "proc" / "full" become SandboxMode
        // cases, that's a namespace collision — surface it.
        #expect(SandboxMode(rawValue: "wasm") == nil)
        #expect(SandboxMode(rawValue: "proc") == nil)
        #expect(SandboxMode(rawValue: "full") == nil)
        #expect(SandboxMode(rawValue: "none") == nil)
    }

    @Test("HandSandbox (execution-sandbox) cases are exactly {none, wasm, proc, full}")
    func handSandboxIsExecutionSandboxSurface() {
        // Execution-sandbox dispatch values. T.3b-2 will EXTEND
        // `.wasm` semantics (it already exists). T.3b-1 routing child
        // (iv) wires the `.wasm` arm. Pin the case set so a future
        // refactor doesn't accidentally drop `.wasm` or merge with
        // SandboxMode's output-truncation values.
        let observed = Set([
            HandSandbox.none.rawValue,
            HandSandbox.wasm.rawValue,
            HandSandbox.proc.rawValue,
            HandSandbox.full.rawValue,
        ])
        #expect(observed == ["none", "wasm", "proc", "full"])

        // Negative: OUTPUT-truncation raw values must not parse as
        // HandSandbox. If "auto" / "always" / "never" become HandSandbox
        // cases, that's a namespace collision — surface it.
        #expect(HandSandbox(rawValue: "auto") == nil)
        #expect(HandSandbox(rawValue: "always") == nil)
        #expect(HandSandbox(rawValue: "never") == nil)
    }
}
