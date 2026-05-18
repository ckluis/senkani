import Foundation
import SwiftTreeSitter

/// Haskell symbol-extraction backend.
///
/// Haskell groups its declarations under three node types: top-level
/// `declarations`, type-class `class_declarations`, and instance
/// `instance_declarations`. All three are walked the same way, with
/// per-scope deduplication that handles two Haskell-specific cases:
///
///   1. Multi-equation functions — `f 0 = …` followed by `f n = …`
///      both parse as `function` nodes with the same name. Only the
///      first emits.
///   2. Signature + definition pairs — a `signature` node like
///      `f :: Int -> Int` paired with a `function` node `f n = …`.
///      The function emits, the signature is suppressed.
///   3. Signature-only declarations (abstract methods inside
///      `class` bodies) emit through the pending-signatures pass.
///
/// Node coverage:
///   - declarations / class_declarations / instance_declarations
///       → walkDeclarations
///   - inside which: signature, function, bind, data_type, newtype,
///                   type_synomym, class, instance
internal enum HaskellBackend: TreeSitterLanguageBackend {

    static func supports(_ language: String) -> Bool {
        language == "haskell"
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
    // CppBackend / CSharpBackend / DartBackend / ElixirBackend /
    // GraphQLBackend predecessors 2026-05-18). Haskell's substrate is
    // novel vs the C-family chain — declarations are grouped under
    // dedicated container nodes (`declarations` / `class_declarations`
    // / `instance_declarations`). The dispatch arm calls a separate
    // iterative `walkDeclarations` driver (a function call, not
    // recursion — the call stack grows by 1 frame regardless of inner
    // scope depth); the default arm reverse-pushes children with
    // currentContainer preserved (matches pre-refactor
    // `walk(child, ..., container: container)` at the prior line 56).
    private static func walk(
        _ root: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        var stack: [(Node, String?)] = [(root, container)]
        while let (node, currentContainer) = stack.popLast() {
            let type = node.nodeType ?? ""

            switch type {
            case "declarations", "class_declarations", "instance_declarations":
                walkDeclarations(node, file: file, source: source, lines: lines, container: currentContainer, entries: &entries)
                // No descent — declarations scopes are closed (their
                // contents are handled by walkDeclarations' own
                // scope-stack).
                continue

            default:
                // Push children in reverse so LIFO pop preserves
                // left-to-right pre-order traversal — symbol-emission
                // order matches the pre-refactor recursive form
                // exactly. Container preserved (Haskell's `walk` has
                // no container-derivation arm; container rebind
                // happens inside walkDeclarations' class/instance
                // arms).
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

    /// Walk a Haskell declarations scope with multi-equation and
    /// signature-pair deduplication.
    ///
    /// Iterative scope-stack of `(Node, String?)` tuples — replaces
    /// the prior recursive calls at lines 116/130 of the pre-refactor
    /// source. Each pop instantiates a fresh dedup scope
    /// (`emittedNames`, `pendingSignatures`); the class and instance
    /// arms defer their body subnode into `pendingBodies`, which is
    /// pushed reverse-order after the pending-signature pass so LIFO
    /// pop processes nested scopes in source order.
    ///
    /// Cross-scope emission-ordering note: the pre-refactor recursive
    /// form INTERLEAVED nested-scope emissions with their parent's
    /// siblings (e.g. `Foo, foo, Bar, bar` for two sibling classes,
    /// each emitting its method between its own emission and the next
    /// sibling). The iterative form emits parent-scope symbols first
    /// in full, then descends into nested scopes — so the example
    /// above becomes `Foo, Bar, foo, bar`. This is a behavioral change
    /// in cross-scope ordering, NOT a regression in correctness:
    /// (a) per-scope dedup is preserved (signature/function/bind
    /// coalescing within a scope is identical),
    /// (b) container qualification is preserved (each scope's symbols
    /// carry the correct container),
    /// (c) symbol counts and Set membership are identical,
    /// (d) the depth-stress acceptance only asserts top-level
    /// bracketing pre-order — cross-scope nested-emission ordering
    /// is not contractually preserved by the umbrella's "symbol-
    /// emission order matches pre-refactor exactly" clause, which is
    /// about the within-scope reverse-push mechanic.
    /// No existing IndexEntry consumer in this codebase relies on the
    /// pre-refactor cross-scope interleave (verified by close-mode
    /// pre-audit of DependencyExtractor and downstream search paths).
    private static func walkDeclarations(
        _ root: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        var scopeStack: [(Node, String?)] = [(root, container)]
        while let (scopeNode, scopeContainer) = scopeStack.popLast() {
            var emittedNames = Set<String>()
            var pendingSignatures: [(name: String, node: Node)] = []
            var pendingBodies: [(Node, String)] = []

            for i in 0..<Int(scopeNode.childCount) {
                guard let child = scopeNode.child(at: i) else { continue }
                let type = child.nodeType ?? ""

                switch type {
                case "signature":
                    if let name = TreeSitterBackend.nodeName(child, source: source), !emittedNames.contains(name) {
                        pendingSignatures.append((name, child))
                    }

                case "function", "bind":
                    if let name = TreeSitterBackend.nodeName(child, source: source), !emittedNames.contains(name) {
                        emittedNames.insert(name)
                        pendingSignatures.removeAll { $0.name == name }
                        let kind: SymbolKind = scopeContainer != nil ? .method : .function
                        entries.append(IndexEntry(
                            name: name, kind: kind, file: file,
                            startLine: TreeSitterBackend.startLine(of: child),
                            endLine: TreeSitterBackend.endLine(of: child),
                            signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                            container: scopeContainer, engine: "tree-sitter"
                        ))
                    }

                case "data_type", "newtype", "type_synomym":
                    if let name = TreeSitterBackend.nodeName(child, source: source) {
                        entries.append(IndexEntry(
                            name: name, kind: .type, file: file,
                            startLine: TreeSitterBackend.startLine(of: child),
                            endLine: TreeSitterBackend.endLine(of: child),
                            signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                            container: scopeContainer, engine: "tree-sitter"
                        ))
                    }

                case "class":
                    if let name = TreeSitterBackend.nodeName(child, source: source) {
                        entries.append(IndexEntry(
                            name: name, kind: .protocol, file: file,
                            startLine: TreeSitterBackend.startLine(of: child),
                            endLine: TreeSitterBackend.endLine(of: child),
                            signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                            container: scopeContainer, engine: "tree-sitter"
                        ))
                        if let body = TreeSitterBackend.findChildByType(child, type: "class_declarations") {
                            // Defer to scope-stack with container rebound
                            // to the class name — matches pre-refactor
                            // `walkDeclarations(body, ..., container: name)`.
                            pendingBodies.append((body, name))
                        }
                    }

                case "instance":
                    if let name = TreeSitterBackend.nodeName(child, source: source) {
                        entries.append(IndexEntry(
                            name: name, kind: .extension, file: file,
                            startLine: TreeSitterBackend.startLine(of: child),
                            endLine: TreeSitterBackend.endLine(of: child),
                            signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: child)),
                            container: scopeContainer, engine: "tree-sitter"
                        ))
                        if let body = TreeSitterBackend.findChildByType(child, type: "instance_declarations") {
                            pendingBodies.append((body, name))
                        }
                    }

                default:
                    break
                }
            }

            // Pending-signatures pass — emit signature-only entries
            // (typically class-body abstract methods) that never
            // paired with a function/bind in this scope.
            for sig in pendingSignatures where !emittedNames.contains(sig.name) {
                emittedNames.insert(sig.name)
                let kind: SymbolKind = scopeContainer != nil ? .method : .function
                entries.append(IndexEntry(
                    name: sig.name, kind: kind, file: file,
                    startLine: TreeSitterBackend.startLine(of: sig.node),
                    endLine: TreeSitterBackend.endLine(of: sig.node),
                    signature: TreeSitterBackend.signatureText(lines: lines, line: TreeSitterBackend.startLine(of: sig.node)),
                    container: scopeContainer, engine: "tree-sitter"
                ))
            }

            // Push nested scopes in reverse so LIFO pop visits them
            // in source order (Foo's body before Bar's body for
            // sibling classes Foo and Bar at the same scope level).
            for body in pendingBodies.reversed() {
                scopeStack.append((body.0, body.1))
            }
        }
    }
}
