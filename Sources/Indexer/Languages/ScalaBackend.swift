import Foundation
import SwiftTreeSitter

/// Scala symbol-extraction backend.
///
/// Scala distinguishes objects (singletons → emitted as .class),
/// traits (interface-with-impl → emitted as .protocol), and class
/// definitions (`class_definition`, the same node type Python uses;
/// `extractPythonClass` handles both grammars because the shape is
/// identical: `name` field + body).
///
/// `val_definition` / `var_definition` carry the symbol name on a
/// `pattern` field rather than `name`, so they go through a custom
/// extraction path.
///
/// Node coverage:
///   - class_definition (.class via extractPythonClass, body recursed
///     with class name as container)
///   - object_definition (.class, body recursed with object name as
///     container)
///   - trait_definition (.protocol, body recursed with trait name as
///     container so default fn implementations land as methods)
///   - val_definition / var_definition (.property, name from `pattern` field)
///   - type_definition (.type)
///   - function_definition / function_declaration (.method/.function
///     via extractFunction — Scala uses `function_definition` for `def`)
internal enum ScalaBackend: TreeSitterLanguageBackend {

    static func supports(_ language: String) -> Bool {
        language == "scala"
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
    // frames on the cooperative pool. Umbrella chain child of
    // `indexer-backends-iterative-walk-refactor-2026-05-11`
    // (alphabetical successor to RustBackend; closest precedent
    // JavaBackend's five-body-rebind-arm pattern, Scala has three
    // body-rebind arms all with emit — no emit-less wrinkle, unlike
    // Rust's impl_item). Three body-rebind arms (`class_definition`,
    // `object_definition`, `trait_definition`) each emit and then
    // push the body with container re-bound to the declared name.
    // Leaf-emit arms (`val_definition` / `var_definition`,
    // `type_definition`, `function_definition` /
    // `function_declaration`) emit without descent. The default arm
    // reverse-pushes children with currentContainer preserved so LIFO
    // pop reproduces left-to-right pre-order — symbol-emission order
    // matches pre-refactor exactly.
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

            case "object_definition":
                if let name = TreeSitterBackend.nodeName(node, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .class, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                    if let body = TreeSitterBackend.findBody(node) {
                        // Re-bind container to the object name for the
                        // body's descendants — matches pre-refactor
                        // `walk(body, ..., container: name)`.
                        stack.append((body, name))
                    }
                }

            case "trait_definition":
                if let name = TreeSitterBackend.nodeName(node, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .protocol, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                    if let body = TreeSitterBackend.findBody(node) {
                        // Re-bind container to the trait name for the
                        // body's descendants — matches pre-refactor
                        // `walk(body, ..., container: name)`.
                        stack.append((body, name))
                    }
                }

            case "val_definition", "var_definition":
                // Scala-specific: symbol name is on the `pattern` field,
                // not `name`. Preserved verbatim from pre-refactor.
                if let patternNode = node.child(byFieldName: "pattern"),
                   let name = TreeSitterBackend.nodeText(patternNode, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .property, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                }

            case "type_definition":
                if let name = TreeSitterBackend.nodeName(node, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .type, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                }

            case "function_definition", "function_declaration":
                if let entry = TreeSitterBackend.extractFunction(node, file: file, source: source, lines: lines, container: currentContainer) {
                    entries.append(entry)
                }

            default:
                // Push children in reverse so LIFO pop preserves
                // left-to-right pre-order traversal — symbol-emission
                // order matches the pre-refactor recursive form
                // exactly. The pre-refactor default arm guarded with
                // `if child.childCount > 0`; the iterative form's
                // `guard count > 0 else continue` reproduces that —
                // childless leaves popped here fall through as a
                // no-op exactly as the pre-refactor's guard skipped
                // them.
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
