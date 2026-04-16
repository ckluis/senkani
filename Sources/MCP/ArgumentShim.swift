import Foundation
import MCP

/// P2-10: Argument vocabulary shim for MCP tools.
///
/// Canonicalizes escape-hatch argument names so clients have one consistent
/// vocabulary across tools. Currently translates `detail: "summary"|"full"`
/// on `senkani_knowledge` + `senkani_validate` into the canonical
/// `full: true|false` (the name `senkani_read` has always used).
///
/// Pure function — no session state. Callers (ToolRouter) filter returned
/// deprecations through `MCPSession.noteDeprecation` so warnings fire only
/// once per session. Removed entirely when `tool_schemas_version` bumps to 2
/// (next release, per `/Users/clank/.claude/plans/p2-10-escape-hatch-vocabulary.md`).
public enum ArgumentShim {

    public struct Deprecation: Sendable {
        /// Stable session-scope identifier, e.g. "knowledge.detail".
        public let key: String
        /// Human-readable, actionable warning text appended to the tool result.
        public let message: String
    }

    public struct Normalization: Sendable {
        public let arguments: [String: Value]?
        public let deprecations: [Deprecation]
    }

    public static func normalize(
        toolName: String,
        arguments: [String: Value]?
    ) -> Normalization {
        guard let raw = arguments else {
            return Normalization(arguments: nil, deprecations: [])
        }

        switch toolName {
        case "knowledge", "validate":
            return normalizeDetailToFull(toolName: toolName, args: raw)
        default:
            return Normalization(arguments: raw, deprecations: [])
        }
    }

    // MARK: - Private

    private static func normalizeDetailToFull(
        toolName: String,
        args: [String: Value]
    ) -> Normalization {
        guard let detailValue = args["detail"] else {
            return Normalization(arguments: args, deprecations: [])
        }

        var out = args
        var deps: [Deprecation] = []
        let key = "\(toolName).detail"

        let raw = detailValue.stringValue ?? ""
        let lower = raw.lowercased()

        let mapped: Bool?
        switch lower {
        case "full":    mapped = true
        case "summary": mapped = false
        default:        mapped = nil
        }

        if let mapped = mapped {
            // Conflict: caller also set canonical `full`. `full` wins.
            if let existingFull = args["full"]?.boolValue {
                deps.append(Deprecation(
                    key: key,
                    message: "[senkani deprecation] senkani_\(toolName) received both 'detail' and 'full'; ignoring deprecated 'detail' (\"\(raw)\") and using 'full: \(existingFull)'. Drop 'detail' when you update your client."
                ))
            } else {
                out["full"] = .bool(mapped)
                deps.append(Deprecation(
                    key: key,
                    message: "[senkani deprecation] senkani_\(toolName).detail is renamed to 'full'. Pass 'full: \(mapped)' instead of 'detail: \"\(raw)\"'. Removed in tool_schemas_version 2."
                ))
            }
            out.removeValue(forKey: "detail")
        } else {
            // Unknown value — leave the arg alone but warn the caller.
            deps.append(Deprecation(
                key: key,
                message: "[senkani deprecation] senkani_\(toolName) got detail:\"\(raw)\" which is not a recognized value. Valid: full:true or full:false. 'detail' is removed in tool_schemas_version 2."
            ))
        }

        return Normalization(arguments: out, deprecations: deps)
    }
}
