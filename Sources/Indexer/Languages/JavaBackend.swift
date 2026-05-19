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

    // Iterative work-stack of (node, container) tuples. Replaces a
    // recursive descent so AST depth no longer consumes Swift call
    // frames. Chain child of `indexer-backends-iterative-walk-refactor-
    // 2026-05-11` (closest precedent: CSharpBackend's multi-site
    // class/struct/record/interface/enum rebind pattern). Java's
    // substrate has five body-rebind arms — class / interface / enum /
    // record / annotation_type — each emits then pushes the body with
    // container re-bound to the declared name, matching pre-refactor
    // `walk(body, ..., container: entry.name)`. method_declaration and
    // constructor_declaration emit without descent. The default arm
    // reverse-pushes children with currentContainer preserved so LIFO
    // pop reproduces left-to-right pre-order — symbol-emission order
    // matches pre-refactor exactly.
    private static func walk(
        _ root: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        var stack: [(Node, String?)] = [(root, container)]
        while let (node, currentContainer) = stack.popLast() {
            let type = node.nodeType ?? ""

            switch type {
            case "class_declaration":
                if let (entry, body) = TreeSitterBackend.extractTSDeclaration(node, kind: .class, file: file, source: source, lines: lines, container: currentContainer) {
                    entries.append(entry)
                    if let body = body {
                        // Re-bind container to the class name for the
                        // body's descendants — matches pre-refactor
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

            case "record_declaration":
                if let (entry, body) = TreeSitterBackend.extractTSDeclaration(node, kind: .struct, file: file, source: source, lines: lines, container: currentContainer) {
                    entries.append(entry)
                    if let body = body {
                        stack.append((body, entry.name))
                    }
                }

            case "annotation_type_declaration":
                if let (entry, body) = TreeSitterBackend.extractTSDeclaration(node, kind: .protocol, file: file, source: source, lines: lines, container: currentContainer) {
                    entries.append(entry)
                    if let body = body {
                        stack.append((body, entry.name))
                    }
                }

            case "method_declaration", "constructor_declaration":
                if let entry = TreeSitterBackend.extractFunction(node, file: file, source: source, lines: lines, container: currentContainer) {
                    entries.append(entry)
                }
                // No descent — matches pre-refactor.

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
