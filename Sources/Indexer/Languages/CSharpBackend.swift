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

    private static func walk(
        _ node: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        for i in 0..<Int(node.childCount) {
            guard let child = node.child(at: i) else { continue }
            let type = child.nodeType ?? ""

            switch type {
            case "class_declaration":
                if let (entry, body) = TreeSitterBackend.extractTSDeclaration(child, kind: .class, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                    if let body = body {
                        walk(body, file: file, source: source, lines: lines, container: entry.name, entries: &entries)
                    }
                }

            case "struct_declaration", "record_declaration":
                if let (entry, body) = TreeSitterBackend.extractTSDeclaration(child, kind: .struct, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                    if let body = body {
                        walk(body, file: file, source: source, lines: lines, container: entry.name, entries: &entries)
                    }
                }

            case "interface_declaration":
                if let (entry, body) = TreeSitterBackend.extractTSDeclaration(child, kind: .interface, file: file, source: source, lines: lines, container: container) {
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

            case "delegate_declaration":
                if let name = TreeSitterBackend.nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .type, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            case "namespace_declaration":
                if let name = TreeSitterBackend.nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .extension, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }
                if let body = TreeSitterBackend.findBody(child) {
                    walk(body, file: file, source: source, lines: lines, container: container, entries: &entries)
                }

            case "file_scoped_namespace_declaration":
                if let name = TreeSitterBackend.nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .extension, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }
                if child.childCount > 0 {
                    walk(child, file: file, source: source, lines: lines, container: container, entries: &entries)
                }

            case "method_declaration", "constructor_declaration", "destructor_declaration":
                if let entry = TreeSitterBackend.extractFunction(child, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                }

            case "property_declaration":
                if let name = TreeSitterBackend.nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .property, file: file,
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
