import Foundation
import SwiftTreeSitter

/// Incremental tree-sitter re-parsing via edit detection and Tree.edit().
/// Computes the minimal edit between old and new content using prefix/suffix
/// diffing on UTF-8 bytes, then applies the edit to the old tree before
/// re-parsing — letting tree-sitter reuse unchanged subtrees.
public enum IncrementalParser {

    /// Detect the edit between old and new content, returning an InputEdit
    /// suitable for MutableTree.edit(). Returns nil if contents are identical.
    public static func detectEdit(oldContent: String, newContent: String) -> InputEdit? {
        let oldBytes = Array(oldContent.utf8)
        let newBytes = Array(newContent.utf8)

        // Common prefix
        var prefixLen = 0
        let minLen = min(oldBytes.count, newBytes.count)
        while prefixLen < minLen && oldBytes[prefixLen] == newBytes[prefixLen] {
            prefixLen += 1
        }

        // Common suffix (don't overlap with prefix)
        var suffixLen = 0
        let maxSuffix = min(oldBytes.count - prefixLen, newBytes.count - prefixLen)
        while suffixLen < maxSuffix
            && oldBytes[oldBytes.count - 1 - suffixLen] == newBytes[newBytes.count - 1 - suffixLen] {
            suffixLen += 1
        }

        // Identical content
        if prefixLen + suffixLen >= oldBytes.count && prefixLen + suffixLen >= newBytes.count {
            return nil
        }

        let startByte = UInt32(prefixLen)
        let oldEndByte = UInt32(oldBytes.count - suffixLen)
        let newEndByte = UInt32(newBytes.count - suffixLen)

        let startPoint = byteOffsetToPoint(oldBytes, offset: Int(startByte))
        let oldEndPoint = byteOffsetToPoint(oldBytes, offset: Int(oldEndByte))
        let newEndPoint = byteOffsetToPoint(newBytes, offset: Int(newEndByte))

        return InputEdit(
            startByte: startByte,
            oldEndByte: oldEndByte,
            newEndByte: newEndByte,
            startPoint: startPoint,
            oldEndPoint: oldEndPoint,
            newEndPoint: newEndPoint
        )
    }

    /// Incrementally re-parse a file using a cached old tree.
    /// Clones the old tree before editing so the caller's reference stays valid.
    /// Returns nil on parse failure.
    public static func reparse(
        oldTree: MutableTree,
        oldContent: String,
        newContent: String,
        language: String
    ) -> MutableTree? {
        guard let edit = detectEdit(oldContent: oldContent, newContent: newContent) else {
            return oldTree  // No change
        }

        guard let treeCopy = oldTree.mutableCopy() else { return nil }
        guard let tsLanguage = TreeSitterBackend.language(for: language) else { return nil }
        let parser = Parser()
        do { try parser.setLanguage(tsLanguage) } catch { return nil }

        treeCopy.edit(edit)
        return parser.parse(tree: treeCopy, string: newContent)
    }

    // MARK: - Private

    /// Convert a byte offset into UTF-8 content to a tree-sitter Point (row, column).
    private static func byteOffsetToPoint(_ bytes: [UInt8], offset: Int) -> Point {
        var row: UInt32 = 0
        var col: UInt32 = 0
        for i in 0..<min(offset, bytes.count) {
            if bytes[i] == 0x0A {
                row += 1
                col = 0
            } else {
                col += 1
            }
        }
        return Point(row: row, column: col)
    }
}
