import Foundation
import SwiftTreeSitter
import TreeSitterSwiftParser
import TreeSitterPythonParser
import TreeSitterTypeScriptParser
import TreeSitterTSXParser
import TreeSitterJavaScriptParser
import TreeSitterGoParser
import TreeSitterRustParser
import TreeSitterJavaParser
import TreeSitterCParser
import TreeSitterCppParser
import TreeSitterCSharpParser
import TreeSitterRubyParser
import TreeSitterPhpParser
import TreeSitterKotlinParser
import TreeSitterBashParser
import TreeSitterLuaParser
import TreeSitterScalaParser
import TreeSitterElixirParser
import TreeSitterHaskellParser
import TreeSitterZigParser
import TreeSitterHtmlParser
import TreeSitterCssParser

/// AST-based indexer using tree-sitter for supported languages.
/// Provides accurate symbol extraction with proper container tracking
/// and exact end-line detection (no brace-depth estimation).
public enum TreeSitterBackend {

    /// Languages with vendored tree-sitter grammars.
    public static let supportedLanguages: Set<String> = ["swift", "python", "typescript", "tsx", "javascript", "go", "rust", "java", "c", "cpp", "csharp", "ruby", "php", "kotlin", "bash", "lua", "scala", "elixir", "haskell", "zig", "html", "css"]

    /// Whether tree-sitter supports the given language.
    public static func supports(_ language: String) -> Bool {
        supportedLanguages.contains(language)
    }

    /// Return the tree-sitter Language for a given language identifier.
    /// Used by DependencyExtractor to share parser creation without duplicating the switch.
    public static func language(for lang: String) -> Language? {
        switch lang {
        case "swift":      return Language(language: tree_sitter_swift())
        case "python":     return Language(language: tree_sitter_python())
        case "typescript":  return Language(language: tree_sitter_typescript())
        case "tsx":        return Language(language: tree_sitter_tsx())
        case "javascript": return Language(language: tree_sitter_javascript())
        case "go":         return Language(language: tree_sitter_go())
        case "rust":       return Language(language: tree_sitter_rust())
        case "java":       return Language(language: tree_sitter_java())
        case "c":          return Language(language: tree_sitter_c())
        case "cpp":        return Language(language: tree_sitter_cpp())
        case "csharp":     return Language(language: tree_sitter_c_sharp())
        case "ruby":       return Language(language: tree_sitter_ruby())
        case "php":        return Language(language: tree_sitter_php())
        case "kotlin":     return Language(language: tree_sitter_kotlin())
        case "bash":       return Language(language: tree_sitter_bash())
        case "lua":        return Language(language: tree_sitter_lua())
        case "scala":      return Language(language: tree_sitter_scala())
        case "elixir":     return Language(language: tree_sitter_elixir())
        case "haskell":    return Language(language: tree_sitter_haskell())
        case "zig":        return Language(language: tree_sitter_zig())
        case "html":       return Language(language: tree_sitter_html())
        case "css":        return Language(language: tree_sitter_css())
        default:           return nil
        }
    }

    /// Extract symbols from a pre-parsed tree's root node.
    /// Used by IncrementalParser to re-extract symbols without re-parsing the file.
    public static func extractSymbols(
        from root: Node,
        source: String,
        language: String,
        file: String
    ) -> [IndexEntry] {
        let ns = source as NSString
        let lines = source.components(separatedBy: "\n")
        var entries: [IndexEntry] = []
        walkNode(root, language: language, file: file, source: ns, lines: lines, container: nil, entries: &entries)
        return entries
    }

    /// Index files of a given language using tree-sitter AST parsing.
    /// When a `treeCache` is provided, parsed trees are stored for later incremental re-parsing.
    public static func index(files: [String], language: String, projectRoot: String, treeCache: TreeCache? = nil) -> [IndexEntry] {
        let parser = Parser()
        let tsLanguage: Language
        switch language {
        case "swift":
            tsLanguage = Language(language: tree_sitter_swift())
        case "python":
            tsLanguage = Language(language: tree_sitter_python())
        case "typescript":
            tsLanguage = Language(language: tree_sitter_typescript())
        case "tsx":
            tsLanguage = Language(language: tree_sitter_tsx())
        case "javascript":
            tsLanguage = Language(language: tree_sitter_javascript())
        case "go":
            tsLanguage = Language(language: tree_sitter_go())
        case "rust":
            tsLanguage = Language(language: tree_sitter_rust())
        case "java":
            tsLanguage = Language(language: tree_sitter_java())
        case "c":
            tsLanguage = Language(language: tree_sitter_c())
        case "cpp":
            tsLanguage = Language(language: tree_sitter_cpp())
        case "csharp":
            tsLanguage = Language(language: tree_sitter_c_sharp())
        case "ruby":
            tsLanguage = Language(language: tree_sitter_ruby())
        case "php":
            tsLanguage = Language(language: tree_sitter_php())
        case "kotlin":
            tsLanguage = Language(language: tree_sitter_kotlin())
        case "bash":
            tsLanguage = Language(language: tree_sitter_bash())
        case "lua":
            tsLanguage = Language(language: tree_sitter_lua())
        case "scala":
            tsLanguage = Language(language: tree_sitter_scala())
        case "elixir":
            tsLanguage = Language(language: tree_sitter_elixir())
        case "haskell":
            tsLanguage = Language(language: tree_sitter_haskell())
        case "zig":
            tsLanguage = Language(language: tree_sitter_zig())
        case "html":
            tsLanguage = Language(language: tree_sitter_html())
        case "css":
            tsLanguage = Language(language: tree_sitter_css())
        default:
            return []
        }
        do { try parser.setLanguage(tsLanguage) } catch { return [] }

        var entries: [IndexEntry] = []

        for relativePath in files {
            let fullPath = projectRoot + "/" + relativePath
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }
            guard let tree = parser.parse(content) else { continue }
            guard let root = tree.rootNode else { continue }

            // Populate cache for incremental re-parsing
            if let cache = treeCache {
                let hash = TreeCache.hash(content)
                cache.store(file: relativePath, tree: tree, content: content, contentHash: hash, language: language)
            }

            let source = content as NSString
            let lines = content.components(separatedBy: "\n")
            walkNode(root, language: language, file: relativePath, source: source, lines: lines, container: nil, entries: &entries)
        }

        return entries
    }

    // MARK: - AST Walking

    private static func walkNode(
        _ node: Node,
        language: String,
        file: String,
        source: NSString,
        lines: [String],
        container: String?,
        entries: inout [IndexEntry]
    ) {
        for i in 0..<Int(node.childCount) {
            guard let child = node.child(at: i) else { continue }
            let type = child.nodeType ?? ""

            switch type {
            // Swift + TypeScript/TSX/JavaScript + Kotlin + Lua + Zig function declarations
            case "function_declaration", "protocol_function_declaration", "generator_function_declaration":
                if language == "zig" {
                    // Zig: function name is an identifier child, not a "name" field
                    if let nameNode = findChildByType(child, type: "identifier"),
                       let name = nodeText(nameNode, source: source) {
                        let kind: SymbolKind = container != nil ? .method : .function
                        entries.append(IndexEntry(
                            name: name, kind: kind, file: file,
                            startLine: startLine(of: child), endLine: endLine(of: child),
                            signature: signatureText(lines: lines, line: startLine(of: child)),
                            container: container, engine: "tree-sitter"
                        ))
                    }
                } else if language == "kotlin" {
                    // Kotlin grammar has no field names — find simple_identifier child
                    if let nameNode = findChildByType(child, type: "simple_identifier"),
                       let name = nodeText(nameNode, source: source) {
                        let kind: SymbolKind = container != nil ? .method : .function
                        entries.append(IndexEntry(
                            name: name, kind: kind, file: file,
                            startLine: startLine(of: child), endLine: endLine(of: child),
                            signature: signatureText(lines: lines, line: startLine(of: child)),
                            container: container, engine: "tree-sitter"
                        ))
                    }
                } else if language == "lua" {
                    // Lua: name can be identifier, dot_index_expression (M.foo), or method_index_expression (M:foo)
                    if let (name, luaContainer) = extractLuaFunctionName(child, source: source) {
                        let kind: SymbolKind = luaContainer != nil ? .method : .function
                        entries.append(IndexEntry(
                            name: name, kind: kind, file: file,
                            startLine: startLine(of: child), endLine: endLine(of: child),
                            signature: signatureText(lines: lines, line: startLine(of: child)),
                            container: luaContainer, engine: "tree-sitter"
                        ))
                    }
                } else if let entry = extractFunction(child, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                }

            // Python + C/C++ function definitions
            case "function_definition":
                if let entry = extractFunction(child, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                } else if language == "cpp" {
                    // Out-of-class method: void Foo::bar() { }
                    if let (name, qualContainer) = extractCppQualifiedMethod(child, source: source) {
                        entries.append(IndexEntry(
                            name: name, kind: .method, file: file,
                            startLine: startLine(of: child), endLine: endLine(of: child),
                            signature: signatureText(lines: lines, line: startLine(of: child)),
                            container: qualContainer, engine: "tree-sitter"
                        ))
                    } else if let name = extractCDeclaratorName(child, source: source) {
                        // In-class or free function via declarator chain
                        let kind: SymbolKind = container != nil ? .method : .function
                        entries.append(IndexEntry(
                            name: name, kind: kind, file: file,
                            startLine: startLine(of: child), endLine: endLine(of: child),
                            signature: signatureText(lines: lines, line: startLine(of: child)),
                            container: container, engine: "tree-sitter"
                        ))
                    }
                } else if language == "c", let name = extractCDeclaratorName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .function, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: nil, engine: "tree-sitter"
                    ))
                }

            // class_declaration — Swift uses this for class/struct/enum/extension,
            // TypeScript/TSX uses it for class only, Kotlin uses it for class + interface
            case "class_declaration":
                if language == "swift" {
                    if let (entry, body) = extractSwiftClassLike(child, file: file, source: source, lines: lines, container: container) {
                        entries.append(entry)
                        if let body = body {
                            walkNode(body, language: language, file: file, source: source, lines: lines, container: entry.name, entries: &entries)
                        }
                    }
                } else if language == "kotlin" {
                    // Kotlin grammar has no field names — find type_identifier child
                    if let nameNode = findChildByType(child, type: "type_identifier"),
                       let name = nodeText(nameNode, source: source) {
                        entries.append(IndexEntry(
                            name: name, kind: .class, file: file,
                            startLine: startLine(of: child), endLine: endLine(of: child),
                            signature: signatureText(lines: lines, line: startLine(of: child)),
                            container: container, engine: "tree-sitter"
                        ))
                        if let body = findBody(child) {
                            walkNode(body, language: language, file: file, source: source, lines: lines, container: name, entries: &entries)
                        }
                    }
                } else {
                    if let (entry, body) = extractTSDeclaration(child, kind: .class, file: file, source: source, lines: lines, container: container) {
                        entries.append(entry)
                        if let body = body {
                            walkNode(body, language: language, file: file, source: source, lines: lines, container: entry.name, entries: &entries)
                        }
                    }
                }

            // Python class definitions
            case "class_definition":
                if let (entry, body) = extractPythonClass(child, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                    if let body = body {
                        walkNode(body, language: language, file: file, source: source, lines: lines, container: entry.name, entries: &entries)
                    }
                }

            // Swift protocol declarations
            case "protocol_declaration":
                if let (entry, body) = extractProtocol(child, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                    if let body = body {
                        walkNode(body, language: language, file: file, source: source, lines: lines, container: entry.name, entries: &entries)
                    }
                }

            // Swift init declarations
            case "init_declaration":
                let start = startLine(of: child)
                let end = endLine(of: child)
                let sig = signatureText(lines: lines, line: start)
                entries.append(IndexEntry(
                    name: "init",
                    kind: .method,
                    file: file,
                    startLine: start,
                    endLine: end,
                    signature: sig,
                    container: container,
                    engine: "tree-sitter"
                ))

            // Swift/C#/PHP/Kotlin property declarations
            case "property_declaration", "protocol_property_declaration":
                if language == "kotlin" {
                    // Kotlin: property_declaration → variable_declaration → simple_identifier
                    if let varDecl = findChildByType(child, type: "variable_declaration"),
                       let nameNode = findChildByType(varDecl, type: "simple_identifier"),
                       let name = nodeText(nameNode, source: source) {
                        entries.append(IndexEntry(
                            name: name, kind: .property, file: file,
                            startLine: startLine(of: child), endLine: endLine(of: child),
                            signature: signatureText(lines: lines, line: startLine(of: child)),
                            container: container, engine: "tree-sitter"
                        ))
                    }
                } else if language == "php" {
                    // PHP properties live inside property_element children with variable_name ($foo)
                    for pi in 0..<Int(child.childCount) {
                        guard let propElem = child.child(at: pi),
                              propElem.nodeType == "property_element",
                              let name = nodeName(propElem, source: source) else { continue }
                        entries.append(IndexEntry(
                            name: name, kind: .property, file: file,
                            startLine: startLine(of: child), endLine: endLine(of: child),
                            signature: signatureText(lines: lines, line: startLine(of: child)),
                            container: container, engine: "tree-sitter"
                        ))
                    }
                } else if language == "csharp", let name = nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .property, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                } else if let entry = extractProperty(child, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                }

            // TypeScript/TSX interface declarations
            case "interface_declaration":
                if let (entry, body) = extractTSDeclaration(child, kind: .interface, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                    if let body = body {
                        walkNode(body, language: language, file: file, source: source, lines: lines, container: entry.name, entries: &entries)
                    }
                }

            // TypeScript/TSX type alias declarations
            case "type_alias_declaration":
                if let name = nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name,
                        kind: .type,
                        file: file,
                        startLine: startLine(of: child),
                        endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container,
                        engine: "tree-sitter"
                    ))
                }

            // TypeScript/TSX enum declarations
            case "enum_declaration":
                if let (entry, body) = extractTSDeclaration(child, kind: .enum, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                    if let body = body {
                        walkNode(body, language: language, file: file, source: source, lines: lines, container: entry.name, entries: &entries)
                    }
                }

            // TypeScript/TSX method definitions (inside class body)
            case "method_definition":
                if let entry = extractFunction(child, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                }

            // Go method declarations (receiver-based containers) / Java method declarations (lexical containers)
            case "method_declaration":
                if language == "go" {
                    if let entry = extractGoMethod(child, file: file, source: source, lines: lines) {
                        entries.append(entry)
                    }
                } else {
                    if let entry = extractFunction(child, file: file, source: source, lines: lines, container: container) {
                        entries.append(entry)
                    }
                }

            // Go type declarations (struct, interface, type alias)
            case "type_declaration":
                extractGoTypeDeclaration(child, file: file, source: source, lines: lines, entries: &entries)

            // Rust function items (top-level or inside impl blocks)
            case "function_item", "function_signature_item":
                if let entry = extractFunction(child, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                }

            // Rust struct items
            case "struct_item":
                if let name = nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .struct, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            // Rust enum items
            case "enum_item":
                if let name = nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .enum, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            // Rust trait items (mapped to .protocol)
            case "trait_item":
                if let name = nodeName(child, source: source) {
                    let body = findBody(child)
                    entries.append(IndexEntry(
                        name: name, kind: .protocol, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                    if let body = body {
                        walkNode(body, language: language, file: file, source: source, lines: lines, container: name, entries: &entries)
                    }
                }

            // Rust type aliases
            case "type_item":
                if let name = nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .type, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            // Rust impl blocks — extract type name and walk body with it as container
            case "impl_item":
                let implContainer = extractRustImplType(child, source: source)
                if let body = findBody(child) {
                    walkNode(body, language: language, file: file, source: source, lines: lines, container: implContainer, entries: &entries)
                }

            // Java record declarations (mapped to .struct)
            case "record_declaration":
                if let (entry, body) = extractTSDeclaration(child, kind: .struct, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                    if let body = body {
                        walkNode(body, language: language, file: file, source: source, lines: lines, container: entry.name, entries: &entries)
                    }
                }

            // Java annotation type declarations (mapped to .protocol)
            case "annotation_type_declaration":
                if let (entry, body) = extractTSDeclaration(child, kind: .protocol, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                    if let body = body {
                        walkNode(body, language: language, file: file, source: source, lines: lines, container: entry.name, entries: &entries)
                    }
                }

            // Java/C# constructor declarations
            case "constructor_declaration":
                if let entry = extractFunction(child, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                }

            // C# destructor declarations (~ClassName)
            case "destructor_declaration":
                if let entry = extractFunction(child, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                }

            // C# struct declarations
            case "struct_declaration":
                if let (entry, body) = extractTSDeclaration(child, kind: .struct, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                    if let body = body {
                        walkNode(body, language: language, file: file, source: source, lines: lines, container: entry.name, entries: &entries)
                    }
                }

            // C# delegate declarations
            case "delegate_declaration":
                if language == "csharp", let name = nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .type, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            // C# namespace declarations
            case "namespace_declaration":
                if language == "csharp" {
                    if let name = nodeName(child, source: source) {
                        entries.append(IndexEntry(
                            name: name, kind: .extension, file: file,
                            startLine: startLine(of: child), endLine: endLine(of: child),
                            signature: signatureText(lines: lines, line: startLine(of: child)),
                            container: container, engine: "tree-sitter"
                        ))
                    }
                    if let body = findBody(child) {
                        walkNode(body, language: language, file: file, source: source, lines: lines, container: container, entries: &entries)
                    }
                } else if child.childCount > 0 {
                    walkNode(child, language: language, file: file, source: source, lines: lines, container: container, entries: &entries)
                }

            // C# file-scoped namespace declarations (namespace Foo;)
            case "file_scoped_namespace_declaration":
                if language == "csharp", let name = nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .extension, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }
                // Walk child declarations (classes, etc. inside the file-scoped namespace)
                if child.childCount > 0 {
                    walkNode(child, language: language, file: file, source: source, lines: lines, container: container, entries: &entries)
                }

            // Ruby class (bare 'class' node — distinct from class_declaration)
            case "class":
                if language == "ruby", let name = nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .class, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                    if let body = findBody(child) {
                        walkNode(body, language: language, file: file, source: source, lines: lines, container: name, entries: &entries)
                    }
                }

            // Ruby module (namespacing/mixins — acts as container like class)
            case "module":
                if language == "ruby", let name = nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .extension, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                    if let body = findBody(child) {
                        walkNode(body, language: language, file: file, source: source, lines: lines, container: name, entries: &entries)
                    }
                }

            // Ruby instance methods (def foo)
            case "method":
                if language == "ruby", let name = nodeName(child, source: source) {
                    let kind: SymbolKind = container != nil ? .method : .function
                    entries.append(IndexEntry(
                        name: name, kind: kind, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            // Ruby singleton methods (def self.foo — class methods)
            case "singleton_method":
                if language == "ruby", let name = nodeName(child, source: source) {
                    let kind: SymbolKind = container != nil ? .method : .function
                    entries.append(IndexEntry(
                        name: name, kind: kind, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            // PHP trait declarations (act like classes for container purposes)
            case "trait_declaration":
                if let (entry, body) = extractTSDeclaration(child, kind: .class, file: file, source: source, lines: lines, container: container) {
                    entries.append(entry)
                    if let body = body {
                        walkNode(body, language: language, file: file, source: source, lines: lines, container: entry.name, entries: &entries)
                    }
                }

            // Kotlin object declarations (singletons — act as containers like classes)
            case "object_declaration":
                if language == "kotlin",
                   let nameNode = findChildByType(child, type: "type_identifier"),
                   let name = nodeText(nameNode, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .class, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                    if let body = findBody(child) {
                        walkNode(body, language: language, file: file, source: source, lines: lines, container: name, entries: &entries)
                    }
                }

            // Scala object definitions (singletons — act as containers)
            case "object_definition":
                if language == "scala", let name = nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .class, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                    if let body = findBody(child) {
                        walkNode(body, language: language, file: file, source: source, lines: lines, container: name, entries: &entries)
                    }
                }

            // Scala trait definitions (mapped to .protocol — interfaces with optional implementations)
            case "trait_definition":
                if language == "scala", let name = nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .protocol, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                    if let body = findBody(child) {
                        walkNode(body, language: language, file: file, source: source, lines: lines, container: name, entries: &entries)
                    }
                }

            // Scala val/var definitions (properties — use "pattern" field instead of "name")
            case "val_definition", "var_definition":
                if language == "scala",
                   let patternNode = child.child(byFieldName: "pattern"),
                   let name = nodeText(patternNode, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .property, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            // Kotlin companion objects (static-like container inside a class)
            case "companion_object":
                if language == "kotlin" {
                    // Name is optional — bare `companion object { }` defaults to "Companion"
                    let name: String
                    if let nameNode = findChildByType(child, type: "type_identifier"),
                       let explicitName = nodeText(nameNode, source: source) {
                        name = explicitName
                    } else {
                        name = "Companion"
                    }
                    entries.append(IndexEntry(
                        name: name, kind: .class, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                    if let body = findBody(child) {
                        walkNode(body, language: language, file: file, source: source, lines: lines, container: name, entries: &entries)
                    }
                }

            // Kotlin type aliases
            case "type_alias":
                if language == "kotlin",
                   let nameNode = findChildByType(child, type: "type_identifier"),
                   let name = nodeText(nameNode, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .type, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            // C++ class specifiers
            case "class_specifier":
                if language == "cpp", let name = nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .class, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                    if let body = findBody(child) {
                        walkNode(body, language: language, file: file, source: source, lines: lines, container: name, entries: &entries)
                    }
                }

            // C/C++ struct/union specifiers
            case "struct_specifier", "union_specifier":
                if let name = nodeName(child, source: source) {
                    if language == "cpp" {
                        entries.append(IndexEntry(
                            name: name, kind: .struct, file: file,
                            startLine: startLine(of: child), endLine: endLine(of: child),
                            signature: signatureText(lines: lines, line: startLine(of: child)),
                            container: container, engine: "tree-sitter"
                        ))
                        if let body = findBody(child) {
                            walkNode(body, language: language, file: file, source: source, lines: lines, container: name, entries: &entries)
                        }
                    } else if language == "c" {
                        entries.append(IndexEntry(
                            name: name, kind: .struct, file: file,
                            startLine: startLine(of: child), endLine: endLine(of: child),
                            signature: signatureText(lines: lines, line: startLine(of: child)),
                            container: nil, engine: "tree-sitter"
                        ))
                    }
                }

            // C/C++ enum specifiers
            case "enum_specifier":
                if (language == "c" || language == "cpp"), let name = nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .enum, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: nil, engine: "tree-sitter"
                    ))
                }

            // C/C++/Scala type definitions
            case "type_definition":
                if (language == "c" || language == "cpp"), let name = extractCDeclaratorName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .type, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: nil, engine: "tree-sitter"
                    ))
                } else if language == "scala", let name = nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .type, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            // C/C++ declarations (function prototypes, constructor declarations)
            case "declaration":
                if (language == "c" || language == "cpp") && cHasFunctionDeclarator(child) {
                    if let name = extractCDeclaratorName(child, source: source) {
                        let kind: SymbolKind = container != nil ? .method : .function
                        entries.append(IndexEntry(
                            name: name, kind: kind, file: file,
                            startLine: startLine(of: child), endLine: endLine(of: child),
                            signature: signatureText(lines: lines, line: startLine(of: child)),
                            container: container, engine: "tree-sitter"
                        ))
                    }
                } else if child.childCount > 0 {
                    walkNode(child, language: language, file: file, source: source, lines: lines, container: container, entries: &entries)
                }

            // C++ in-class method declarations (field_declaration with function_declarator)
            case "field_declaration":
                if language == "cpp" && cHasFunctionDeclarator(child) {
                    if let name = extractCDeclaratorName(child, source: source) {
                        let kind: SymbolKind = container != nil ? .method : .function
                        entries.append(IndexEntry(
                            name: name, kind: kind, file: file,
                            startLine: startLine(of: child), endLine: endLine(of: child),
                            signature: signatureText(lines: lines, line: startLine(of: child)),
                            container: container, engine: "tree-sitter"
                        ))
                    }
                }

            // C++/PHP namespace definitions
            case "namespace_definition":
                if language == "cpp" || language == "php" {
                    if let name = nodeName(child, source: source) {
                        entries.append(IndexEntry(
                            name: name, kind: .extension, file: file,
                            startLine: startLine(of: child), endLine: endLine(of: child),
                            signature: signatureText(lines: lines, line: startLine(of: child)),
                            container: container, engine: "tree-sitter"
                        ))
                    }
                    // Recurse into body without setting container (namespaces don't set container)
                    if let body = findBody(child) {
                        walkNode(body, language: language, file: file, source: source, lines: lines, container: container, entries: &entries)
                    }
                } else if child.childCount > 0 {
                    walkNode(child, language: language, file: file, source: source, lines: lines, container: container, entries: &entries)
                }

            // C++ using aliases (using Foo = Bar;)
            case "alias_declaration":
                if language == "cpp", let name = nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .type, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            // Haskell declarations scope (top-level, class body, instance body — handles deduplication)
            case "declarations", "class_declarations", "instance_declarations":
                if language == "haskell" {
                    walkHaskellDeclarations(child, file: file, source: source, lines: lines, container: container, entries: &entries)
                } else if child.childCount > 0 {
                    walkNode(child, language: language, file: file, source: source, lines: lines, container: container, entries: &entries)
                }

            // Zig variable declarations (const Foo = struct { ... }; — type bindings)
            case "variable_declaration":
                if language == "zig" {
                    walkZigVariableDeclaration(child, file: file, source: source, lines: lines, container: container, entries: &entries)
                }

            // Zig container fields (struct field declarations — only emit typed fields, skip enum variants)
            case "container_field":
                if language == "zig" {
                    // Only emit fields that have a type annotation (name: type) — this filters out
                    // enum variants which are just identifiers without types
                    if findChildByType(child, type: ":") != nil,
                       let nameNode = findChildByType(child, type: "identifier"),
                       let name = nodeText(nameNode, source: source) {
                        entries.append(IndexEntry(
                            name: name, kind: .property, file: file,
                            startLine: startLine(of: child), endLine: endLine(of: child),
                            signature: signatureText(lines: lines, line: startLine(of: child)),
                            container: container, engine: "tree-sitter"
                        ))
                    }
                }

            // Zig test declarations (test "name" { ... })
            case "test_declaration":
                if language == "zig" {
                    let testName = extractZigTestName(child, source: source) ?? "test"
                    entries.append(IndexEntry(
                        name: testName, kind: .function, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: nil, engine: "tree-sitter"
                    ))
                }

            // Elixir declarations (defmodule, def, defp, defmacro, defmacrop — all parse as call nodes)
            case "call":
                if language == "elixir" {
                    // Get the call target identifier (defmodule, def, etc.)
                    guard let targetNode = findChildByType(child, type: "identifier"),
                          let target = nodeText(targetNode, source: source) else { break }
                    switch target {
                    case "defmodule":
                        if let name = extractElixirModuleName(child, source: source) {
                            entries.append(IndexEntry(
                                name: name, kind: .class, file: file,
                                startLine: startLine(of: child), endLine: endLine(of: child),
                                signature: signatureText(lines: lines, line: startLine(of: child)),
                                container: container, engine: "tree-sitter"
                            ))
                            if let doBlock = findChildByType(child, type: "do_block") {
                                walkNode(doBlock, language: language, file: file, source: source, lines: lines, container: name, entries: &entries)
                            }
                        }
                    case "def", "defp", "defmacro", "defmacrop":
                        if let name = extractElixirFunctionName(child, source: source) {
                            let kind: SymbolKind = container != nil ? .method : .function
                            entries.append(IndexEntry(
                                name: name, kind: kind, file: file,
                                startLine: startLine(of: child), endLine: endLine(of: child),
                                signature: signatureText(lines: lines, line: startLine(of: child)),
                                container: container, engine: "tree-sitter"
                            ))
                        }
                    default:
                        break
                    }
                } else if child.childCount > 0 {
                    walkNode(child, language: language, file: file, source: source, lines: lines, container: container, entries: &entries)
                }

            default:
                // Recurse into non-declaration nodes (decorated_definition, export_statement, block, etc.)
                if child.childCount > 0 {
                    walkNode(child, language: language, file: file, source: source, lines: lines, container: container, entries: &entries)
                }
            }
        }
    }

    // MARK: - Shared Extractors

    private static func extractFunction(
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
    private static func extractSwiftClassLike(
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

    private static func extractProtocol(
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

    private static func extractProperty(
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
    private static func extractPythonClass(
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
    private static func extractTSDeclaration(
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
    private static func extractGoMethod(
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
    private static func extractGoReceiverType(_ node: Node, source: NSString) -> String? {
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
    private static func extractGoTypeDeclaration(
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
    private static func extractGoTypeSpec(
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
    private static func extractRustImplType(_ node: Node, source: NSString) -> String? {
        // The "type" field is the type being implemented (e.g., User in `impl Display for User`)
        guard let typeNode = node.child(byFieldName: "type") else { return nil }
        return extractRustTypeName(typeNode, source: source)
    }

    /// Extract the base type name from a Rust type node.
    /// Handles type_identifier, generic_type (strips <T>), and scoped_type_identifier.
    private static func extractRustTypeName(_ node: Node, source: NSString) -> String? {
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
    private static func extractLuaFunctionName(_ node: Node, source: NSString) -> (name: String, container: String?)? {
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

    // MARK: - Elixir Extractors

    /// Extract the module name from a defmodule call node.
    /// `defmodule MyApp.Greeter do` → arguments contain an `alias` node with the full dotted name.
    private static func extractElixirModuleName(_ callNode: Node, source: NSString) -> String? {
        guard let args = findChildByType(callNode, type: "arguments") else { return nil }
        // First child of arguments should be an alias (module name)
        for i in 0..<Int(args.childCount) {
            guard let arg = args.child(at: i) else { continue }
            let t = arg.nodeType ?? ""
            if t == "alias" { return nodeText(arg, source: source) }
        }
        return nil
    }

    /// Extract the function name from a def/defp/defmacro/defmacrop call node.
    /// Two forms:
    /// 1. `def hello do` → arguments contain an `identifier` "hello"
    /// 2. `def greet(name) do` → arguments contain a `call` whose target is `identifier` "greet"
    private static func extractElixirFunctionName(_ callNode: Node, source: NSString) -> String? {
        guard let args = findChildByType(callNode, type: "arguments") else { return nil }
        guard let firstArg = args.child(at: 0) else { return nil }
        let argType = firstArg.nodeType ?? ""
        switch argType {
        case "identifier":
            // No-arg function: def hello
            return nodeText(firstArg, source: source)
        case "call":
            // Function with args: def greet(name) — target identifier is the function name
            if let target = findChildByType(firstArg, type: "identifier") {
                return nodeText(target, source: source)
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: - Haskell Declarations Walker

    /// Walks a Haskell declarations scope (top-level, class body, instance body) with
    /// deduplication for multi-equation functions and signature+definition pairs.
    /// Signatures are only emitted if no corresponding function/bind definition exists.
    private static func walkHaskellDeclarations(
        _ node: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        var emittedNames = Set<String>()
        var pendingSignatures: [(name: String, node: Node)] = []

        for i in 0..<Int(node.childCount) {
            guard let child = node.child(at: i) else { continue }
            let type = child.nodeType ?? ""

            switch type {
            case "signature":
                if let name = nodeName(child, source: source), !emittedNames.contains(name) {
                    pendingSignatures.append((name, child))
                }

            case "function", "bind":
                if let name = nodeName(child, source: source), !emittedNames.contains(name) {
                    emittedNames.insert(name)
                    pendingSignatures.removeAll { $0.name == name }
                    let kind: SymbolKind = container != nil ? .method : .function
                    entries.append(IndexEntry(
                        name: name, kind: kind, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            case "data_type", "newtype", "type_synomym":
                if let name = nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .type, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                }

            case "class":
                if let name = nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .protocol, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                    if let body = findChildByType(child, type: "class_declarations") {
                        walkHaskellDeclarations(body, file: file, source: source, lines: lines, container: name, entries: &entries)
                    }
                }

            case "instance":
                if let name = nodeName(child, source: source) {
                    entries.append(IndexEntry(
                        name: name, kind: .extension, file: file,
                        startLine: startLine(of: child), endLine: endLine(of: child),
                        signature: signatureText(lines: lines, line: startLine(of: child)),
                        container: container, engine: "tree-sitter"
                    ))
                    if let body = findChildByType(child, type: "instance_declarations") {
                        walkHaskellDeclarations(body, file: file, source: source, lines: lines, container: name, entries: &entries)
                    }
                }

            default:
                break
            }
        }

        // Emit remaining signature-only entries (abstract methods in type classes)
        for sig in pendingSignatures where !emittedNames.contains(sig.name) {
            emittedNames.insert(sig.name)
            let kind: SymbolKind = container != nil ? .method : .function
            entries.append(IndexEntry(
                name: sig.name, kind: kind, file: file,
                startLine: startLine(of: sig.node), endLine: endLine(of: sig.node),
                signature: signatureText(lines: lines, line: startLine(of: sig.node)),
                container: container, engine: "tree-sitter"
            ))
        }
    }

    // MARK: - Zig Helpers

    /// Walk a Zig variable_declaration: detect type bindings (const Foo = struct/enum/union { ... })
    /// and emit type entries. Skip plain constants (imports, integers, etc.).
    private static func walkZigVariableDeclaration(
        _ node: Node, file: String, source: NSString, lines: [String],
        container: String?, entries: inout [IndexEntry]
    ) {
        // Extract const name from identifier child
        guard let nameNode = findChildByType(node, type: "identifier"),
              let name = nodeText(nameNode, source: source) else { return }

        // Check if RHS is a type declaration (struct/enum/union)
        var typeKind: SymbolKind? = nil
        var bodyNode: Node? = nil
        for i in 0..<Int(node.childCount) {
            guard let child = node.child(at: i) else { continue }
            let t = child.nodeType ?? ""
            switch t {
            case "struct_declaration":
                typeKind = .struct
                bodyNode = child
            case "enum_declaration":
                typeKind = .enum
                bodyNode = child
            case "union_declaration":
                typeKind = .struct  // unions mapped to .struct (same as C)
                bodyNode = child
            default:
                break
            }
        }

        guard let kind = typeKind else { return }  // Skip plain constants

        entries.append(IndexEntry(
            name: name, kind: kind, file: file,
            startLine: startLine(of: node), endLine: endLine(of: node),
            signature: signatureText(lines: lines, line: startLine(of: node)),
            container: container, engine: "tree-sitter"
        ))

        // Only recurse into struct bodies (fields + methods + nested types).
        // Enum and union bodies don't produce child entries in v1.
        if let body = bodyNode, body.nodeType == "struct_declaration" {
            walkNode(body, language: "zig", file: file, source: source, lines: lines, container: name, entries: &entries)
        }
    }

    /// Extract the test name from a Zig test_declaration's string child.
    private static func extractZigTestName(_ node: Node, source: NSString) -> String? {
        guard let stringNode = findChildByType(node, type: "string") else { return nil }
        // The string node contains: `"`, string_content, `"` — extract string_content
        for i in 0..<Int(stringNode.childCount) {
            guard let child = stringNode.child(at: i) else { continue }
            if child.nodeType == "string_content" {
                return nodeText(child, source: source)
            }
        }
        return nil
    }

    // MARK: - C++ Extractors

    /// Extract method name and container from a C++ out-of-class method definition.
    /// Handles: `void Foo::bar() { }` and `int *Foo::baz() { }`.
    private static func extractCppQualifiedMethod(_ node: Node, source: NSString) -> (name: String, container: String)? {
        guard let qualId = findQualifiedIdentifier(node) else { return nil }
        guard let nameNode = qualId.child(byFieldName: "name") else { return nil }
        guard let name = nodeText(nameNode, source: source) else { return nil }
        guard let scopeNode = qualId.child(byFieldName: "scope") else { return nil }
        guard let scope = nodeText(scopeNode, source: source) else { return nil }
        return (name, scope)
    }

    /// Find a qualified_identifier node in the declarator chain.
    private static func findQualifiedIdentifier(_ node: Node) -> Node? {
        guard let declarator = node.child(byFieldName: "declarator") else { return nil }
        if (declarator.nodeType ?? "") == "qualified_identifier" { return declarator }
        return findQualifiedIdentifier(declarator)
    }

    // MARK: - C Extractors

    /// Extract the symbol name from a C declarator chain.
    /// Traverses: function_declarator, pointer_declarator, parenthesized_declarator → identifier.
    private static func extractCDeclaratorName(_ node: Node, source: NSString) -> String? {
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
    private static func cHasFunctionDeclarator(_ node: Node) -> Bool {
        guard let declarator = node.child(byFieldName: "declarator") else { return false }
        let type = declarator.nodeType ?? ""
        if type == "function_declarator" { return true }
        return cHasFunctionDeclarator(declarator)
    }

    // MARK: - Node Helpers

    /// Extract text from a node using its NSRange and the source NSString.
    private static func nodeText(_ node: Node, source: NSString) -> String? {
        let range = node.range
        guard range.location != NSNotFound, NSMaxRange(range) <= source.length else { return nil }
        return source.substring(with: range)
    }

    /// Get the name from a node's "name" field.
    private static func nodeName(_ node: Node, source: NSString) -> String? {
        guard let nameNode = node.child(byFieldName: "name") else { return nil }
        return nodeText(nameNode, source: source)
    }

    /// For Swift extension declarations, extract the extended type name.
    private static func extensionTypeName(_ node: Node, source: NSString) -> String? {
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
    private static func findChildByType(_ node: Node, type: String) -> Node? {
        for i in 0..<Int(node.childCount) {
            guard let child = node.child(at: i) else { continue }
            if child.nodeType == type { return child }
        }
        return nil
    }

    /// Find the body node inside a declaration.
    private static func findBody(_ node: Node) -> Node? {
        if let body = node.child(byFieldName: "body") { return body }
        for i in 0..<Int(node.childCount) {
            guard let child = node.child(at: i) else { continue }
            let t = child.nodeType ?? ""
            if t.hasSuffix("_body") { return child }
        }
        return nil
    }

    /// Find the first simple_identifier descendant (for Swift property patterns).
    private static func findFirstIdentifier(in node: Node, source: NSString) -> String? {
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
    private static func startLine(of node: Node) -> Int {
        Int(node.pointRange.lowerBound.row) + 1
    }

    /// 1-based end line from a node's point range.
    private static func endLine(of node: Node) -> Int {
        Int(node.pointRange.upperBound.row) + 1
    }

    /// Extract the signature text from the source lines.
    private static func signatureText(lines: [String], line: Int) -> String {
        guard line > 0, line <= lines.count else { return "" }
        return lines[line - 1].trimmingCharacters(in: .whitespaces)
    }
}
