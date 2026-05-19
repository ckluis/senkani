import Foundation
import SwiftTreeSitter

/// Ruby symbol-extraction backend.
///
/// Ruby's grammar uses bare `class` / `module` / `method` /
/// `singleton_method` node types (no `_declaration` suffix). Class
/// and module bodies act as containers; methods inside them emit as
/// `.method`, top-level methods as `.function`. Modules emit as
/// `.extension` to stay consistent with other namespacing constructs
/// (PHP namespaces, Swift extensions). Unlike PHP namespaces, Ruby
/// modules DO act as containers — methods defined inside a `module`
/// body carry the module name as their `container`.
///
/// Node coverage:
///   - class           (.class, body recursed with class name as container)
///   - module          (.extension, body recursed with module name as container)
///   - method          (.method/.function based on container)
///   - singleton_method (def self.foo — class-level methods)
internal enum RubyBackend: TreeSitterLanguageBackend {

    static func supports(_ language: String) -> Bool {
        language == "ruby"
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
    // (alphabetical successor to PythonBackend; closest precedent
    // PhpBackend's multi-arm body-rebind pattern). Ruby's substrate
    // has two body-rebind arms — `class` and `module` — each emits
    // then pushes the body with container re-bound to the declared
    // name, matching pre-refactor
    // `walk(body, ..., container: name)`. Unlike PHP's
    // namespace_definition arm, Ruby modules DO act as containers
    // (a method inside `module Acme` carries `container: "Acme"`),
    // so the module arm rebinds to the module name rather than
    // preserving the outer container. method and singleton_method
    // emit without descent — Ruby method bodies are not source for
    // further top-level declarations the walk reaches (matches
    // pre-refactor's lack of a recurse-into-method-body site). The
    // default arm reverse-pushes children with currentContainer
    // preserved so LIFO pop reproduces left-to-right pre-order —
    // symbol-emission order matches pre-refactor exactly.
    private static func walk(
        _ root: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        var stack: [(Node, String?)] = [(root, container)]
        while let (node, currentContainer) = stack.popLast() {
            let type = node.nodeType ?? ""

            switch type {
            case "class":
                if let name = TreeSitterBackend.nodeName(node, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .class, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                    if let body = TreeSitterBackend.findBody(node) {
                        // Re-bind container to the class name for the
                        // body's descendants — matches pre-refactor
                        // `walk(body, ..., container: name)`.
                        stack.append((body, name))
                    }
                }
                // If nodeName fails, the arm is a no-op — matches
                // pre-refactor (the `if let` guard skips both emit
                // and body walk; body is NOT walked under default
                // either because the switch already matched `class`).

            case "module":
                if let name = TreeSitterBackend.nodeName(node, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .extension, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                    if let body = TreeSitterBackend.findBody(node) {
                        // Ruby modules ARE containers — push the
                        // body with the module name, matches pre-
                        // refactor `walk(body, ..., container: name)`.
                        stack.append((body, name))
                    }
                }

            case "method", "singleton_method":
                if let name = TreeSitterBackend.nodeName(node, source: source) {
                    let kind: SymbolKind = currentContainer != nil ? .method : .function
                    entries.append(IndexEntry(
                        name: name, kind: kind, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                }
                // No descent — matches pre-refactor.

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
