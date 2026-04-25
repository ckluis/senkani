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

    private static func walk(
        _ node: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        for i in 0..<Int(node.childCount) {
            guard let child = node.child(at: i) else { continue }
            let type = child.nodeType ?? ""

            switch type {
            case "function_declaration":
                if let nameNode = TreeSitterBackend.findChildByType(child, type: "simple_identifier"),
                   let name = TreeSitterBackend.nodeText(nameNode, source: source) {
                    let kind: SymbolKind = container != nil ? .method : .function
                    entries.append(IndexEntry(
                        name: name, kind: kind, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            case "class_declaration":
                if let nameNode = TreeSitterBackend.findChildByType(child, type: "type_identifier"),
                   let name = TreeSitterBackend.nodeText(nameNode, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .class, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                    if let body = TreeSitterBackend.findBody(child) {
                        walk(body, file: file, source: source, lines: lines, container: name, entries: &entries)
                    }
                }

            case "property_declaration":
                if let varDecl = TreeSitterBackend.findChildByType(child, type: "variable_declaration"),
                   let nameNode = TreeSitterBackend.findChildByType(varDecl, type: "simple_identifier"),
                   let name = TreeSitterBackend.nodeText(nameNode, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .property, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            case "object_declaration":
                if let nameNode = TreeSitterBackend.findChildByType(child, type: "type_identifier"),
                   let name = TreeSitterBackend.nodeText(nameNode, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .class, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                    if let body = TreeSitterBackend.findBody(child) {
                        walk(body, file: file, source: source, lines: lines, container: name, entries: &entries)
                    }
                }

            case "companion_object":
                let name: String
                if let nameNode = TreeSitterBackend.findChildByType(child, type: "type_identifier"),
                   let explicit = TreeSitterBackend.nodeText(nameNode, source: source) {
                    name = explicit
                } else {
                    name = "Companion"
                }
                entries.append(IndexEntry(
                    name: name, kind: .class, file: file,
                    startLine: TreeSitterBackend.startLine(of: child),
                    endLine: TreeSitterBackend.endLine(of: child),
                    signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                    container: container, engine: "tree-sitter"
                ))
                if let body = TreeSitterBackend.findBody(child) {
                    walk(body, file: file, source: source, lines: lines, container: name, entries: &entries)
                }

            case "type_alias":
                if let nameNode = TreeSitterBackend.findChildByType(child, type: "type_identifier"),
                   let name = TreeSitterBackend.nodeText(nameNode, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .type, file: file,
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
}
