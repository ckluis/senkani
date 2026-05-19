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

    // Iterative work-stack of (node, container) tuples. Replaces a
    // recursive descent so AST depth no longer consumes Swift call
    // frames on the cooperative pool. Umbrella chain child of
    // `indexer-backends-iterative-walk-refactor-2026-05-11`
    // (alphabetical successor to RubyBackend; closest precedents
    // RubyBackend and PhpBackend's multi-arm body-rebind patterns).
    // Rust's substrate has TWO body-rebind arms with different
    // emit semantics: `trait_item` emits an entry then pushes the
    // body with container re-bound to the trait name; `impl_item`
    // does NOT emit (impl blocks are not symbols themselves) but
    // pushes the body with container re-bound to the impl'd type
    // via `extractRustImplType` (handles `impl User`,
    // `impl<T> Wrapper<T>`, `impl Display for User` — returns the
    // impl'd type name, never the trait name). Leaf-emit arms
    // (`function_item` / `function_signature_item`, `struct_item`,
    // `enum_item`, `type_item`) emit without descent — function
    // bodies are not source for top-level declarations the walk
    // reaches. The default arm reverse-pushes children with
    // currentContainer preserved so LIFO pop reproduces
    // left-to-right pre-order — symbol-emission order matches
    // pre-refactor exactly.
    private static func walk(
        _ root: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        var stack: [(Node, String?)] = [(root, container)]
        while let (node, currentContainer) = stack.popLast() {
            let type = node.nodeType ?? ""

            switch type {
            case "function_item", "function_signature_item":
                if let entry = TreeSitterBackend.extractFunction(node, file: file, source: source, lines: lines, container: currentContainer) {
                    entries.append(entry)
                }
                // No descent — matches pre-refactor.

            case "struct_item":
                if let name = TreeSitterBackend.nodeName(node, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .struct, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                }

            case "enum_item":
                if let name = TreeSitterBackend.nodeName(node, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .enum, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                }

            case "trait_item":
                if let name = TreeSitterBackend.nodeName(node, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .protocol, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                    if let body = TreeSitterBackend.findBody(node) {
                        // Re-bind container to the trait name for the
                        // body's descendants — matches pre-refactor
                        // `walk(body, ..., container: name)`.
                        stack.append((body, name))
                    }
                }

            case "type_item":
                if let name = TreeSitterBackend.nodeName(node, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .type, file: file,
                        startLine: TreeSitterBackend.startLine(of: node),
                        endLine: TreeSitterBackend.endLine(of: node),
                        signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                        container: currentContainer, engine: "tree-sitter"
                    ))
                }

            case "impl_item":
                // Emit-less body-rebind arm — impl blocks are not
                // symbols themselves but their bodies carry the
                // impl'd type as container so inner methods land as
                // `.method` with the right owner. Matches pre-refactor
                // `walk(body, ..., container: implContainer)`.
                let implContainer = TreeSitterBackend.extractRustImplType(node, source: source)
                if let body = TreeSitterBackend.findBody(node) {
                    stack.append((body, implContainer))
                }

            default:
                // Push children in reverse so LIFO pop preserves
                // left-to-right pre-order traversal — symbol-emission
                // order matches the pre-refactor recursive form
                // exactly. The pre-refactor default arm guarded with
                // `if child.childCount > 0`; the iterative form's
                // `guard count > 0 else continue` reproduces that —
                // childless leaves popped here fall through as a
                // no-op exactly as the pre-refactor's guard skipped
                // them.
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
