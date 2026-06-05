import Testing
import Foundation
@testable import Core

/// T.3b-1 child (iii) — caller-classifier invariants.
///
/// Pins the design decision: the classifier is NOT driven by
/// MCP arguments. Trusted Swift-API callers pass an explicit
/// `callerKindOverride: .toolInternal`; everything else (including
/// every MCP-arriving call) classifies as `.userSupplied`.
///
/// Defense-in-depth: child (iv) will route `.userSupplied` through
/// wasmtime by default. If a future change made the classifier
/// readable from `arguments?["..."]`, a prompt-injected MCP call
/// could claim `tool_internal` and bypass the sandbox. These tests
/// fail loudly if that ever happens.
@Suite("Exec-caller-classifier — invariants (T.3b-1 child iii)")
struct ExecCallerClassifierTests {

    @Test("classify(nil) → .userSupplied — MCP default")
    func defaultIsUserSupplied() {
        // Spec: positive test for `.userSupplied` classification on a
        // synthesized user-script call. The MCP entry point at
        // ExecTool.handle always passes `nil` (no trusted override
        // channel from MCP), so this is the lock-in for the MCP path.
        let kind = ExecCallerClassifier.classify(callerKindOverride: nil)
        #expect(kind == .userSupplied)
        #expect(kind.rawValue == "user_supplied")
    }

    @Test("classify(.toolInternal) → .toolInternal — trusted Swift-API override")
    func explicitOverrideRespected() {
        // Spec: positive test for `.toolInternal` classification on a
        // HandManifest-driven call without opt-in. In this round only
        // the override seam exists; child (iv) will wire HandManifest-
        // derived callers to pass `.toolInternal` here. The override
        // is the ONLY way to reach `.toolInternal`.
        let kind = ExecCallerClassifier.classify(callerKindOverride: .toolInternal)
        #expect(kind == .toolInternal)
        #expect(kind.rawValue == "tool_internal")
    }

    @Test("default-arg form classifies as .userSupplied")
    func defaultArgFormIsUserSupplied() {
        // Pins the no-argument call path (a future caller forgetting
        // to pass the override falls SAFE to .userSupplied — the
        // restrictive default).
        let kind = ExecCallerClassifier.classify()
        #expect(kind == .userSupplied)
    }
}
