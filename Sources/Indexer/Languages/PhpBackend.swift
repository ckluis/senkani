import Foundation
import SwiftTreeSitter

/// PHP symbol-extraction backend.
///
/// PHP uses uniform `name`-field declarations for classes, interfaces,
/// enums, and traits, but its property declarations group multiple
/// `property_element` children with `$`-sigil names under a single
/// `property_declaration` node. Each `property_element` emits its own
/// `.property` entry sharing the parent's start/end lines.
///
/// PHP namespaces emit as `.extension` for parity with Ruby modules
/// and Swift extensions, and do NOT act as containers — `helpers_boot`
/// inside `namespace Acme\Services { … }` is still a top-level
/// `.function` with `container: nil`.
///
/// Node coverage:
///   - class_declaration / trait_declaration  (.class, body recursed)
///   - interface_declaration                   (.interface, body recursed)
///   - enum_declaration                        (.enum, body recursed)
///   - method_declaration                      (.method via extractFunction)
///   - function_definition                     (.function via extractFunction)
///   - property_declaration                    (one .property per property_element)
///   - namespace_definition                    (.extension, body recursed
///                                              with the OUTER container)
internal enum PhpBackend: TreeSitterLanguageBackend {

    static func supports(_ language: String) -> Bool {
        language == "php"
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
            case "class_declaration", "trait_declaration":
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

            case "method_declaration":
                if let entry = TreeSitterBackend.extractFunction(child, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                }

            case "function_definition":
                if let entry = TreeSitterBackend.extractFunction(child, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                }

            case "property_declaration":
                for pi in 0..<Int(child.childCount) {
                    guard let propElem = child.child(at: pi),
                          propElem.nodeType == "property_element",
                          let name = TreeSitterBackend.nodeName(propElem, source: source) else { continue }
                    entries.append(IndexEntry(
                        name: name, kind: .property, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            case "namespace_definition":
                if let name = TreeSitterBackend.nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .extension, file: file,
                        startLine: TreeSitterBackend.startLine(of: child),
                        endLine: TreeSitterBackend.endLine(of: child),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }
                if let body = TreeSitterBackend.findBody(child) {
                    walk(body, file: file, source: source, lines: lines, container: container, entries: &entries)
                }

            default:
                if child.childCount > 0 {
                    walk(child, file: file, source: source, lines: lines, container: container, entries: &entries)
                }
            }
        }
    }
}
