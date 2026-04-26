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

    private static func walk(
        _ node: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        for i in 0..<Int(node.childCount) {
            guard let child = node.child(at: i) else { continue }
            let type = child.nodeType ?? ""

            switch type {
            case "function_definition":
                if let entry = TreeSitterBackend.extractFunction(child, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                }

            default:
                if child.childCount > 0 {
                    walk(child, file: file, source: source, lines: lines, container: container, entries: &entries)
                }
            }
        }
    }
}
