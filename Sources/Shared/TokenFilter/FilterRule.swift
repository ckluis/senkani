import Foundation

/// A single filter operation to apply to command output.
public enum FilterOp: Sendable {
    case stripANSI
    case head(Int)
    case tail(Int)
    case truncateBytes(Int)
    case keepMatching(String)
    case stripMatching(String)
    case dedupLines
    case groupSimilar(threshold: Int)
    case stripBlankRuns(max: Int)
}

/// A filter rule: matches commands and applies ordered operations.
public struct FilterRule: Sendable {
    /// Base command name to match (e.g. "git")
    public let command: String
    /// Optional subcommand to match (e.g. "status"). nil matches any subcommand.
    public let subcommand: String?
    /// Ordered list of operations to apply.
    public let ops: [FilterOp]

    public init(command: String, subcommand: String? = nil, ops: [FilterOp]) {
        self.command = command
        self.subcommand = subcommand
        self.ops = ops
    }

    /// Check if this rule matches a parsed command.
    public func matches(_ match: CommandMatcher.Match) -> Bool {
        guard match.base == command else { return false }
        if let sub = subcommand {
            return match.subcommand == sub
        }
        return true
    }
}
