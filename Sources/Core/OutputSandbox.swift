import Foundation

/// Controls when large outputs are **truncated** (stored to the
/// `sandboxed_results` DB table, summary returned to the caller).
///
/// **Scope clarification (T.3b-1 child (i) — exec-sandbox-naming, 2026-06-05):**
/// `SandboxMode` governs OUTPUT TRUNCATION, NOT process execution.
/// The naming is historical — "sandbox" here means "put the large output
/// aside so the caller gets a summary." The DB table is also named
/// `sandboxed_results` for the same historical reason.
///
/// For EXECUTION sandboxing (running a command inside wasmtime / a
/// constrained process / a full hand-manifest sandbox), see
/// `HandSandbox` in `HandManifest.swift`. The two surfaces share the
/// word "sandbox" but are independent enums with distinct semantics;
/// T.3b-2 will extend `HandSandbox.wasm` semantics — there is no
/// collision between `SandboxMode` and `HandSandbox` (the original
/// t3b-1 P0-#3 collision claim was incorrect).
public enum SandboxMode: String, Sendable {
    case auto   // Sandbox if output exceeds line threshold (default)
    case always // Always sandbox, even small outputs
    case never  // Never sandbox, return full output
}

/// Outputs with more lines than this trigger output-truncation in
/// `SandboxMode.auto`. See `SandboxMode` doc-comment for naming
/// scope (OUTPUT-truncation, NOT execution).
public let sandboxLineThreshold = 20

/// Number of head/tail lines to include in the sandbox summary.
private let previewLines = 5

/// Build a compact summary for sandboxed output.
/// Shows head + tail lines, total line/byte counts, and the retrieve ID.
public func buildSandboxSummary(output: String, lineCount: Int, byteCount: Int, resultId: String) -> String {
    let lines = output.components(separatedBy: "\n")
    let head = lines.prefix(previewLines).joined(separator: "\n")
    let tail = lines.suffix(previewLines).joined(separator: "\n")
    let omitted = lineCount - (previewLines * 2)

    var summary = "// output sandboxed: \(lineCount) lines, \(byteCount) bytes\n"
    summary += "// retrieve full output: senkani_session(action: 'result', result_id: '\(resultId)')\n"
    summary += head + "\n"
    if omitted > 0 {
        summary += "// ... \(omitted) lines omitted ...\n"
    }
    summary += tail
    return summary
}
