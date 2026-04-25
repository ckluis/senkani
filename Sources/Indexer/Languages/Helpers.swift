import Foundation
import SwiftTreeSitter

// MARK: - Shared tree-sitter helpers
//
// These were once `private static` on `TreeSitterBackend`. They are
// promoted to `internal` here so the per-language backends in
// `Sources/Indexer/Languages/` can reuse them without copy-paste.
// They remain semantically methods on `TreeSitterBackend` (extension)
// so existing call sites inside `TreeSitterBackend.swift` need no
// edits during migration.
//
// Add new helpers here when they are called from more than one
// language backend. Single-language helpers stay private to their
// backend file.

extension TreeSitterBackend {

    // MARK: - Shared Extractors

    /// Generic function-like extractor. Uses the node's `name` field
    /// to pull the symbol name; emits `.method` if a container is
    /// set, else `.function`. Used for: function_declaration,
    /// function_definition, method_definition, method_declaration
    /// (non-Go), function_item, function_signature_item,
    /// constructor_declaration, destructor_declaration.
    internal static func extractFunction(
        _ node: Node, file: String, source: NSString, lines: [String], container: String?
    ) -> IndexEntry? {
        guard let name = nodeName(node, source: source) else { return nil }
        let kind: SymbolKind = container != nil ? .method : .function
        return IndexEntry(
            name: name,
            kind: kind,
            file: file,
            startLine: startLine(of: node),
            endLine: endLine(of: node),
            signature: signatureText(lines: lines, line: startLine(of: node)),
            container: container,
            engine: "tree-sitter"
        )
    }

    // MARK: - Swift Extractors

    /// Extracts Swift class/struct/enum/extension declarations.
    internal static func extractSwiftClassLike(
        _ node: Node, file: String, source: NSString, lines: [String], container: String?
    ) -> (IndexEntry, Node?)? {
        let kind: SymbolKind
        var declKindText = ""
        for i in 0..<Int(node.childCount) {
            guard let child = node.child(at: i) else { continue }
            let t = child.nodeType ?? ""
            if ["class", "struct", "enum", "actor", "extension"].contains(t) {
                declKindText = t
                break
            }
        }

        switch declKindText {
        case "class", "actor": kind = .class
        case "struct": kind = .struct
        case "enum": kind = .enum
        case "extension": kind = .extension
        default: return nil
        }

        let name: String
        if let n = nodeName(node, source: source) {
            name = n
        } else if kind == .extension, let typeName = extensionTypeName(node, source: source) {
            name = typeName
        } else {
            return nil
        }

        let body = findBody(node)
        let entry = IndexEntry(
            name: name,
            kind: kind,
            file: file,
            startLine: startLine(of: node),
            endLine: endLine(of: node),
            signature: signatureText(lines: lines, line: startLine(of: node)),
            container: container,
            engine: "tree-sitter"
        )

        return (entry, body)
    }

    internal static func extractProtocol(
        _ node: Node, file: String, source: NSString, lines: [String], container: String?
    ) -> (IndexEntry, Node?)? {
        guard let name = nodeName(node, source: source) else { return nil }
        let body = findBody(node)
        let entry = IndexEntry(
            name: name,
            kind: .protocol,
            file: file,
            startLine: startLine(of: node),
            endLine: endLine(of: node),
            signature: signatureText(lines: lines, line: startLine(of: node)),
            container: container,
            engine: "tree-sitter"
        )
        return (entry, body)
    }

    internal static func extractProperty(
        _ node: Node, file: String, source: NSString, lines: [String], container: String?
    ) -> IndexEntry? {
        guard let name = findFirstIdentifier(in: node, source: source) else { return nil }
        let kind: SymbolKind = container != nil ? .property : .variable
        return IndexEntry(
            name: name,
            kind: kind,
            file: file,
            startLine: startLine(of: node),
            endLine: endLine(of: node),
            signature: signatureText(lines: lines, line: startLine(of: node)),
            container: container,
            engine: "tree-sitter"
        )
    }

    // MARK: - Python Extractors

    /// Extracts a Python class_definition.
    internal static func extractPythonClass(
        _ node: Node, file: String, source: NSString, lines: [String], container: String?
    ) -> (IndexEntry, Node?)? {
        guard let name = nodeName(node, source: source) else { return nil }
        let body = findBody(node)
        let entry = IndexEntry(
            name: name,
            kind: .class,
            file: file,
            startLine: startLine(of: node),
            endLine: endLine(of: node),
            signature: signatureText(lines: lines, line: startLine(of: node)),
            container: container,
            engine: "tree-sitter"
        )
        return (entry, body)
    }

    // MARK: - TypeScript/TSX Extractors

    /// Extracts a TypeScript/TSX declaration with a name field and optional body.
    internal static func extractTSDeclaration(
        _ node: Node, kind: SymbolKind, file: String, source: NSString, lines: [String], container: String?
    ) -> (IndexEntry, Node?)? {
        guard let name = nodeName(node, source: source) else { return nil }
        let body = findBody(node)
        let entry = IndexEntry(
            name: name,
            kind: kind,
            file: file,
            startLine: startLine(of: node),
            endLine: endLine(of: node),
            signature: signatureText(lines: lines, line: startLine(of: node)),
            container: container,
            engine: "tree-sitter"
        )
        return (entry, body)
    }

    // MARK: - Go Extractors

    /// Extracts a Go method_declaration with receiver-based container.
    internal static func extractGoMethod(
        _ node: Node, file: String, source: NSString, lines: [String]
    ) -> IndexEntry? {
        guard let name = nodeName(node, source: source) else { return nil }
        let container = extractGoReceiverType(node, source: source)
        return IndexEntry(
            name: name,
            kind: .method,
            file: file,
            startLine: startLine(of: node),
            endLine: endLine(of: node),
            signature: signatureText(lines: lines, line: startLine(of: node)),
            container: container,
            engine: "tree-sitter"
        )
    }

    /// Extract the receiver type from a Go method_declaration.
    /// Handles both value receivers `(u User)` and pointer receivers `(u *User)`.
    internal static func extractGoReceiverType(_ node: Node, source: NSString) -> String? {
        // receiver field is a parameter_list
        guard let receiver = node.child(byFieldName: "receiver") else { return nil }
        // Walk into first parameter_declaration
        for i in 0..<Int(receiver.childCount) {
            guard let param = receiver.child(at: i) else { continue }
            let paramType = param.nodeType ?? ""
            if paramType == "parameter_declaration" {
                // Find the type field — either type_identifier or pointer_type
                if let typeNode = param.child(byFieldName: "type") {
                    let typeNodeType = typeNode.nodeType ?? ""
                    if typeNodeType == "type_identifier" {
                        return nodeText(typeNode, source: source)
                    } else if typeNodeType == "pointer_type" {
                        // pointer_type contains a type_identifier child
                        for j in 0..<Int(typeNode.childCount) {
                            guard let inner = typeNode.child(at: j) else { continue }
                            if (inner.nodeType ?? "") == "type_identifier" {
                                return nodeText(inner, source: source)
                            }
                        }
                    }
                }
            }
        }
        return nil
    }

    /// Extracts Go type declarations from a type_declaration node.
    /// A type_declaration can contain multiple type_spec children.
    internal static func extractGoTypeDeclaration(
        _ node: Node, file: String, source: NSString, lines: [String], entries: inout [IndexEntry]
    ) {
        for i in 0..<Int(node.childCount) {
            guard let child = node.child(at: i) else { continue }
            let childType = child.nodeType ?? ""
            if childType == "type_spec" {
                if let entry = extractGoTypeSpec(child, file: file, source: source, lines: lines) {
                    entries.append(entry)
                }
            }
        }
    }

    /// Extracts a single Go type_spec (name + type).
    internal static func extractGoTypeSpec(
        _ node: Node, file: String, source: NSString, lines: [String]
    ) -> IndexEntry? {
        guard let name = nodeName(node, source: source) else { return nil }
        // Determine kind from the type field
        let kind: SymbolKind
        if let typeNode = node.child(byFieldName: "type") {
            let typeNodeType = typeNode.nodeType ?? ""
            switch typeNodeType {
            case "struct_type": kind = .struct
            case "interface_type": kind = .interface
            default: kind = .type
            }
        } else {
            kind = .type
        }
        return IndexEntry(
            name: name,
            kind: kind,
            file: file,
            startLine: startLine(of: node),
            endLine: endLine(of: node),
            signature: signatureText(lines: lines, line: startLine(of: node)),
            container: nil,
            engine: "tree-sitter"
        )
    }

    // MARK: - Rust Extractors

    /// Extract the type name from a Rust impl_item.
    /// Handles: `impl User`, `impl<T> Wrapper<T>`, `impl Display for User` (returns "User").
    internal static func extractRustImplType(_ node: Node, source: NSString) -> String? {
        // The "type" field is the type being implemented (e.g., User in `impl Display for User`)
        guard let typeNode = node.child(byFieldName: "type") else { return nil }
        return extractRustTypeName(typeNode, source: source)
    }

    /// Extract the base type name from a Rust type node.
    /// Handles type_identifier, generic_type (strips <T>), and scoped_type_identifier.
    internal static func extractRustTypeName(_ node: Node, source: NSString) -> String? {
        let type = node.nodeType ?? ""
        switch type {
        case "type_identifier":
            return nodeText(node, source: source)
        case "generic_type":
            // generic_type contains a type_identifier child for the base name
            if let typeId = node.child(byFieldName: "type") {
                return extractRustTypeName(typeId, source: source)
            }
            // Fallback: first type_identifier child
            for i in 0..<Int(node.childCount) {
                guard let child = node.child(at: i) else { continue }
                if (child.nodeType ?? "") == "type_identifier" {
                    return nodeText(child, source: source)
                }
            }
            return nil
        case "scoped_type_identifier":
            // For module::Type, extract the last type_identifier
            for i in stride(from: Int(node.childCount) - 1, through: 0, by: -1) {
                guard let child = node.child(at: i) else { continue }
                if (child.nodeType ?? "") == "type_identifier" {
                    return nodeText(child, source: source)
                }
            }
            return nil
        default:
            return nodeText(node, source: source)
        }
    }

    // MARK: - Lua Extractors

    /// Extract function name and optional container from a Lua function_declaration.
    /// Handles three forms:
    /// - `function foo()` → ("foo", nil)
    /// - `function M.greet()` → ("greet", "M")
    /// - `function M:say()` → ("say", "M")
    internal static func extractLuaFunctionName(_ node: Node, source: NSString) -> (name: String, container: String?)? {
        guard let nameNode = node.child(byFieldName: "name") else { return nil }
        let nameType = nameNode.nodeType ?? ""

        switch nameType {
        case "identifier":
            guard let name = nodeText(nameNode, source: source) else { return nil }
            return (name, nil)
        case "dot_index_expression":
            guard let fieldNode = nameNode.child(byFieldName: "field"),
                  let tableNode = nameNode.child(byFieldName: "table"),
                  let field = nodeText(fieldNode, source: source),
                  let table = nodeText(tableNode, source: source) else { return nil }
            return (field, table)
        case "method_index_expression":
            guard let methodNode = nameNode.child(byFieldName: "method"),
                  let tableNode = nameNode.child(byFieldName: "table"),
                  let method = nodeText(methodNode, source: source),
                  let table = nodeText(tableNode, source: source) else { return nil }
            return (method, table)
        default:
            return nil
        }
    }

    // MARK: - C++ Extractors

    /// Extract method name and container from a C++ out-of-class method definition.
    /// Handles: `void Foo::bar() { }` and `int *Foo::baz() { }`.
    internal static func extractCppQualifiedMethod(_ node: Node, source: NSString) -> (name: String, container: String)? {
        guard let qualId = findQualifiedIdentifier(node) else { return nil }
        guard let nameNode = qualId.child(byFieldName: "name") else { return nil }
        guard let name = nodeText(nameNode, source: source) else { return nil }
        guard let scopeNode = qualId.child(byFieldName: "scope") else { return nil }
        guard let scope = nodeText(scopeNode, source: source) else { return nil }
        return (name, scope)
    }

    /// Find a qualified_identifier node in the declarator chain.
    internal static func findQualifiedIdentifier(_ node: Node) -> Node? {
        guard let declarator = node.child(byFieldName: "declarator") else { return nil }
        if (declarator.nodeType ?? "") == "qualified_identifier" { return declarator }
        return findQualifiedIdentifier(declarator)
    }

    // MARK: - C Extractors

    /// Extract the symbol name from a C declarator chain.
    /// Traverses: function_declarator, pointer_declarator, parenthesized_declarator → identifier.
    internal static func extractCDeclaratorName(_ node: Node, source: NSString) -> String? {
        let type = node.nodeType ?? ""
        if type == "identifier" || type == "type_identifier" || type == "field_identifier" {
            return nodeText(node, source: source)
        }
        if let declarator = node.child(byFieldName: "declarator") {
            return extractCDeclaratorName(declarator, source: source)
        }
        for i in 0..<Int(node.childCount) {
            guard let child = node.child(at: i) else { continue }
            let childType = child.nodeType ?? ""
            if childType == "identifier" || childType == "type_identifier" || childType == "field_identifier" {
                return nodeText(child, source: source)
            }
        }
        for i in 0..<Int(node.childCount) {
            guard let child = node.child(at: i) else { continue }
            let childType = child.nodeType ?? ""
            if childType != "parameter_list" && childType != "argument_list" {
                if let name = extractCDeclaratorName(child, source: source) {
                    return name
                }
            }
        }
        return nil
    }

    /// Check if a C declaration contains a function_declarator in its declarator chain.
    internal static func cHasFunctionDeclarator(_ node: Node) -> Bool {
        guard let declarator = node.child(byFieldName: "declarator") else { return false }
        let type = declarator.nodeType ?? ""
        if type == "function_declarator" { return true }
        return cHasFunctionDeclarator(declarator)
    }

    // MARK: - Node Helpers

    /// Extract text from a node using its NSRange and the source NSString.
    internal static func nodeText(_ node: Node, source: NSString) -> String? {
        let range = node.range
        guard range.location != NSNotFound, NSMaxRange(range) <= source.length else { return nil }
        return source.substring(with: range)
    }

    /// Get the name from a node's "name" field.
    internal static func nodeName(_ node: Node, source: NSString) -> String? {
        guard let nameNode = node.child(byFieldName: "name") else { return nil }
        return nodeText(nameNode, source: source)
    }

    /// For Swift extension declarations, extract the extended type name.
    internal static func extensionTypeName(_ node: Node, source: NSString) -> String? {
        var pastKeyword = false
        for i in 0..<Int(node.childCount) {
            guard let child = node.child(at: i) else { continue }
            let t = child.nodeType ?? ""
            if t == "extension" { pastKeyword = true; continue }
            if pastKeyword && (t == "type_identifier" || t == "user_type") {
                return nodeText(child, source: source)
            }
        }
        return nil
    }

    /// Find the first child node of a given type (for grammars without field names, e.g. Kotlin).
    internal static func findChildByType(_ node: Node, type: String) -> Node? {
        for i in 0..<Int(node.childCount) {
            guard let child = node.child(at: i) else { continue }
            if child.nodeType == type { return child }
        }
        return nil
    }

    /// Find the body node inside a declaration.
    internal static func findBody(_ node: Node) -> Node? {
        if let body = node.child(byFieldName: "body") { return body }
        for i in 0..<Int(node.childCount) {
            guard let child = node.child(at: i) else { continue }
            let t = child.nodeType ?? ""
            if t.hasSuffix("_body") { return child }
        }
        return nil
    }

    /// Find the first simple_identifier descendant (for Swift property patterns).
    internal static func findFirstIdentifier(in node: Node, source: NSString) -> String? {
        let type = node.nodeType ?? ""
        if type == "simple_identifier" { return nodeText(node, source: source) }
        for i in 0..<Int(node.childCount) {
            guard let child = node.child(at: i) else { continue }
            let childType = child.nodeType ?? ""
            if childType == "type_annotation" || childType == "call_expression"
                || childType == "value_arguments" { continue }
            if let found = findFirstIdentifier(in: child, source: source) { return found }
        }
        return nil
    }

    /// 1-based start line from a node's point range.
    internal static func startLine(of node: Node) -> Int {
        Int(node.pointRange.lowerBound.row) + 1
    }

    /// 1-based end line from a node's point range.
    internal static func endLine(of node: Node) -> Int {
        Int(node.pointRange.upperBound.row) + 1
    }

    /// Extract the signature text from the source lines.
    internal static func signatureText(lines: [String], line: Int) -> String {
        guard line > 0, line <= lines.count else { return "" }
        return lines[line - 1].trimmingCharacters(in: .whitespaces)
    }
}
