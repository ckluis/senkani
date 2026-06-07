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

    // Iterative work-stack of (node, container) tuples. Replaces a
    // recursive descent so AST depth no longer consumes Swift call
    // frames. Chain child of `indexer-backends-iterative-walk-refactor-
    // 2026-05-11` (GoBackend pilot 2026-05-18, BashBackend / CBackend
    // predecessors 2026-05-18). CppBackend is the first chain child
    // whose substrate genuinely USES the container slot — class /
    // struct / union body pushes re-bind container to the type's
    // name; namespace / declaration / default propagate unchanged.
    private static func walk(
        _ root: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        var stack: [(Node, String?)] = [(root, container)]
        while let (node, currentContainer) = stack.popLast() {
            let type = node.nodeType ?? ""

            switch type {
            case "function_definition":
                if let entry = TreeSitterBackend.extractFunction(node, file: file, source: source, lines: lines, container: currentContainer) {
                    entries.append(entry)
                } else if let (name, qualContainer) = TreeSitterBackend.extractCppQualifiedMethod(node, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .method, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: qualContainer, engine: "tree-sitter"
                    ))
                } else if let name = TreeSitterBackend.extractCDeclaratorName(node, source: source) {
                    let kind: SymbolKind = currentContainer != nil ? .method : .function
                    entries.append(IndexEntry(
                        name: name, kind: kind, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                }
                // No body push — matches pre-refactor (the arm
                // emitted and returned without recursing into the
                // function body).

            case "class_specifier":
                if let name = TreeSitterBackend.nodeName(node, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .class, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                    if let body = TreeSitterBackend.findBody(node) {
                        // Re-bind container to the class name for
                        // the body's descendants — matches pre-
                        // refactor `walk(body, ..., container: name)`.
                        stack.append((body, name))
                    }
                }

            case "struct_specifier", "union_specifier":
                if let name = TreeSitterBackend.nodeName(node, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .struct, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                    if let body = TreeSitterBackend.findBody(node) {
                        stack.append((body, name))
                    }
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
                    // No children push — matches pre-refactor.
                } else {
                    let count = Int(node.childCount)
                    guard count > 0 else { continue }
                    for i in stride(from: count - 1, through: 0, by: -1) {
                        if let child = node.child(at: i) {
                            stack.append((child, currentContainer))
                        }
                    }
                }

            case "field_declaration":
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
                }
                // No descent — matches pre-refactor (field_declaration
                // arm emitted and returned without recursing).

            case "namespace_definition":
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
                // anonymous namespaces (no name field) still descend.
                if let body = TreeSitterBackend.findBody(node) {
                    stack.append((body, currentContainer))
                }

            case "alias_declaration":
                if let name = TreeSitterBackend.nodeName(node, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .type, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
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
