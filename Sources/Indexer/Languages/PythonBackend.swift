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

    private static func walk(
        _ node: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        for i in 0..<Int(node.childCount) {
            guard let child = node.child(at: i) else { continue }
            let type = child.nodeType ?? ""

            switch type {
            case "function_definition":
                if let entry = TreeSitterBackend.extractFunction(
                    child, file: file, source: source, lines: lines, container: container
                ) {
                    entries.append(entry)
                }

            case "class_definition":
                if let (entry, body) = TreeSitterBackend.extractPythonClass(
                    child, file: file, source: source, lines: lines, container: container
                ) {
                    entries.append(entry)
                    if let body = body {
                        walk(body, file: file, source: source, lines: lines, container: entry.name, entries: &entries)
                    }
                }

            default:
                // decorated_definition + module/block wrappers — recurse so
                // inner function/class declarations are visited.
                if child.childCount > 0 {
                    walk(child, file: file, source: source, lines: lines, container: container, entries: &entries)
                }
            }
        }
    }
}
