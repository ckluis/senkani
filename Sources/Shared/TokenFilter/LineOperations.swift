import Foundation

public enum LineOperations {
    /// Keep only the first N lines.
    public static func head(_ input: String, count: Int) -> String {
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count <= count { return input }
        let kept = lines.prefix(count)
        let truncated = lines.count - count
        return kept.joined(separator: "\n") + "\n... (\(truncated) lines truncated)"
    }

    /// Keep only the last N lines.
    public static func tail(_ input: String, count: Int) -> String {
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count <= count { return input }
        let truncated = lines.count - count
        return "... (\(truncated) lines truncated)\n" + lines.suffix(count).joined(separator: "\n")
    }

    /// Truncate to max bytes at a line boundary.
    public static func truncateBytes(_ input: String, max: Int) -> String {
        if input.utf8.count <= max { return input }
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
        var result = ""
        var byteCount = 0
        for line in lines {
            let lineBytes = line.utf8.count + 1  // +1 for newline
            if byteCount + lineBytes > max { break }
            if !result.isEmpty { result += "\n" }
            result += line
            byteCount += lineBytes
        }
        return result + "\n... (output truncated at \(max) bytes)"
    }

    /// Remove lines containing a substring.
    public static func stripMatching(_ input: String, pattern: String) -> String {
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.filter { !$0.contains(pattern) }
        let removed = lines.count - kept.count
        var result = kept.joined(separator: "\n")
        if removed > 0 {
            result += "\n... (\(removed) lines filtered)"
        }
        return result
    }

    /// Keep only lines containing a substring.
    public static func keepMatching(_ input: String, pattern: String) -> String {
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.filter { $0.contains(pattern) }
        return kept.joined(separator: "\n")
    }

    /// Remove consecutive duplicate lines, showing count.
    public static func dedup(_ input: String) -> String {
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
        guard !lines.isEmpty else { return input }

        var result: [String] = []
        var current = lines[0]
        var count = 1

        for line in lines.dropFirst() {
            if line == current {
                count += 1
            } else {
                if count > 1 {
                    result.append("\(current) (repeated \(count)x)")
                } else {
                    result.append(String(current))
                }
                current = line
                count = 1
            }
        }
        // Flush last group
        if count > 1 {
            result.append("\(current) (repeated \(count)x)")
        } else {
            result.append(String(current))
        }

        return result.joined(separator: "\n")
    }

    /// Collapse runs of consecutive similar lines (same prefix) into a summary.
    /// Lines are "similar" if they share the first `prefixLength` characters.
    public static func groupSimilar(_ input: String, threshold: Int, prefixLength: Int = 20) -> String {
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
        guard !lines.isEmpty else { return input }

        var result: [String] = []
        var groupStart = 0

        func prefix(of line: Substring) -> Substring {
            line.prefix(min(prefixLength, line.count))
        }

        var i = 1
        while i <= lines.count {
            let isEnd = i == lines.count
            let isSimilar = !isEnd && prefix(of: lines[i]) == prefix(of: lines[groupStart])

            if isSimilar {
                i += 1
                continue
            }

            // End of group
            let groupSize = i - groupStart
            if groupSize >= threshold {
                result.append(String(lines[groupStart]))
                result.append("... (\(groupSize - 1) similar lines)")
            } else {
                for j in groupStart..<i {
                    result.append(String(lines[j]))
                }
            }
            groupStart = i
            i += 1
        }

        return result.joined(separator: "\n")
    }

    /// Collapse runs of blank lines exceeding `max` into `max` blank lines.
    public static func stripBlankRuns(_ input: String, max: Int) -> String {
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [String] = []
        var blankCount = 0

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blankCount += 1
                if blankCount <= max {
                    result.append(String(line))
                }
            } else {
                blankCount = 0
                result.append(String(line))
            }
        }

        return result.joined(separator: "\n")
    }
}
