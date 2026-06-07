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

    // Iterative work-stack of (node, container) tuples. Replaces a
    // recursive descent so AST depth no longer consumes Swift call
    // frames on the cooperative pool. Umbrella chain child of
    // `indexer-backends-iterative-walk-refactor-2026-05-11`
    // (alphabetical successor to SwiftBackend). TOML's substrate is
    // structurally distinct from every prior chain child — two
    // pre-refactor recursion sites, ONE body-rebind-with-emit arm
    // (`table` / `table_array_element` folded into a single case) and
    // one leaf-emit arm (`pair`). The body-rebind arm is the FIRST
    // chain child to recurse INTO the same node rather than a
    // separate body subtree: the pre-refactor's
    // `walk(child=table, container: name)` re-entered walk and
    // iterated the table_node's own children. The iterative
    // translation MUST NOT push the table node back onto the stack
    // with the new container — that would re-dispatch to the same
    // arm, re-emit, and re-push, infinite-looping. Instead, the arm
    // unrolls one step: it reverse-pushes the table_node's
    // **children** onto the stack with container re-bound to the
    // table name. Each grandchild popped individually then dispatches
    // — `[` / `]` brackets and key tokens fall through default
    // (childless, no-op), `pair` children match the pair arm and
    // emit with container = table name. Closest precedent is
    // PhpBackend's `namespace_definition` arm in that both rebind
    // container for descendants, but PHP pushes a separate body
    // subtree (`findBody` resolved) while TOML pushes the grandchildren
    // directly to avoid the same-node loop. The default arm
    // reverse-pushes children with currentContainer preserved so LIFO
    // pop reproduces left-to-right pre-order — symbol-emission order
    // matches pre-refactor exactly.
    private static func walk(
        _ root: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        var stack: [(Node, String?)] = [(root, container)]
        while let (node, currentContainer) = stack.popLast() {
            let type = node.nodeType ?? ""

            switch type {
            // [table] + [[table_array_element]] headers — fold into a
            // single case to match the dispatcher's prior shape (the
            // historical reason was a Swift-6 codegen stack-overflow
            // on adjacent identical cases in the much-larger central
            // switch; harmless here, kept for symmetry with the spec).
            case "table", "table_array_element":
                if let name = extractTableName(node, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .extension, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                    // Pre-refactor: `walk(child=table, container: name)`
                    // re-entered walk and iterated table_node.children.
                    // Iterative form unrolls one step — reverse-push the
                    // table_node's CHILDREN (NOT the table node itself,
                    // which would infinite-loop on re-dispatch) with the
                    // table name as container. Pairs inside the table
                    // then match the pair arm and emit with container =
                    // table name.
                    let count = Int(node.childCount)
                    guard count > 0 else { continue }
                    for i in stride(from: count - 1, through: 0, by: -1) {
                        if let child = node.child(at: i) {
                            stack.append((child, name))
                        }
                    }
                }

            case "pair":
                if let name = extractPairKey(node, source: source) {
                    let kind: SymbolKind = currentContainer != nil ? .property : .variable
                    entries.append(IndexEntry(
                        name: name, kind: kind, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                }
                // No descent — pair is leaf-emit; matches pre-refactor.

            default:
                // Push children in reverse so LIFO pop preserves
                // left-to-right pre-order traversal — symbol-emission
                // order matches the pre-refactor recursive form
                // exactly. The pre-refactor default arm guarded with
                // `if child.childCount > 0`; the iterative form's
                // `guard count > 0 else continue` reproduces that —
                // childless leaves popped here fall through as a
                // no-op exactly as the pre-refactor's guard skipped
                // them.
                let count = Int(node.childCount)
                guard count > 0 else { continue }
                for i in stride(from: count - 1, through: 0, by: -1) {
                    if let child = node.child(at: i) {
                        stack.append((child, currentContainer))
                    }
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
