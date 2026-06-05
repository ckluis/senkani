import Foundation

/// T.3b-1 child (iii) — caller classifier for the `senkani_exec` v2
/// routing branch. Identifies whether an `ExecTool.handle` invocation
/// originated from a USER-SUPPLIED script (default-on for wasmtime
/// dispatch in child (iv)) or from a TOOL-INTERNAL caller (Foundation
/// `Process` unless HandManifest opts in via `HandSandbox.wasm`).
///
/// **Security boundary (Torvalds + Schneier):** the MCP arg surface
/// is operator-untrusted — a hostile prompt-injected call could try
/// to impersonate a tool-internal caller to bypass the wasm dispatch
/// child (iv) lands as the user-script default. The classifier is
/// therefore NOT driven by an MCP argument; it is driven by an
/// out-of-band Swift-API override that only a tool-internal Swift
/// caller can set. The MCP code path is unconditionally
/// `.userSupplied` regardless of any `arguments?["..."]` content.
///
/// **No behavioral change in this round.** Child (iii) lands the
/// enum + classifier + ExecTool.handle threading only. The kind is
/// computed at handle() entry but does NOT drive any branching yet.
/// Child (iv) wires the dispatch:
///   - `.userSupplied` → wasmtime subprocess runtime (fail-CLOSED on
///     `.wasmtime_missing` — never falls back to Foundation Process).
///   - `.toolInternal` + `HandSandbox.wasm` opt-in → wasmtime.
///   - `.toolInternal` (no opt-in) → Foundation Process (today's path).
///
/// For execution-sandbox surface details see `HandSandbox` in
/// `HandManifest.swift`. For OUTPUT-truncation surface see
/// `SandboxMode` in `OutputSandbox.swift`.
public enum ExecCallerKind: String, Sendable, Equatable {
    /// MCP-arriving call from an operator-untrusted source (prompt,
    /// user-typed shell command, etc.). Child (iv) defaults this to
    /// wasmtime dispatch.
    case userSupplied = "user_supplied"
    /// Swift-API call from a trusted in-process caller (e.g.
    /// HandManifest-driven validation, AutoValidateWorker). Child (iv)
    /// keeps these on Foundation `Process` unless the manifest opts
    /// in via `HandSandbox.wasm`.
    case toolInternal = "tool_internal"
}

/// Pure classifier for `ExecTool.handle` invocations.
///
/// **Design**: the override defaults to `nil`, which classifies as
/// `.userSupplied`. Only trusted Swift-API callers can pass an
/// explicit `.toolInternal` override. The MCP entry point at
/// `ExecTool.handle` always passes `nil` so the user cannot
/// impersonate a tool-internal caller via any MCP argument. This is
/// a DEFENSE-IN-DEPTH choice — if a future arg-driven classifier is
/// proposed, the burden of proof is on the proposer to show the MCP
/// surface cannot be abused to bypass child (iv)'s wasm default.
public enum ExecCallerClassifier {
    /// Classify an ExecTool invocation. Returns `.toolInternal` IFF
    /// the caller is a trusted in-process Swift-API caller AND has
    /// passed an explicit override; otherwise `.userSupplied`.
    ///
    /// MCP-arriving calls MUST pass `callerKindOverride: nil` (the
    /// MCP path cannot supply a trusted override — there is no
    /// authenticated channel for an MCP arg to claim trust).
    public static func classify(
        callerKindOverride: ExecCallerKind? = nil
    ) -> ExecCallerKind {
        return callerKindOverride ?? .userSupplied
    }
}
