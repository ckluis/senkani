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

    // Iterative work-stack of (node, container) tuples. Replaces a
    // recursive descent so AST depth no longer consumes Swift call
    // frames. Chain child of `indexer-backends-iterative-walk-refactor-
    // 2026-05-11` (closest precedent: JavaBackend's multi-site
    // class/interface/enum/record/annotation_type rebind pattern).
    // PHP's substrate has three body-rebind arms — class_declaration /
    // trait_declaration, interface_declaration, enum_declaration —
    // each emits then pushes the body with container re-bound to the
    // declared name, matching pre-refactor
    // `walk(body, ..., container: entry.name)`. namespace_definition
    // is a fourth arm but with a PHP-specific quirk: it emits the
    // namespace as `.extension` and pushes its body with
    // `currentContainer` PRESERVED (NOT the namespace name) — PHP
    // namespaces do not act as containers (per the docstring above:
    // "helpers_boot inside `namespace Acme\\Services { … }` is still a
    // top-level `.function` with `container: nil`"). method_declaration,
    // function_definition, and property_declaration emit without
    // descent (the property_declaration arm iterates its
    // property_element children for emission only — those children
    // are leaves, not nodes to push onto the work-stack). The default
    // arm reverse-pushes children with currentContainer preserved so
    // LIFO pop reproduces left-to-right pre-order — symbol-emission
    // order matches pre-refactor exactly.
    private static func walk(
        _ root: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        var stack: [(Node, String?)] = [(root, container)]
        while let (node, currentContainer) = stack.popLast() {
            let type = node.nodeType ?? ""

            switch type {
            case "class_declaration", "trait_declaration":
                if let (entry, body) = TreeSitterBackend.extractTSDeclaration(node, kind: .class, file: file, source: source, lines: lines, container: currentContainer) {
                    entries.append(entry)
                    if let body = body {
                        // Re-bind container to the class/trait name for
                        // the body's descendants — matches pre-refactor
                        // `walk(body, ..., container: entry.name)`.
                        stack.append((body, entry.name))
                    }
                }

            case "interface_declaration":
                if let (entry, body) = TreeSitterBackend.extractTSDeclaration(node, kind: .interface, file: file, source: source, lines: lines, container: currentContainer) {
                    entries.append(entry)
                    if let body = body {
                        stack.append((body, entry.name))
                    }
                }

            case "enum_declaration":
                if let (entry, body) = TreeSitterBackend.extractTSDeclaration(node, kind: .enum, file: file, source: source, lines: lines, container: currentContainer) {
                    entries.append(entry)
                    if let body = body {
                        stack.append((body, entry.name))
                    }
                }

            case "method_declaration":
                if let entry = TreeSitterBackend.extractFunction(node, file: file, source: source, lines: lines, container: currentContainer) {
                    entries.append(entry)
                }
                // No descent — matches pre-refactor.

            case "function_definition":
                if let entry = TreeSitterBackend.extractFunction(node, file: file, source: source, lines: lines, container: currentContainer) {
                    entries.append(entry)
                }
                // No descent — matches pre-refactor.

            case "property_declaration":
                for pi in 0..<Int(node.childCount) {
                    guard let propElem = node.child(at: pi),
                          propElem.nodeType == "property_element",
                          let name = TreeSitterBackend.nodeName(propElem, source: source) else { continue }
                    entries.append(IndexEntry(
                        name: name, kind: .property, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                }
                // No descent — property_element children are leaves,
                // emitted in the loop above; matches pre-refactor.

            case "namespace_definition":
                if let name = TreeSitterBackend.nodeName(node, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .extension, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                }
                if let body = TreeSitterBackend.findBody(node) {
                    // PHP namespaces do NOT act as containers — push
                    // the body with currentContainer preserved, NOT
                    // the namespace name. Matches pre-refactor line
                    // 111's `walk(body, ..., container: container)`.
                    stack.append((body, currentContainer))
                }

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
