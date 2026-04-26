import Foundation
import SwiftTreeSitter

/// Dart symbol-extraction backend.
///
/// Node coverage:
///   - class_definition (.class, body recursed) — same node type
///     Python uses, so the shared `extractPythonClass` helper works.
///   - function_signature (.method when inside a class container,
///     else .function — top-level fns and class method signatures)
///   - getter_signature, setter_signature (.property in a container,
///     else .variable)
///   - extension_declaration (.extension — `extension Foo on Bar`).
///     Container fallback "extension" when the grammar produces no
///     name (anonymous extensions).
///   - mixin_declaration (.class — `mixin Foo { ... }`; mixin bodies
///     recurse with the mixin name as container)
///   - enum_declaration (.enum — `enum Color { red, green }`)
internal enum DartBackend: TreeSitterLanguageBackend {

    static func supports(_ language: String) -> Bool {
        language == "dart"
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

    private static func walk(
        _ node: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        for i in 0..<Int(node.childCount) {
            guard let child = node.child(at: i) else { continue }
            let type = child.nodeType ?? ""

            switch type {
            case "class_definition":
                if let (entry, body) = TreeSitterBackend.extractPythonClass(child, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                    if let body = body {
                        walk(body, file: file, source: source, lines: lines, container: entry.name, entries: &entries)
                    }
                }

            case "enum_declaration":
                if let (entry, body) = TreeSitterBackend.extractTSDeclaration(child, kind: .enum, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                    if let body = body {
                        walk(body, file: file, source: source, lines: lines, container: entry.name, entries: &entries)
                    }
                }

            case "function_signature":
                if let name = TreeSitterBackend.nodeName(child, source: source) {
                    let kind: SymbolKind = container != nil ? .method : .function
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

            case "getter_signature", "setter_signature":
                if let name = TreeSitterBackend.nodeName(child, source: source) {
                    let kind: SymbolKind = container != nil ? .property : .variable
                    entries.append(IndexEntry(
                        name: name, kind: kind, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            case "extension_declaration":
                let name = TreeSitterBackend.nodeName(child, source: source) ?? "extension"
                entries.append(IndexEntry(
                    name: name, kind: .extension, file: file,
                    startLine: TreeSitterBackend.startLine(of: child),
                    endLine: TreeSitterBackend.endLine(of: child),
                    signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                    container: container, engine: "tree-sitter"
                ))
                if let body = TreeSitterBackend.findBody(child) {
                    walk(body, file: file, source: source, lines: lines, container: name, entries: &entries)
                }

            case "mixin_declaration":
                if let name = TreeSitterBackend.nodeName(child, source: source) {
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

            default:
                if child.childCount > 0 {
                    walk(child, file: file, source: source, lines: lines, container: container, entries: &entries)
                }
            }
        }
    }
}
