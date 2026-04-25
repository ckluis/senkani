import Foundation
import SwiftTreeSitter

/// TypeScript / TSX / JavaScript symbol-extraction backend.
///
/// One backend covers all three grammars because their declaration
/// node types and extraction logic are uniform: classes, interfaces,
/// type aliases, enums, methods, and (generator) function
/// declarations all share the same `name`-field shape. JSX in `.tsx`
/// and `.js` is handled by the parser; the walk is identical.
///
/// Class / interface / enum bodies recurse through the backend's own
/// `walk`, propagating the declaration name as `container` so methods
/// come out tagged correctly. Arrow functions and anonymous function
/// expressions assigned to consts are intentionally not emitted in v1
/// (see TreeSitterJavaScriptTests.parsesArrowFunctionsAreNotMatched).
internal enum TypeScriptBackend: TreeSitterLanguageBackend {

    static func supports(_ language: String) -> Bool {
        language == "typescript" || language == "tsx" || language == "javascript"
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
            case "function_declaration", "generator_function_declaration":
                if let entry = TreeSitterBackend.extractFunction(
                    child, file: file, source: source, lines: lines, container: container
                ) {
                    entries.append(entry)
                }

            case "class_declaration":
                if let (entry, body) = TreeSitterBackend.extractTSDeclaration(
                    child, kind: .class, file: file, source: source, lines: lines, container: container
                ) {
                    entries.append(entry)
                    if let body = body {
                        walk(body, file: file, source: source, lines: lines, container: entry.name, entries: &entries)
                    }
                }

            case "interface_declaration":
                if let (entry, body) = TreeSitterBackend.extractTSDeclaration(
                    child, kind: .interface, file: file, source: source, lines: lines, container: container
                ) {
                    entries.append(entry)
                    if let body = body {
                        walk(body, file: file, source: source, lines: lines, container: entry.name, entries: &entries)
                    }
                }

            case "type_alias_declaration":
                if let name = TreeSitterBackend.nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name,
                        kind: .type,
                        file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container,
                        engine: "tree-sitter"
                    ))
                }

            case "enum_declaration":
                if let (entry, body) = TreeSitterBackend.extractTSDeclaration(
                    child, kind: .enum, file: file, source: source, lines: lines, container: container
                ) {
                    entries.append(entry)
                    if let body = body {
                        walk(body, file: file, source: source, lines: lines, container: entry.name, entries: &entries)
                    }
                }

            case "method_definition":
                if let entry = TreeSitterBackend.extractFunction(
                    child, file: file, source: source, lines: lines, container: container
                ) {
                    entries.append(entry)
                }

            default:
                // export_statement, decorated_definition, program, block, etc.
                if child.childCount > 0 {
                    walk(child, file: file, source: source, lines: lines, container: container, entries: &entries)
                }
            }
        }
    }
}
