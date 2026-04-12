import Foundation

/// Controls when large outputs are sandboxed (stored in DB, summary returned).
public enum SandboxMode: String, Sendable {
    case auto   // Sandbox if output exceeds line threshold (default)
    case always // Always sandbox, even small outputs
    case never  // Never sandbox, return full output
}

/// Outputs with more lines than this trigger sandboxing in `auto` mode.
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
