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

    // Iterative work-stack of (node, container) tuples. Replaces a
    // recursive descent so AST depth no longer consumes Swift call
    // frames. Chain child of `indexer-backends-iterative-walk-refactor-
    // 2026-05-11` (GoBackend pilot precedent, BashBackend predecessor,
    // both 2026-05-18).
    private static func walk(
        _ root: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        var stack: [(Node, String?)] = [(root, container)]
        while let (node, currentContainer) = stack.popLast() {
            let type = node.nodeType ?? ""

            switch type {
            case "function_definition":
                if let name = TreeSitterBackend.extractCDeclaratorName(node, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .function, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: nil, engine: "tree-sitter"
                    ))
                }
                // Bodies aren't walked — matches the pre-refactor
                // recursive form (the switch arm returned without
                // recursing into children).

            case "struct_specifier", "union_specifier":
                if let name = TreeSitterBackend.nodeName(node, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .struct, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: nil, engine: "tree-sitter"
                    ))
                }

            case "enum_specifier":
                if let name = TreeSitterBackend.nodeName(node, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .enum, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: nil, engine: "tree-sitter"
                    ))
                }

            case "type_definition":
                if let name = TreeSitterBackend.extractCDeclaratorName(node, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .type, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: nil, engine: "tree-sitter"
                    ))
                }

            case "declaration":
                if TreeSitterBackend.cHasFunctionDeclarator(node),
                   let name = TreeSitterBackend.extractCDeclaratorName(node, source: source) {
                    let kind: SymbolKind = currentContainer != nil ? .method : .function
                    entries.append(IndexEntry(
                        name: name, kind: kind, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                    // Don't push children — matches pre-refactor: when
                    // the declaration carries a function declarator,
                    // its body/children are not descended.
                } else {
                    // No function declarator (or name extraction
                    // failed) — push children for later iteration.
                    // Matches pre-refactor `else if child.childCount > 0`.
                    let count = Int(node.childCount)
                    guard count > 0 else { continue }
                    for i in stride(from: count - 1, through: 0, by: -1) {
                        if let child = node.child(at: i) {
                            stack.append((child, currentContainer))
                        }
                    }
                }

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
