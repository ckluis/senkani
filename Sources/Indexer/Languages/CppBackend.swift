import Foundation
import SwiftTreeSitter

/// C++ symbol-extraction backend.
///
/// Three-tier `function_definition` extraction strategy preserved
/// from the dispatcher:
///   1. `extractFunction` — works for in-namespace name-field cases.
///   2. `extractCppQualifiedMethod` — for out-of-class definitions
///      (`void Foo::bar() { }`); container comes from the scope.
///   3. `extractCDeclaratorName` — declarator-chain fallback for
///      free / in-class definitions.
///
/// Node coverage:
///   - function_definition (3-tier as above)
///   - class_specifier (.class, body recursed with name as container)
///   - struct_specifier / union_specifier (.struct, body recursed)
///   - enum_specifier (.enum)
///   - type_definition (typedef → declarator name → .type)
///   - declaration (function prototypes via cHasFunctionDeclarator)
///   - field_declaration (in-class methods via cHasFunctionDeclarator)
///   - namespace_definition (.extension, body recursed without
///     setting container — namespaces don't appear in symbol containers)
///   - alias_declaration (using Foo = Bar; → .type)
internal enum CppBackend: TreeSitterLanguageBackend {

    static func supports(_ language: String) -> Bool {
        language == "cpp"
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
            case "function_definition":
                if let entry = TreeSitterBackend.extractFunction(child, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                } else if let (name, qualContainer) = TreeSitterBackend.extractCppQualifiedMethod(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .method, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: qualContainer, engine: "tree-sitter"
                    ))
                } else if let name = TreeSitterBackend.extractCDeclaratorName(child, source: source) {
                    let kind: SymbolKind = container != nil ? .method : .function
                    entries.append(IndexEntry(
                        name: name, kind: kind, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            case "class_specifier":
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

            case "struct_specifier", "union_specifier":
                if let name = TreeSitterBackend.nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .struct, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                    if let body = TreeSitterBackend.findBody(child) {
                        walk(body, file: file, source: source, lines: lines, container: name, entries: &entries)
                    }
                }

            case "enum_specifier":
                if let name = TreeSitterBackend.nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .enum, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: nil, engine: "tree-sitter"
                    ))
                }

            case "type_definition":
                if let name = TreeSitterBackend.extractCDeclaratorName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .type, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: nil, engine: "tree-sitter"
                    ))
                }

            case "declaration":
                if TreeSitterBackend.cHasFunctionDeclarator(child),
                   let name = TreeSitterBackend.extractCDeclaratorName(child, source: source) {
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

            case "field_declaration":
                if TreeSitterBackend.cHasFunctionDeclarator(child),
                   let name = TreeSitterBackend.extractCDeclaratorName(child, source: source) {
                    let kind: SymbolKind = container != nil ? .method : .function
                    entries.append(IndexEntry(
                        name: name, kind: kind, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            case "namespace_definition":
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

            case "alias_declaration":
                if let name = TreeSitterBackend.nodeName(child, source: source) {
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
