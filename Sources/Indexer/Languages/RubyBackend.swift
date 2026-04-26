import Foundation
import SwiftTreeSitter

/// Ruby symbol-extraction backend.
///
/// Ruby's grammar uses bare `class` / `module` / `method` /
/// `singleton_method` node types (no `_declaration` suffix). Class
/// and module bodies act as containers; methods inside them emit as
/// `.method`, top-level methods as `.function`. Modules emit as
/// `.extension` to stay consistent with other namespacing constructs
/// (PHP namespaces, Swift extensions).
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

    private static func walk(
        _ node: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        for i in 0..<Int(node.childCount) {
            guard let child = node.child(at: i) else { continue }
            let type = child.nodeType ?? ""

            switch type {
            case "class":
                if let name = TreeSitterBackend.nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .class, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                    if let body = TreeSitterBackend.findBody(child) {
                        walk(body, file: file, source: source, lines: lines, container: name, entries: &entries)
                    }
                }

            case "module":
                if let name = TreeSitterBackend.nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .extension, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                    if let body = TreeSitterBackend.findBody(child) {
                        walk(body, file: file, source: source, lines: lines, container: name, entries: &entries)
                    }
                }

            case "method", "singleton_method":
                if let name = TreeSitterBackend.nodeName(child, source: source) {
                    let kind: SymbolKind = container != nil ? .method : .function
                    entries.append(IndexEntry(
                        name: name, kind: kind, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            default:
                if child.childCount > 0 {
                    walk(child, file: file, source: source, lines: lines, container: container, entries: &entries)
                }
            }
        }
    }
}
