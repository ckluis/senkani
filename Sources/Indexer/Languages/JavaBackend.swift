import Foundation
import SwiftTreeSitter

/// Java symbol-extraction backend.
///
/// Java is a uniform `name`-field grammar: classes, interfaces,
/// enums, records, and annotation types all expose `name` and (most)
/// expose `body`. Records are mapped to `.struct` and annotation
/// types to `.protocol` for symbol-table compatibility with how
/// other languages treat similar concepts.
///
/// Methods and constructors emit via `extractFunction` (which picks
/// `.method` when a container is set, `.function` otherwise — Java
/// only ever calls this with a class/interface container in normal
/// code).
///
/// Node coverage:
///   - class_declaration (.class, body recursed)
///   - interface_declaration (.interface, body recursed)
///   - enum_declaration (.enum, body recursed)
///   - record_declaration (.struct, body recursed)
///   - annotation_type_declaration (.protocol, body recursed)
///   - method_declaration / constructor_declaration (.method/.function)
internal enum JavaBackend: TreeSitterLanguageBackend {

    static func supports(_ language: String) -> Bool {
        language == "java"
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
            case "class_declaration":
                if let (entry, body) = TreeSitterBackend.extractTSDeclaration(child, kind: .class, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                    if let body = body {
                        walk(body, file: file, source: source, lines: lines, container: entry.name, entries: &entries)
                    }
                }

            case "interface_declaration":
                if let (entry, body) = TreeSitterBackend.extractTSDeclaration(child, kind: .interface, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                    if let body = body {
                        walk(body, file: file, source: source, lines: lines, container: entry.name, entries: &entries)
                    }
                }

            case "enum_declaration":
                if let (entry, body) = TreeSitterBackend.extractTSDeclaration(child, kind: .enum, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                    if let body = body {
                        walk(body, file: file, source: source, lines: lines, container: entry.name, entries: &entries)
                    }
                }

            case "record_declaration":
                if let (entry, body) = TreeSitterBackend.extractTSDeclaration(child, kind: .struct, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                    if let body = body {
                        walk(body, file: file, source: source, lines: lines, container: entry.name, entries: &entries)
                    }
                }

            case "annotation_type_declaration":
                if let (entry, body) = TreeSitterBackend.extractTSDeclaration(child, kind: .protocol, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                    if let body = body {
                        walk(body, file: file, source: source, lines: lines, container: entry.name, entries: &entries)
                    }
                }

            case "method_declaration", "constructor_declaration":
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
