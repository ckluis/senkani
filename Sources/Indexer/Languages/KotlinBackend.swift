import Foundation
import SwiftTreeSitter

/// Kotlin symbol-extraction backend.
///
/// Kotlin's grammar uses positional children rather than named
/// fields, so symbol-name lookups go via `findChildByType` (e.g.
/// `simple_identifier` for functions and properties,
/// `type_identifier` for classes / objects / type aliases) instead
/// of `nodeName`'s field-based path used by TypeScript and Swift.
///
/// `class_declaration` covers class, sealed class, data class,
/// interface, and inner class — all parse as the same node.
/// `object_declaration` and `companion_object` act as containers
/// like classes; `companion_object`'s name defaults to "Companion"
/// when no explicit identifier is present.
internal enum KotlinBackend: TreeSitterLanguageBackend {

    static func supports(_ language: String) -> Bool {
        language == "kotlin"
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
    // 2026-05-11` (closest precedent: JavaBackend's multi-site
    // class/interface/enum/record/annotation_type rebind pattern).
    // Kotlin's substrate has three body-rebind arms — class_declaration
    // (covers class / sealed class / data class / interface / inner
    // class), object_declaration, and companion_object — each emits
    // then pushes the body with container re-bound to the declared
    // name, matching pre-refactor `walk(body, ..., container: name)`.
    // companion_object's name defaults to "Companion" when no
    // type_identifier child is present; the iterative form preserves
    // that by computing `name` before emission/body push.
    // function_declaration, property_declaration, and type_alias emit
    // without descent. The default arm reverse-pushes children with
    // currentContainer preserved so LIFO pop reproduces left-to-right
    // pre-order — symbol-emission order matches pre-refactor exactly.
    private static func walk(
        _ root: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        var stack: [(Node, String?)] = [(root, container)]
        while let (node, currentContainer) = stack.popLast() {
            let type = node.nodeType ?? ""

            switch type {
            case "function_declaration":
                if let nameNode = TreeSitterBackend.findChildByType(node, type: "simple_identifier"),
                   let name = TreeSitterBackend.nodeText(nameNode, source: source) {
                    let kind: SymbolKind = currentContainer != nil ? .method : .function
                    entries.append(IndexEntry(
                        name: name, kind: kind, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                }
                // No descent — matches pre-refactor.

            case "class_declaration":
                if let nameNode = TreeSitterBackend.findChildByType(node, type: "type_identifier"),
                   let name = TreeSitterBackend.nodeText(nameNode, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .class, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                    if let body = TreeSitterBackend.findBody(node) {
                        // Re-bind container to class name for body
                        // descendants — matches pre-refactor
                        // `walk(body, ..., container: name)`.
                        stack.append((body, name))
                    }
                }

            case "property_declaration":
                if let varDecl = TreeSitterBackend.findChildByType(node, type: "variable_declaration"),
                   let nameNode = TreeSitterBackend.findChildByType(varDecl, type: "simple_identifier"),
                   let name = TreeSitterBackend.nodeText(nameNode, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .property, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                }
                // No descent — matches pre-refactor.

            case "object_declaration":
                if let nameNode = TreeSitterBackend.findChildByType(node, type: "type_identifier"),
                   let name = TreeSitterBackend.nodeText(nameNode, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .class, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                    if let body = TreeSitterBackend.findBody(node) {
                        stack.append((body, name))
                    }
                }

            case "companion_object":
                // companion's name defaults to "Companion" when no
                // explicit type_identifier child is present —
                // preserved from pre-refactor by computing name
                // before emission and body push.
                let name: String
                if let nameNode = TreeSitterBackend.findChildByType(node, type: "type_identifier"),
                   let explicit = TreeSitterBackend.nodeText(nameNode, source: source) {
                    name = explicit
                } else {
                    name = "Companion"
                }
                entries.append(IndexEntry(
                    name: name, kind: .class, file: file,
                    startLine: TreeSitterBackend.startLine(of: node),
                    endLine: TreeSitterBackend.endLine(of: node),
                    signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                    container: currentContainer, engine: "tree-sitter"
                ))
                if let body = TreeSitterBackend.findBody(node) {
                    stack.append((body, name))
                }

            case "type_alias":
                if let nameNode = TreeSitterBackend.findChildByType(node, type: "type_identifier"),
                   let name = TreeSitterBackend.nodeText(nameNode, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .type, file: file,
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
                // order matches the pre-refactor recursive form
                // exactly.
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
