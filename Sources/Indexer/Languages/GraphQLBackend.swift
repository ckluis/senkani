import Foundation
import SwiftTreeSitter

/// GraphQL symbol-extraction backend.
///
/// GraphQL has its own dedicated walker so it doesn't share the
/// large central `walkNode` switch. The original reason was a
/// Swift 6 codegen SIGBUS on large unrelated ASTs when GraphQL's
/// node types were mixed in; lifting the walker out also makes
/// GraphQL trivially extendable in isolation.
///
/// Matches top-level schema definitions (object, interface, enum,
/// scalar, union, input object, directive) by name, recursing into
/// wrapper nodes (`document`, `definition`, `type_system_definition`,
/// `type_definition`) via a simple loop.
internal enum GraphQLBackend: TreeSitterLanguageBackend {

    static func supports(_ language: String) -> Bool {
        language == "graphql"
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
    // frames. Chain child of `indexer-backends-iterative-walk-refactor-
    // 2026-05-11` (GoBackend pilot + BashBackend / CBackend /
    // CppBackend / CSharpBackend / DartBackend / ElixirBackend
    // predecessors 2026-05-18). GraphQLBackend's substrate is the
    // simplest minor variant in the chain — one pre-refactor recursion
    // site, no container derivation. The dispatch shifts from
    // "iterate children, switch on child.nodeType" to "pop node,
    // switch on node.nodeType" — semantically identical because the
    // pop sequence reproduces the iteration order, and GraphQL's root
    // (`source_file` / `document`) never matches a definition kind so
    // the per-iteration child-emission semantics still hold. Definition
    // arms emit the entry without descent (matches pre-refactor "no
    // recurse on this child"); the default arm reverse-pushes children
    // with `currentContainer` preserved (matches pre-refactor
    // `walk(child, ..., container: container)` at line 52 of the
    // pre-refactor source). The malformed-definition edge case — node
    // matches a definition kind but `extractName` returns nil — falls
    // through to the default arm's child push, matching pre-refactor
    // behavior where `if let kind = …, let name = …` failing on `name`
    // triggers the `else if child.childCount > 0 { walk(child, …) }`
    // branch.
    private static func walk(
        _ root: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        var stack: [(Node, String?)] = [(root, container)]
        while let (node, currentContainer) = stack.popLast() {
            let type = node.nodeType ?? ""

            if let kind = definitionKind(type),
               let name = extractName(node, source: source) {
                entries.append(IndexEntry(
                    name: name, kind: kind, file: file,
                    startLine: TreeSitterBackend.startLine(of: node),
                    endLine: TreeSitterBackend.endLine(of: node),
                    signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                    container: currentContainer, engine: "tree-sitter"
                ))
                // No descent — matches pre-refactor (definition emit
                // without recurse into children).
                continue
            }

            // Default arm — push children in reverse so LIFO pop
            // preserves left-to-right pre-order traversal. Symbol-
            // emission order matches the pre-refactor recursive form
            // exactly. Container preserved (GraphQL has no
            // container-derivation arms).
            let count = Int(node.childCount)
            guard count > 0 else { continue }
            for i in stride(from: count - 1, through: 0, by: -1) {
                if let child = node.child(at: i) {
                    stack.append((child, currentContainer))
                }
            }
        }
    }

    // MARK: - GraphQL-only helpers

    /// Return the text of a GraphQL definition's `name` child node.
    /// GraphQL grammar treats `name` as a node type (not a field), so
    /// we look it up by type instead of `child(byFieldName:)`.
    private static func extractName(_ node: Node, source: NSString) -> String? {
        guard let nameNode = TreeSitterBackend.findChildByType(node, type: "name") else { return nil }
        return TreeSitterBackend.nodeText(nameNode, source: source)
    }

    /// Map a GraphQL top-level definition node type to a `SymbolKind`.
    /// - object_type_definition       → .class    (struct-like aggregate of fields)
    /// - interface_type_definition    → .interface
    /// - enum_type_definition         → .enum
    /// - input_object_type_definition → .struct   (input-only aggregate)
    /// - scalar_type_definition / union_type_definition → .type
    /// - directive_definition         → .function (callable-ish at use sites)
    private static func definitionKind(_ nodeType: String) -> SymbolKind? {
        switch nodeType {
        case "object_type_definition":       return .class
        case "interface_type_definition":    return .interface
        case "enum_type_definition":         return .enum
        case "input_object_type_definition": return .struct
        case "scalar_type_definition",
             "union_type_definition":        return .type
        case "directive_definition":         return .function
        default:                             return nil
        }
    }
}
