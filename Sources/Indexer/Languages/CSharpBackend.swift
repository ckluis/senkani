import Foundation
import SwiftTreeSitter

/// C# symbol-extraction backend.
///
/// C# uses the `name`-field idiom for most declarations, so most
/// extraction routes through `extractTSDeclaration` (named for its
/// first user — works for any grammar with a `name` field + optional
/// `body` field).
///
/// Namespaces emit as `.extension` and recurse into their bodies
/// without setting `container:` — namespaces don't appear in the
/// container column on emitted symbols. File-scoped namespaces
/// (`namespace Foo;`) walk all subsequent siblings under the same
/// rule.
///
/// Node coverage:
///   - class_declaration (.class, body recursed)
///   - struct_declaration / record_declaration (.struct, body recursed)
///   - interface_declaration (.interface, body recursed)
///   - enum_declaration (.enum, body recursed)
///   - delegate_declaration (.type)
///   - namespace_declaration (.extension, body recursed without container)
///   - file_scoped_namespace_declaration (.extension, sibling walk)
///   - method_declaration / constructor_declaration / destructor_declaration (.method/.function)
///   - property_declaration (.property)
internal enum CSharpBackend: TreeSitterLanguageBackend {

    static func supports(_ language: String) -> Bool {
        language == "csharp"
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
    // recursive descent so AST depth no longer consumes Swift call
    // frames. Chain child of `indexer-backends-iterative-walk-refactor-
    // 2026-05-11` (GoBackend pilot 2026-05-18, BashBackend / CBackend /
    // CppBackend predecessors 2026-05-18). CSharpBackend's substrate is
    // closest to CppBackend's — class / struct / record / interface /
    // enum body pushes re-bind container to the type's name; namespace
    // body pushes preserve currentContainer (C# namespaces don't appear
    // in the container column, per the docstring above). File-scoped
    // namespace pushes its own children with container preserved,
    // matching the recursive form's `walk(child, ...)` re-entry on the
    // node itself.
    private static func walk(
        _ root: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        var stack: [(Node, String?)] = [(root, container)]
        while let (node, currentContainer) = stack.popLast() {
            let type = node.nodeType ?? ""

            switch type {
            case "class_declaration":
                if let (entry, body) = TreeSitterBackend.extractTSDeclaration(node, kind: .class, file: file, source: source, lines: lines, container: currentContainer) {
                    entries.append(entry)
                    if let body = body {
                        // Re-bind container to the class name for the
                        // body's descendants — matches pre-refactor
                        // `walk(body, ..., container: entry.name)`.
                        stack.append((body, entry.name))
                    }
                }

            case "struct_declaration", "record_declaration":
                if let (entry, body) = TreeSitterBackend.extractTSDeclaration(node, kind: .struct, file: file, source: source, lines: lines, container: currentContainer) {
                    entries.append(entry)
                    if let body = body {
                        stack.append((body, entry.name))
                    }
                }

            case "interface_declaration":
                if let (entry, body) = TreeSitterBackend.extractTSDeclaration(node, kind: .interface, file: file, source: source, lines: lines, container: currentContainer) {
                    entries.append(entry)
                    if let body = body {
                        stack.append((body, entry.name))
                    }
                }

            case "enum_declaration":
                if let (entry, body) = TreeSitterBackend.extractTSDeclaration(node, kind: .enum, file: file, source: source, lines: lines, container: currentContainer) {
                    entries.append(entry)
                    if let body = body {
                        stack.append((body, entry.name))
                    }
                }

            case "delegate_declaration":
                if let name = TreeSitterBackend.nodeName(node, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .type, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                }
                // No descent — matches pre-refactor.

            case "namespace_declaration":
                if let name = TreeSitterBackend.nodeName(node, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .extension, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                }
                // Body recursion lives OUTSIDE the name-found guard —
                // anonymous-namespace edge cases still descend. Container
                // is PRESERVED (not rebound to the namespace name) per
                // the docstring contract.
                if let body = TreeSitterBackend.findBody(node) {
                    stack.append((body, currentContainer))
                }

            case "file_scoped_namespace_declaration":
                if let name = TreeSitterBackend.nodeName(node, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .extension, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                }
                // Recursive form does `walk(child, ..., container)` —
                // it re-enters the walk on the node itself, iterating
                // its children via the switch. In the iterative form,
                // push the node's children directly (reverse for LIFO
                // pre-order), container preserved.
                let count = Int(node.childCount)
                guard count > 0 else { continue }
                for i in stride(from: count - 1, through: 0, by: -1) {
                    if let child = node.child(at: i) {
                        stack.append((child, currentContainer))
                    }
                }

            case "method_declaration", "constructor_declaration", "destructor_declaration":
                if let entry = TreeSitterBackend.extractFunction(node, file: file, source: source, lines: lines, container: currentContainer) {
                    entries.append(entry)
                }
                // No descent — matches pre-refactor.

            case "property_declaration":
                if let name = TreeSitterBackend.nodeName(node, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .property, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                }
                // No descent — matches pre-refactor.

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
