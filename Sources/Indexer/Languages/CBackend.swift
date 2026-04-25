import Foundation
import SwiftTreeSitter

/// C symbol-extraction backend.
///
/// C grammar puts the function name inside a declarator chain
/// (function_declarator → parenthesized_declarator → identifier),
/// so name lookups go via `extractCDeclaratorName`. Functions are
/// always emitted with `container: nil` (C has no lexical container
/// hierarchy at the symbol-table level — struct/union/enum bodies
/// don't nest function definitions in well-formed C).
///
/// Node coverage:
///   - function_definition (top-level definitions)
///   - struct_specifier / union_specifier (mapped to .struct, no body recursion)
///   - enum_specifier (mapped to .enum)
///   - type_definition (typedef — name extracted from the declarator)
///   - declaration (function prototypes — emitted as .function)
internal enum CBackend: TreeSitterLanguageBackend {

    static func supports(_ language: String) -> Bool {
        language == "c"
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
                if let name = TreeSitterBackend.extractCDeclaratorName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .function, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: nil, engine: "tree-sitter"
                    ))
                }

            case "struct_specifier", "union_specifier":
                if let name = TreeSitterBackend.nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .struct, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: nil, engine: "tree-sitter"
                    ))
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

            default:
                if child.childCount > 0 {
                    walk(child, file: file, source: source, lines: lines, container: container, entries: &entries)
                }
            }
        }
    }
}
