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

    // Iterative work-stack of (node, container) tuples. Replaces a
    // recursive descent so AST depth no longer consumes Swift call
    // frames on the cooperative pool. Umbrella chain child of
    // `indexer-backends-iterative-walk-refactor-2026-05-11`
    // (alphabetical successor to TomlBackend). TypeScript's substrate
    // has three body-rebind-with-emit arms (class_declaration,
    // interface_declaration, enum_declaration) — each emits via
    // `TreeSitterBackend.extractTSDeclaration` and pushes the returned
    // body onto the stack with container re-bound to `entry.name`,
    // matching pre-refactor `walk(body, ..., container: entry.name)`.
    // Closest precedent is PhpBackend's three-body-rebind-arm pattern
    // — TS uses the same three declaration kinds (class / interface /
    // enum) routed through the shared `extractTSDeclaration` helper,
    // without PHP's namespace `.extension`-emit-with-container-preserve
    // quirk and without PHP's `property_declaration` multi-element
    // iteration. Leaf-emit arms (function_declaration /
    // generator_function_declaration via `extractFunction`,
    // type_alias_declaration via direct `IndexEntry` construction with
    // `kind: .type`, method_definition via `extractFunction`) emit
    // without descent. The default arm covers `export_statement`,
    // `decorated_definition`, `program`, `block`, etc. and
    // reverse-pushes children with currentContainer preserved so LIFO
    // pop reproduces left-to-right pre-order — `export class Foo {}`
    // wrappers fall through default, push the inner class_declaration
    // back onto the stack, and the class arm fires on the next pop.
    // One backend, three grammars (TS, TSX, JS) — the walk is uniform
    // because all three share the same declaration node types.
    private static func walk(
        _ root: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        var stack: [(Node, String?)] = [(root, container)]
        while let (node, currentContainer) = stack.popLast() {
            let type = node.nodeType ?? ""

            switch type {
            case "function_declaration", "generator_function_declaration":
                if let entry = TreeSitterBackend.extractFunction(
                    node, file: file, source: source, lines: lines, container: currentContainer
                ) {
                    entries.append(entry)
                }
                // No descent — matches pre-refactor.

            case "class_declaration":
                if let (entry, body) = TreeSitterBackend.extractTSDeclaration(
                    node, kind: .class, file: file, source: source, lines: lines, container: currentContainer
                ) {
                    entries.append(entry)
                    if let body = body {
                        // Re-bind container to the class name for the
                        // body's descendants — matches pre-refactor
                        // line 58's `walk(body, ..., container: entry.name)`.
                        stack.append((body, entry.name))
                    }
                }

            case "interface_declaration":
                if let (entry, body) = TreeSitterBackend.extractTSDeclaration(
                    node, kind: .interface, file: file, source: source, lines: lines, container: currentContainer
                ) {
                    entries.append(entry)
                    if let body = body {
                        stack.append((body, entry.name))
                    }
                }

            case "type_alias_declaration":
                if let name = TreeSitterBackend.nodeName(node, source: source) {
                    entries.append(IndexEntry(
                        name: name,
                        kind: .type,
                        file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer,
                        engine: "tree-sitter"
                    ))
                }
                // No descent — type aliases are leaf-emit.

            case "enum_declaration":
                if let (entry, body) = TreeSitterBackend.extractTSDeclaration(
                    node, kind: .enum, file: file, source: source, lines: lines, container: currentContainer
                ) {
                    entries.append(entry)
                    if let body = body {
                        stack.append((body, entry.name))
                    }
                }

            case "method_definition":
                if let entry = TreeSitterBackend.extractFunction(
                    node, file: file, source: source, lines: lines, container: currentContainer
                ) {
                    entries.append(entry)
                }
                // No descent — matches pre-refactor.

            default:
                // export_statement, decorated_definition, program,
                // block, etc. Push children in reverse so LIFO pop
                // preserves left-to-right pre-order traversal —
                // symbol-emission order matches the pre-refactor
                // recursive form exactly. The pre-refactor default
                // arm guarded with `if child.childCount > 0`; the
                // iterative form's `guard count > 0 else continue`
                // reproduces that — childless leaves popped here
                // fall through as a no-op exactly as the pre-refactor's
                // guard skipped them.
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
