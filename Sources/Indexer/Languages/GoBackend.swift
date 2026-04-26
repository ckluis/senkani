import Foundation
import SwiftTreeSitter

/// Go symbol-extraction backend.
///
/// Node coverage:
///   - function_declaration → top-level `func foo()` (.function)
///   - method_declaration → `func (r *T) Foo()` with receiver-based
///     container resolved by `extractGoMethod` (.method)
///   - type_declaration → wraps multiple `type_spec` children
///     (struct/interface/type alias). Each type_spec emits its own
///     entry via `extractGoTypeDeclaration` →
///     `extractGoTypeSpec`, which picks `.struct` / `.interface` /
///     `.type` from the spec's `type` field.
internal enum GoBackend: TreeSitterLanguageBackend {

    static func supports(_ language: String) -> Bool {
        language == "go"
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
            case "function_declaration":
                if let entry = TreeSitterBackend.extractFunction(child, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                }

            case "method_declaration":
                if let entry = TreeSitterBackend.extractGoMethod(child, file: file, source: source, lines: lines) {
                    entries.append(entry)
                }

            case "type_declaration":
                TreeSitterBackend.extractGoTypeDeclaration(child, file: file, source: source, lines: lines, entries: &entries)

            default:
                if child.childCount > 0 {
                    walk(child, file: file, source: source, lines: lines, container: container, entries: &entries)
                }
            }
        }
    }
}
