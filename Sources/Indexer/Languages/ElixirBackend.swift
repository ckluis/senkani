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

    private static func walk(
        _ node: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        for i in 0..<Int(node.childCount) {
            guard let child = node.child(at: i) else { continue }
            let type = child.nodeType ?? ""

            switch type {
            case "call":
                guard let targetNode = TreeSitterBackend.findChildByType(child, type: "identifier"),
                      let target = TreeSitterBackend.nodeText(targetNode, source: source) else {
                    if child.childCount > 0 {
                        walk(child, file: file, source: source, lines: lines, container: container, entries: &entries)
                    }
                    break
                }
                switch target {
                case "defmodule":
                    if let name = extractModuleName(child, source: source) {
                        entries.append(IndexEntry(
                            name: name, kind: .class, file: file,
                            startLine: TreeSitterBackend.startLine(of: child),
                            endLine: TreeSitterBackend.endLine(of: child),
                            signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                            container: container, engine: "tree-sitter"
                        ))
                        if let doBlock = TreeSitterBackend.findChildByType(child, type: "do_block") {
                            walk(doBlock, file: file, source: source, lines: lines, container: name, entries: &entries)
                        }
                    }
                case "def", "defp", "defmacro", "defmacrop":
                    if let name = extractFunctionName(child, source: source) {
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
                    break
                }

            default:
                if child.childCount > 0 {
                    walk(child, file: file, source: source, lines: lines, container: container, entries: &entries)
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
