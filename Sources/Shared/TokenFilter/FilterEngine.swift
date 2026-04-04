import Foundation

/// The core token filter engine. Takes a shell command and its raw output,
/// applies matching filter rules, and returns the filtered output.
///
/// The terminal displays full, unfiltered output. Only the output tracked
/// for LLM context gets filtered. The user never loses information.
public final class FilterEngine: Sendable {
    public let rules: [FilterRule]

    public init(rules: [FilterRule] = BuiltinRules.rules) {
        self.rules = rules
    }

    /// Filter command output. Returns the filtered string and whether
    /// any filtering was applied.
    public func filter(command: String, output: String) -> FilterResult {
        let rawBytes = output.utf8.count

        guard let match = CommandMatcher.parse(command) else {
            return FilterResult(output: output, wasFiltered: false,
                                rawBytes: rawBytes, filteredBytes: rawBytes, command: command)
        }

        // Find first matching rule (more specific rules should come first)
        guard let rule = rules.first(where: { $0.matches(match) }) else {
            return FilterResult(output: output, wasFiltered: false,
                                rawBytes: rawBytes, filteredBytes: rawBytes, command: command)
        }

        var result = output
        for op in rule.ops {
            result = apply(op, to: result)
        }

        let filteredBytes = result.utf8.count
        return FilterResult(
            output: result,
            wasFiltered: result != output,
            rawBytes: rawBytes,
            filteredBytes: filteredBytes,
            command: command
        )
    }

    private func apply(_ op: FilterOp, to input: String) -> String {
        switch op {
        case .stripANSI:
            return ANSIStripper.strip(input)
        case .head(let n):
            return LineOperations.head(input, count: n)
        case .tail(let n):
            return LineOperations.tail(input, count: n)
        case .truncateBytes(let max):
            return LineOperations.truncateBytes(input, max: max)
        case .keepMatching(let pattern):
            return LineOperations.keepMatching(input, pattern: pattern)
        case .stripMatching(let pattern):
            return LineOperations.stripMatching(input, pattern: pattern)
        case .dedupLines:
            return LineOperations.dedup(input)
        case .groupSimilar(let threshold):
            return LineOperations.groupSimilar(input, threshold: threshold)
        case .stripBlankRuns(let max):
            return LineOperations.stripBlankRuns(input, max: max)
        }
    }
}

public struct FilterResult: Sendable {
    public let output: String
    public let wasFiltered: Bool
    public let rawBytes: Int
    public let filteredBytes: Int
    public let command: String

    public var savedBytes: Int { rawBytes - filteredBytes }
    public var savingsPercent: Double {
        guard rawBytes > 0 else { return 0 }
        return Double(savedBytes) / Double(rawBytes) * 100
    }
}
