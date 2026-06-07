import Foundation
import SwiftTreeSitter

/// Go symbol-extraction backend.
///
/// Node coverage:
///   - function_declaration → top-level `func foo()` (.function)
///   - method_declaration → `func (r *T) Foo()` with receiver-based
///     container resolved by `extractGoMethod` (.method)
///   - type_declaration → wraps multiple `type_spec` children
///     (struct/interface/type alias). Each type_spec emits its own
///     entry via `extractGoTypeDeclaration` →
///     `extractGoTypeSpec`, which picks `.struct` / `.interface` /
///     `.type` from the spec's `type` field.
internal enum GoBackend: TreeSitterLanguageBackend {

    static func supports(_ language: String) -> Bool {
        language == "go"
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

    // Iterative work-stack of (node, container) tuples. Replaces a
    // recursive descent (former crash site, incident 7C27A798,
    // 2026-05-10) so AST depth no longer consumes Swift call frames.
    // Pilot child of `indexer-backends-iterative-walk-refactor-2026-05-11`.
    private static func walk(
        _ root: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        var stack: [(Node, String?)] = [(root, container)]
        while let (node, currentContainer) = stack.popLast() {
            let type = node.nodeType ?? ""

            switch type {
            case "function_declaration":
                if let entry = TreeSitterBackend.extractFunction(node, file: file, source: source, lines: lines, container: currentContainer) {
                    entries.append(entry)
                }
                // Bodies of top-level decls are not walked — matches the
                // pre-refactor recursive form (the switch arm returned
                // without recursing into children).

            case "method_declaration":
                if let entry = TreeSitterBackend.extractGoMethod(node, file: file, source: source, lines: lines) {
                    entries.append(entry)
                }

            case "type_declaration":
                TreeSitterBackend.extractGoTypeDeclaration(node, file: file, source: source, lines: lines, entries: &entries)

            default:
                // Push children in reverse so LIFO pop preserves
                // left-to-right pre-order traversal — symbol-emission
                // order matches the pre-refactor recursive form exactly.
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
}
