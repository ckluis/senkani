import Foundation
import SwiftTreeSitter

/// Rust symbol-extraction backend.
///
/// Node coverage:
///   - function_item, function_signature_item — top-level fns and
///     trait fn signatures (.function or .method based on container)
///   - struct_item (.struct)
///   - enum_item (.enum)
///   - trait_item (.protocol; body recursed with trait name as
///     container so default fn implementations land as methods)
///   - type_item (.type — type aliases like `type UserId = u64`)
///   - impl_item (no entry of its own; body is recursed with the
///     impl'd type as container so methods inside land as
///     `.method` with the right container; trait-for-impl uses the
///     `for X` type, never the trait name)
///
/// The impl recursion uses `extractRustImplType` which handles
/// `impl User`, `impl<T> Wrapper<T>` (strips generics), and
/// `impl Display for User` (returns "User").
internal enum RustBackend: TreeSitterLanguageBackend {

    static func supports(_ language: String) -> Bool {
        language == "rust"
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
            case "function_item", "function_signature_item":
                if let entry = TreeSitterBackend.extractFunction(child, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                }

            case "struct_item":
                if let name = TreeSitterBackend.nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .struct, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            case "enum_item":
                if let name = TreeSitterBackend.nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .enum, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            case "trait_item":
                if let name = TreeSitterBackend.nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .protocol, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                    if let body = TreeSitterBackend.findBody(child) {
                        walk(body, file: file, source: source, lines: lines, container: name, entries: &entries)
                    }
                }

            case "type_item":
                if let name = TreeSitterBackend.nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .type, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            case "impl_item":
                let implContainer = TreeSitterBackend.extractRustImplType(child, source: source)
                if let body = TreeSitterBackend.findBody(child) {
                    walk(body, file: file, source: source, lines: lines, container: implContainer, entries: &entries)
                }

            default:
                if child.childCount > 0 {
                    walk(child, file: file, source: source, lines: lines, container: container, entries: &entries)
                }
            }
        }
    }
}
