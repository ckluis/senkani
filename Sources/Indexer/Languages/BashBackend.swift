import Foundation
import SwiftTreeSitter

/// Bash symbol-extraction backend.
///
/// Bash exposes a single declaration node — `function_definition` —
/// whose `name` field carries the function name. Top-level only;
/// Bash has no nested function containers in well-formed scripts, so
/// this backend never recurses into bodies.
///
/// Node coverage:
///   - function_definition  (.function via extractFunction)
internal enum BashBackend: TreeSitterLanguageBackend {

    static func supports(_ language: String) -> Bool {
        language == "bash"
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
    // 2026-05-11` (GoBackend pilot precedent, 2026-05-18).
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
                }
                // Bodies aren't walked — matches the pre-refactor
                // recursive form (the switch arm extracted the function
                // without recursing into its children).

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
