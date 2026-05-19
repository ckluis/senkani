import Foundation
import SwiftTreeSitter

/// Python symbol-extraction backend.
///
/// Walks Python ASTs for top-level and nested function / class
/// definitions. `decorated_definition` (e.g. `@dataclass\nclass Foo:`)
/// is a wrapper node — the default arm recurses through it so the
/// inner `function_definition` / `class_definition` is reached.
///
/// Python's class body recursion is what produces method entries
/// inside class scope; the recursive `walk` inherits the class name
/// as `container` so methods come out tagged with their owning class.
internal enum PythonBackend: TreeSitterLanguageBackend {

    static func supports(_ language: String) -> Bool {
        language == "python"
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
    // (alphabetical successor to PhpBackend; closest precedent
    // DartBackend's class_definition body-rebind arm — same
    // `extractPythonClass`-shaped helper). One body-rebind arm —
    // `class_definition` emits via extractPythonClass then pushes
    // its body with container re-bound to the class name, matching
    // pre-refactor `walk(body, ..., container: entry.name)`. The
    // leaf-emit arm `function_definition` emits via extractFunction
    // without descent (Python's function bodies are not source for
    // further top-level declarations the walk reaches; nested defs
    // inside a function are not currently emitted by this backend).
    // The default arm covers `decorated_definition` plus module /
    // block wrappers — reverse-pushes children with currentContainer
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
            case "function_definition":
                if let entry = TreeSitterBackend.extractFunction(
                    node, file: file, source: source, lines: lines, container: currentContainer
                ) {
                    entries.append(entry)
                }
                // No descent — matches pre-refactor.

            case "class_definition":
                if let (entry, body) = TreeSitterBackend.extractPythonClass(
                    node, file: file, source: source, lines: lines, container: currentContainer
                ) {
                    entries.append(entry)
                    if let body = body {
                        // Re-bind container to the class name for the
                        // body's descendants — matches pre-refactor
                        // `walk(body, ..., container: entry.name)`.
                        stack.append((body, entry.name))
                    }
                }

            default:
                // decorated_definition + module/block wrappers — push
                // children in reverse so LIFO pop preserves left-to-
                // right pre-order traversal. Matches pre-refactor
                // `if child.childCount > 0 { walk(child, ...) }`
                // semantics (childless leaves are popped and fall
                // through this default arm as a no-op).
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
