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

    // Iterative work-stack of (node, container) tuples. Replaces a
    // recursive descent so AST depth no longer consumes Swift call
    // frames. Chain child of `indexer-backends-iterative-walk-refactor-
    // 2026-05-11` (GoBackend pilot 2026-05-18, BashBackend / CBackend /
    // CppBackend / CSharpBackend predecessors 2026-05-18). Dart's
    // substrate parallels CSharpBackend: class_definition /
    // enum_declaration body pushes re-bind container to entry.name;
    // extension_declaration and mixin_declaration body pushes re-bind
    // container to the declared name (or "extension" fallback for
    // anonymous extensions, matching the recursive form). The
    // function_signature unresolved-name else-branch and the default
    // arm push children with currentContainer preserved.
    private static func walk(
        _ root: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        var stack: [(Node, String?)] = [(root, container)]
        while let (node, currentContainer) = stack.popLast() {
            let type = node.nodeType ?? ""

            switch type {
            case "class_definition":
                if let (entry, body) = TreeSitterBackend.extractPythonClass(node, file: file, source: source, lines: lines, container: currentContainer) {
                    entries.append(entry)
                    if let body = body {
                        // Re-bind container to the class name for the
                        // body's descendants — matches pre-refactor
                        // `walk(body, ..., container: entry.name)`.
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

            case "function_signature":
                if let name = TreeSitterBackend.nodeName(node, source: source) {
                    let kind: SymbolKind = currentContainer != nil ? .method : .function
                    entries.append(IndexEntry(
                        name: name, kind: kind, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                } else {
                    // Unresolved-name fall-through — push children with
                    // container preserved (matches pre-refactor
                    // `walk(child, ..., container: container)`).
                    let count = Int(node.childCount)
                    guard count > 0 else { continue }
                    for i in stride(from: count - 1, through: 0, by: -1) {
                        if let child = node.child(at: i) {
                            stack.append((child, currentContainer))
                        }
                    }
                }

            case "getter_signature", "setter_signature":
                if let name = TreeSitterBackend.nodeName(node, source: source) {
                    let kind: SymbolKind = currentContainer != nil ? .property : .variable
                    entries.append(IndexEntry(
                        name: name, kind: kind, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                }
                // No descent — matches pre-refactor.

            case "extension_declaration":
                let name = TreeSitterBackend.nodeName(node, source: source) ?? "extension"
                entries.append(IndexEntry(
                    name: name, kind: .extension, file: file,
                    startLine: TreeSitterBackend.startLine(of: node),
                    endLine: TreeSitterBackend.endLine(of: node),
                    signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                    container: currentContainer, engine: "tree-sitter"
                ))
                if let body = TreeSitterBackend.findBody(node) {
                    // Re-bind to extension's name (or "extension"
                    // fallback) — matches pre-refactor body recursion.
                    stack.append((body, name))
                }

            case "mixin_declaration":
                if let name = TreeSitterBackend.nodeName(node, source: source) {
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
