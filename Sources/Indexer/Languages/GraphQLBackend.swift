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

    private static func walk(
        _ node: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        for i in 0..<Int(node.childCount) {
            guard let child = node.child(at: i) else { continue }
            let type = child.nodeType ?? ""
            if let kind = definitionKind(type),
               let name = extractName(child, source: source) {
                entries.append(IndexEntry(
                    name: name, kind: kind, file: file,
                    startLine: TreeSitterBackend.startLine(of: child),
                    endLine: TreeSitterBackend.endLine(of: child),
                    signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                    container: container, engine: "tree-sitter"
                ))
            } else if child.childCount > 0 {
                walk(child, file: file, source: source, lines: lines, container: container, entries: &entries)
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
