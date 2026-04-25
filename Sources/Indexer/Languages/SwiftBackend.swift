import Foundation
import SwiftTreeSitter

/// Swift symbol-extraction backend.
///
/// Owns the AST walk for Swift source: classes, structs, enums,
/// actors, extensions, protocols, free functions, methods,
/// initializers, and properties (incl. protocol property
/// requirements).
///
/// `class_declaration` is Swift's catch-all for class / struct /
/// enum / actor / extension; the kind is decided by inspecting the
/// declaration keyword in `extractSwiftClassLike`. `extension`
/// names come from `extensionTypeName` since they have no `name`
/// field.
internal enum SwiftBackend: TreeSitterLanguageBackend {

    static func supports(_ language: String) -> Bool {
        language == "swift"
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
            // Swift class / struct / enum / actor / extension all parse as
            // `class_declaration`; kind is decided from the keyword child.
            case "class_declaration":
                if let (entry, body) = TreeSitterBackend.extractSwiftClassLike(
                    child, file: file, source: source, lines: lines, container: container
                ) {
                    entries.append(entry)
                    if let body = body {
                        walk(body, file: file, source: source, lines: lines, container: entry.name, entries: &entries)
                    }
                }

            case "protocol_declaration":
                if let (entry, body) = TreeSitterBackend.extractProtocol(
                    child, file: file, source: source, lines: lines, container: container
                ) {
                    entries.append(entry)
                    if let body = body {
                        walk(body, file: file, source: source, lines: lines, container: entry.name, entries: &entries)
                    }
                }

            case "function_declaration", "protocol_function_declaration":
                if let entry = TreeSitterBackend.extractFunction(
                    child, file: file, source: source, lines: lines, container: container
                ) {
                    entries.append(entry)
                }

            case "init_declaration":
                let start = TreeSitterBackend.startLine(of: child)
                let end = TreeSitterBackend.endLine(of: child)
                let sig = TreeSitterBackend.signatureText(lines: lines, line: start)
                entries.append(IndexEntry(
                    name: "init",
                    kind: .method,
                    file: file,
                    startLine: start,
                    endLine: end,
                    signature: sig,
                    container: container,
                    engine: "tree-sitter"
                ))

            case "property_declaration", "protocol_property_declaration":
                if let entry = TreeSitterBackend.extractProperty(
                    child, file: file, source: source, lines: lines, container: container
                ) {
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
