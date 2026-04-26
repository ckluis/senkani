import Foundation
import SwiftTreeSitter

/// TOML symbol-extraction backend.
///
/// TOML symbols come in two flavors:
///   - `[table]` and `[[table_array_element]]` headers → emitted as
///     `.extension` (the closest analogue we have for a named scope
///     of pairs).
///   - `pair` (`key = value`) → emitted as `.property` when nested
///     inside a table, else `.variable`.
///
/// The walk is recursive so nested pairs inherit the table name as
/// their `container`. Top-level pairs (before any header) get
/// `container: nil`.
///
/// Worked example for adding a language: see this file as the
/// minimal reference. ~70 LOC including header doc comment.
internal enum TomlBackend: TreeSitterLanguageBackend {

    static func supports(_ language: String) -> Bool {
        language == "toml"
    }

    static func extractSymbols(
        from root: Node,
        file: String,
        source: NSString,
        lines: [String],
        container: String?,
        entries: inout [IndexEntry]
    ) {
        walk(root, file: file, source: source, lines: lines, container: container, entries: &entries)
    }

    // MARK: - Walk

    private static func walk(
        _ node: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        for i in 0..<Int(node.childCount) {
            guard let child = node.child(at: i) else { continue }
            let type = child.nodeType ?? ""

            switch type {
            // [table] + [[table_array_element]] headers — fold into a
            // single case to match the dispatcher's prior shape (the
            // historical reason was a Swift-6 codegen stack-overflow
            // on adjacent identical cases in the much-larger central
            // switch; harmless here, kept for symmetry with the spec).
            case "table", "table_array_element":
                if let name = extractTableName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .extension, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                    walk(child, file: file, source: source, lines: lines, container: name, entries: &entries)
                }

            case "pair":
                if let name = extractPairKey(child, source: source) {
                    let kind: SymbolKind = container != nil ? .property : .variable
                    entries.append(IndexEntry(
                        name: name, kind: kind, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            default:
                if child.childCount > 0 {
                    walk(child, file: file, source: source, lines: lines, container: container, entries: &entries)
                }
            }
        }
    }

    // MARK: - TOML-only helpers (kept private — only this backend uses them)

    /// Extract the header key from a TOML `table` or `table_array_element`.
    /// Children order is [ `[` or `[[`, key_node, `]` or `]]`, ...pairs ]; the
    /// key node is `bare_key`, `quoted_key`, or `dotted_key`.
    private static func extractTableName(_ node: Node, source: NSString) -> String? {
        for i in 0..<Int(node.childCount) {
            guard let child = node.child(at: i) else { continue }
            switch child.nodeType ?? "" {
            case "bare_key", "quoted_key", "dotted_key":
                return TreeSitterBackend.nodeText(child, source: source)
            default:
                continue
            }
        }
        return nil
    }

    /// Extract the LHS key from a TOML `pair` (`key = value`).
    private static func extractPairKey(_ node: Node, source: NSString) -> String? {
        for i in 0..<Int(node.childCount) {
            guard let child = node.child(at: i) else { continue }
            switch child.nodeType ?? "" {
            case "bare_key", "quoted_key", "dotted_key":
                return TreeSitterBackend.nodeText(child, source: source)
            default:
                continue
            }
        }
        return nil
    }
}
