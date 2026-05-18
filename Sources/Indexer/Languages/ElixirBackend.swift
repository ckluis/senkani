import Foundation
import SwiftTreeSitter

/// Elixir symbol-extraction backend.
///
/// Elixir has no dedicated declaration nodes — `defmodule`, `def`,
/// `defp`, `defmacro`, and `defmacrop` all parse as `call` nodes
/// whose first identifier child is the macro name. We disambiguate
/// by inspecting that identifier and unpacking the `arguments`
/// child:
///
///   - `defmodule Foo do` → first arg is an `alias` carrying the
///     module name; we emit it as `.class` and recurse into the
///     `do_block` with the module name as the container.
///   - `def hello do` / `def greet(name) do` → first arg is either
///     an `identifier` (no-arg) or a `call` whose target identifier
///     is the function name.
///
/// Node coverage:
///   - call (defmodule, def, defp, defmacro, defmacrop)
internal enum ElixirBackend: TreeSitterLanguageBackend {

    static func supports(_ language: String) -> Bool {
        language == "elixir"
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
    // 2026-05-11` (GoBackend pilot 2026-05-18, BashBackend / CBackend /
    // CppBackend / CSharpBackend / DartBackend predecessors 2026-05-18).
    // Elixir's substrate is novel vs the C-family chain — declarations
    // are `call` nodes whose first identifier child is the macro name.
    // The `defmodule` arm pushes the `do_block` body with the module
    // name as the new container; the `def`/`defp`/`defmacro`/
    // `defmacrop` arm emits the entry without descent; the call-with-
    // no-identifier-target fall-through pushes children with
    // currentContainer preserved (matches pre-refactor `walk(child,
    // container: container)`); the default arm pushes children with
    // currentContainer preserved.
    private static func walk(
        _ root: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        var stack: [(Node, String?)] = [(root, container)]
        while let (node, currentContainer) = stack.popLast() {
            let type = node.nodeType ?? ""

            switch type {
            case "call":
                guard let targetNode = TreeSitterBackend.findChildByType(node, type: "identifier"),
                      let target = TreeSitterBackend.nodeText(targetNode, source: source) else {
                    // No identifier target — push children with
                    // container preserved (matches pre-refactor
                    // `walk(child, ..., container: container)`).
                    let count = Int(node.childCount)
                    guard count > 0 else { continue }
                    for i in stride(from: count - 1, through: 0, by: -1) {
                        if let child = node.child(at: i) {
                            stack.append((child, currentContainer))
                        }
                    }
                    continue
                }
                switch target {
                case "defmodule":
                    if let name = extractModuleName(node, source: source) {
                        entries.append(IndexEntry(
                            name: name, kind: .class, file: file,
                            startLine: TreeSitterBackend.startLine(of: node),
                            endLine: TreeSitterBackend.endLine(of: node),
                            signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                            container: currentContainer, engine: "tree-sitter"
                        ))
                        if let doBlock = TreeSitterBackend.findChildByType(node, type: "do_block") {
                            // Re-bind container to the module name for
                            // the body's descendants — matches
                            // pre-refactor `walk(doBlock, ...,
                            // container: name)`.
                            stack.append((doBlock, name))
                        }
                    }
                case "def", "defp", "defmacro", "defmacrop":
                    if let name = extractFunctionName(node, source: source) {
                        let kind: SymbolKind = currentContainer != nil ? .method : .function
                        entries.append(IndexEntry(
                            name: name, kind: kind, file: file,
                            startLine: TreeSitterBackend.startLine(of: node),
                            endLine: TreeSitterBackend.endLine(of: node),
                            signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: node)),
                            container: currentContainer, engine: "tree-sitter"
                        ))
                    }
                    // No descent — matches pre-refactor.
                default:
                    break
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

    /// Extract the module name from a `defmodule` call: the first
    /// `alias` child of the `arguments` node carries the dotted name.
    private static func extractModuleName(_ callNode: Node, source: NSString) -> String? {
        guard let args = TreeSitterBackend.findChildByType(callNode, type: "arguments") else { return nil }
        for i in 0..<Int(args.childCount) {
            guard let arg = args.child(at: i) else { continue }
            if (arg.nodeType ?? "") == "alias" {
                return TreeSitterBackend.nodeText(arg, source: source)
            }
        }
        return nil
    }

    /// Extract the function name from a `def`/`defp`/`defmacro`/`defmacrop`
    /// call. Two shapes:
    ///   1. `def hello do` → arguments[0] is an `identifier`.
    ///   2. `def greet(name) do` → arguments[0] is a `call` whose
    ///      target identifier is the function name.
    private static func extractFunctionName(_ callNode: Node, source: NSString) -> String? {
        guard let args = TreeSitterBackend.findChildByType(callNode, type: "arguments") else { return nil }
        guard let firstArg = args.child(at: 0) else { return nil }
        switch firstArg.nodeType ?? "" {
        case "identifier":
            return TreeSitterBackend.nodeText(firstArg, source: source)
        case "call":
            if let target = TreeSitterBackend.findChildByType(firstArg, type: "identifier") {
                return TreeSitterBackend.nodeText(target, source: source)
            }
            return nil
        default:
            return nil
        }
    }
}
