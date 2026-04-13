import Foundation

/// A single diff hunk — a contiguous block of changes.
struct DiffHunk: Identifiable {
    let id = UUID()
    let removedLines: [String]
    let addedLines: [String]
    let originalStartLine: Int
    let modifiedStartLine: Int
    var resolution: Bool? = nil

    var isResolved: Bool { resolution != nil }
}

enum DiffEngine {

    /// Compute diff hunks between two strings using LCS at the line level.
    static func computeHunks(original: String, modified: String) -> [DiffHunk] {
        let origLines = original.components(separatedBy: "\n")
        let modLines = modified.components(separatedBy: "\n")
        let lcs = lcsTable(origLines, modLines)
        let ops = extractOps(origLines, modLines, lcs)
        return groupIntoHunks(ops)
    }

    /// Apply hunk resolutions to produce the final content.
    /// Accepted hunks keep the modified lines. Rejected hunks revert to original lines.
    static func applyResolutions(original: String, modified: String, hunks: [DiffHunk]) -> String {
        let origLines = original.components(separatedBy: "\n")
        let modLines = modified.components(separatedBy: "\n")
        let lcs = lcsTable(origLines, modLines)
        let ops = extractOps(origLines, modLines, lcs)

        var result: [String] = []
        var hunkIndex = 0
        var pendingRemoved: [String] = []
        var pendingAdded: [String] = []

        for op in ops {
            switch op {
            case .equal(let line, _, _):
                if !pendingRemoved.isEmpty || !pendingAdded.isEmpty {
                    if hunkIndex < hunks.count {
                        if hunks[hunkIndex].resolution == false {
                            result.append(contentsOf: pendingRemoved)
                        } else {
                            result.append(contentsOf: pendingAdded)
                        }
                        hunkIndex += 1
                    } else {
                        result.append(contentsOf: pendingAdded)
                    }
                    pendingRemoved = []
                    pendingAdded = []
                }
                result.append(line)

            case .remove(let line, _):
                pendingRemoved.append(line)

            case .add(let line, _):
                pendingAdded.append(line)
            }
        }

        // Flush trailing
        if !pendingRemoved.isEmpty || !pendingAdded.isEmpty {
            if hunkIndex < hunks.count {
                if hunks[hunkIndex].resolution == false {
                    result.append(contentsOf: pendingRemoved)
                } else {
                    result.append(contentsOf: pendingAdded)
                }
            } else {
                result.append(contentsOf: pendingAdded)
            }
        }

        return result.joined(separator: "\n")
    }

    // MARK: - LCS internals

    private enum DiffOp {
        case equal(line: String, origLine: Int, modLine: Int)
        case remove(line: String, origLine: Int)
        case add(line: String, modLine: Int)
    }

    private static func lcsTable(_ a: [String], _ b: [String]) -> [[Int]] {
        let m = a.count
        let n = b.count
        var table = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    table[i][j] = table[i - 1][j - 1] + 1
                } else {
                    table[i][j] = max(table[i - 1][j], table[i][j - 1])
                }
            }
        }
        return table
    }

    private static func extractOps(_ a: [String], _ b: [String], _ table: [[Int]]) -> [DiffOp] {
        var ops: [DiffOp] = []
        var i = a.count
        var j = b.count

        while i > 0 || j > 0 {
            if i > 0 && j > 0 && a[i - 1] == b[j - 1] {
                ops.append(.equal(line: a[i - 1], origLine: i, modLine: j))
                i -= 1
                j -= 1
            } else if j > 0 && (i == 0 || table[i][j - 1] >= table[i - 1][j]) {
                ops.append(.add(line: b[j - 1], modLine: j))
                j -= 1
            } else {
                ops.append(.remove(line: a[i - 1], origLine: i))
                i -= 1
            }
        }

        return ops.reversed()
    }

    private static func groupIntoHunks(_ ops: [DiffOp]) -> [DiffHunk] {
        var hunks: [DiffHunk] = []
        var currentRemoved: [String] = []
        var currentAdded: [String] = []
        var origStart: Int?
        var modStart: Int?

        for op in ops {
            switch op {
            case .equal:
                if !currentRemoved.isEmpty || !currentAdded.isEmpty {
                    hunks.append(DiffHunk(
                        removedLines: currentRemoved,
                        addedLines: currentAdded,
                        originalStartLine: origStart ?? 1,
                        modifiedStartLine: modStart ?? 1
                    ))
                    currentRemoved = []
                    currentAdded = []
                    origStart = nil
                    modStart = nil
                }

            case .remove(let line, let origLine):
                if origStart == nil { origStart = origLine }
                currentRemoved.append(line)

            case .add(let line, let modLine):
                if modStart == nil { modStart = modLine }
                if origStart == nil { origStart = modLine }
                currentAdded.append(line)
            }
        }

        if !currentRemoved.isEmpty || !currentAdded.isEmpty {
            hunks.append(DiffHunk(
                removedLines: currentRemoved,
                addedLines: currentAdded,
                originalStartLine: origStart ?? 1,
                modifiedStartLine: modStart ?? 1
            ))
        }

        return hunks
    }
}
