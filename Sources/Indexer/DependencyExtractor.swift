import Foundation
import SwiftTreeSitter

/// Extracts import/dependency edges from source files using tree-sitter.
/// Lives alongside TreeSitterBackend and shares its language definitions.
public enum DependencyExtractor {

    /// Extract imports from a single file. Returns the list of module identifiers
    /// imported by the file (raw, as written in source — no path resolution).
    public static func extractImports(source: String, language: String) -> [String] {
        guard let tsLanguage = TreeSitterBackend.language(for: language) else { return [] }
        let parser = Parser()
        do { try parser.setLanguage(tsLanguage) } catch { return [] }
        guard let tree = parser.parse(source) else { return [] }
        guard let root = tree.rootNode else { return [] }

        let ns = source as NSString

        switch language {
        case "swift":      return extractSwift(root: root, source: ns)
        case "python":     return extractPython(root: root, source: ns)
        case "typescript", "tsx", "javascript":
                           return extractJSFamily(root: root, source: ns)
        case "go":         return extractGo(root: root, source: ns)
        case "rust":       return extractRust(root: root, source: ns)
        case "java":       return extractJava(root: root, source: ns)
        case "c", "cpp":   return extractCFamily(root: root, source: ns)
        case "csharp":     return extractCSharp(root: root, source: ns)
        case "ruby":       return extractRuby(root: root, source: ns)
        case "php":        return extractPhp(root: root, source: ns)
        case "kotlin":     return extractKotlin(root: root, source: ns)
        case "scala":      return extractScala(root: root, source: ns)
        case "elixir":     return extractElixir(root: root, source: ns)
        case "haskell":    return extractHaskell(root: root, source: ns)
        case "zig":        return extractZig(root: root, source: ns)
        case "bash", "lua":
                           return [] // sourcing/require patterns too varied
        default:           return []
        }
    }

    /// Batch extract imports for all files of a given language.
    /// Uses a single parser instance for efficiency (avoids per-file parser creation).
    public static func extractAllImports(
        files: [String], language: String, projectRoot: String
    ) -> [String: [String]] {
        guard let tsLanguage = TreeSitterBackend.language(for: language) else { return [:] }
        let parser = Parser()
        do { try parser.setLanguage(tsLanguage) } catch { return [:] }

        var result: [String: [String]] = [:]
        for relativePath in files {
            let fullPath = projectRoot + "/" + relativePath
            guard let source = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }
            guard let tree = parser.parse(source) else { continue }
            guard let root = tree.rootNode else { continue }

            let ns = source as NSString
            let modules = extractForLanguage(root: root, source: ns, language: language)
            if !modules.isEmpty {
                result[relativePath] = modules
            }
        }
        return result
    }

    /// Core extraction dispatch — used by both single-file and batch methods.
    private static func extractForLanguage(root: Node, source: NSString, language: String) -> [String] {
        switch language {
        case "swift":      return extractSwift(root: root, source: source)
        case "python":     return extractPython(root: root, source: source)
        case "typescript", "tsx", "javascript":
                           return extractJSFamily(root: root, source: source)
        case "go":         return extractGo(root: root, source: source)
        case "rust":       return extractRust(root: root, source: source)
        case "java":       return extractJava(root: root, source: source)
        case "c", "cpp":   return extractCFamily(root: root, source: source)
        case "csharp":     return extractCSharp(root: root, source: source)
        case "ruby":       return extractRuby(root: root, source: source)
        case "php":        return extractPhp(root: root, source: source)
        case "kotlin":     return extractKotlin(root: root, source: source)
        case "scala":      return extractScala(root: root, source: source)
        case "elixir":     return extractElixir(root: root, source: source)
        case "haskell":    return extractHaskell(root: root, source: source)
        case "zig":        return extractZig(root: root, source: source)
        case "bash", "lua":
                           return []
        default:           return []
        }
    }

    // MARK: - Per-language extractors

    // Swift: import Foundation, @testable import Filter, import struct Foo.Bar
    private static func extractSwift(root: Node, source: NSString) -> [String] {
        var results: [String] = []
        walk(root) { node in
            if node.nodeType == "import_declaration" {
                if let name = lastDescendantOfType(node, type: "identifier", source: source) {
                    results.append(name)
                }
            }
        }
        return dedupe(results)
    }

    // Python: import os, from pathlib import Path
    private static func extractPython(root: Node, source: NSString) -> [String] {
        var results: [String] = []
        walk(root) { node in
            if node.nodeType == "import_statement" {
                for child in children(of: node) where child.nodeType == "dotted_name" {
                    if let t = nodeText(child, source: source) { results.append(t) }
                }
            } else if node.nodeType == "import_from_statement" {
                if let moduleField = node.child(byFieldName: "module_name"),
                   let t = nodeText(moduleField, source: source) {
                    results.append(t)
                }
            }
        }
        return dedupe(results)
    }

    // JS/TS/TSX: import ... from 'path', require('path')
    private static func extractJSFamily(root: Node, source: NSString) -> [String] {
        var results: [String] = []
        walk(root) { node in
            if node.nodeType == "import_statement" {
                if let sourceField = node.child(byFieldName: "source"),
                   let t = nodeText(sourceField, source: source) {
                    results.append(stripQuotes(t))
                }
            } else if node.nodeType == "call_expression" {
                if let function = node.child(byFieldName: "function"),
                   nodeText(function, source: source) == "require",
                   let args = node.child(byFieldName: "arguments") {
                    let argChildren = children(of: args)
                    if let firstArg = argChildren.first, firstArg.nodeType == "string",
                       let t = nodeText(firstArg, source: source) {
                        results.append(stripQuotes(t))
                    }
                }
            }
        }
        return dedupe(results)
    }

    // Go: import "fmt" or import ( "fmt" "os" )
    private static func extractGo(root: Node, source: NSString) -> [String] {
        var results: [String] = []
        walk(root) { node in
            if node.nodeType == "import_spec" {
                if let path = node.child(byFieldName: "path"),
                   let t = nodeText(path, source: source) {
                    results.append(stripQuotes(t))
                }
            }
        }
        return dedupe(results)
    }

    // Rust: use std::io::Read, extern crate baz
    private static func extractRust(root: Node, source: NSString) -> [String] {
        var results: [String] = []
        walk(root) { node in
            if node.nodeType == "use_declaration" {
                if let arg = node.child(byFieldName: "argument"),
                   let full = nodeText(arg, source: source) {
                    // Take only the first segment (e.g., "std" from "std::io::Read")
                    let firstSegment = full.split(separator: ":").first.map(String.init) ?? full
                    results.append(firstSegment)
                }
            } else if node.nodeType == "extern_crate_declaration" {
                if let name = findChildByType(node, type: "identifier"),
                   let t = nodeText(name, source: source) {
                    results.append(t)
                }
            }
        }
        return dedupe(results)
    }

    // Java: import java.util.List;
    private static func extractJava(root: Node, source: NSString) -> [String] {
        var results: [String] = []
        walk(root) { node in
            if node.nodeType == "import_declaration" {
                if let raw = nodeText(node, source: source) {
                    let trimmed = raw
                        .replacingOccurrences(of: "import ", with: "")
                        .replacingOccurrences(of: "static ", with: "")
                        .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
                        .trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        results.append(trimmed)
                    }
                }
            }
        }
        return dedupe(results)
    }

    // C/C++: #include <stdio.h>, #include "myheader.h"
    private static func extractCFamily(root: Node, source: NSString) -> [String] {
        var results: [String] = []
        walk(root) { node in
            if node.nodeType == "preproc_include" {
                if let path = node.child(byFieldName: "path"),
                   let raw = nodeText(path, source: source) {
                    let stripped = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<>\""))
                    results.append(stripped)
                }
            }
        }
        return dedupe(results)
    }

    // C#: using System; using Foo = Bar.Baz;
    private static func extractCSharp(root: Node, source: NSString) -> [String] {
        var results: [String] = []
        walk(root) { node in
            if node.nodeType == "using_directive" {
                if let raw = nodeText(node, source: source) {
                    let trimmed = raw
                        .replacingOccurrences(of: "using ", with: "")
                        .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
                        .trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        results.append(trimmed)
                    }
                }
            }
        }
        return dedupe(results)
    }

    // Ruby: require 'foo', require_relative 'bar'
    private static func extractRuby(root: Node, source: NSString) -> [String] {
        var results: [String] = []
        walk(root) { node in
            if node.nodeType == "call" {
                if let method = node.child(byFieldName: "method"),
                   let methodName = nodeText(method, source: source),
                   methodName == "require" || methodName == "require_relative" || methodName == "load" {
                    if let args = node.child(byFieldName: "arguments") {
                        let argChildren = children(of: args)
                        if let firstArg = argChildren.first, firstArg.nodeType == "string",
                           let t = nodeText(firstArg, source: source) {
                            results.append(stripQuotes(t))
                        }
                    }
                }
            }
        }
        return dedupe(results)
    }

    // PHP: use Foo\Bar;
    private static func extractPhp(root: Node, source: NSString) -> [String] {
        var results: [String] = []
        walk(root) { node in
            if node.nodeType == "namespace_use_declaration" || node.nodeType == "namespace_use_clause" {
                if let name = findChildByType(node, type: "qualified_name") ?? findChildByType(node, type: "name"),
                   let t = nodeText(name, source: source) {
                    results.append(t)
                }
            }
        }
        return dedupe(results)
    }

    // Kotlin: import kotlinx.coroutines.flow.Flow
    private static func extractKotlin(root: Node, source: NSString) -> [String] {
        var results: [String] = []
        walk(root) { node in
            if node.nodeType == "import_header" {
                if let raw = nodeText(node, source: source) {
                    let trimmed = raw
                        .replacingOccurrences(of: "import ", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        results.append(trimmed)
                    }
                }
            }
        }
        return dedupe(results)
    }

    // Scala: import scala.collection.mutable.{Map, Set}
    private static func extractScala(root: Node, source: NSString) -> [String] {
        var results: [String] = []
        walk(root) { node in
            if node.nodeType == "import_declaration" {
                if let raw = nodeText(node, source: source) {
                    let trimmed = raw
                        .replacingOccurrences(of: "import ", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        // Take just the package path before any { } selector
                        let path = trimmed.split(separator: "{").first
                            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? trimmed
                        results.append(path)
                    }
                }
            }
        }
        return dedupe(results)
    }

    // Elixir: alias Foo.Bar, import Foo.Bar, use Foo.Bar, require Foo.Bar
    // AST: call → identifier "alias"/"import"/"use"/"require" + arguments → alias "Foo.Bar"
    private static func extractElixir(root: Node, source: NSString) -> [String] {
        var results: [String] = []
        let importDirectives: Set<String> = ["alias", "import", "use", "require"]
        walk(root) { node in
            if node.nodeType == "call" {
                if let idNode = findChildByType(node, type: "identifier"),
                   let idText = nodeText(idNode, source: source),
                   importDirectives.contains(idText) {
                    if let args = findChildByType(node, type: "arguments") {
                        if let aliasNode = findChildByType(args, type: "alias"),
                           let t = nodeText(aliasNode, source: source) {
                            results.append(t)
                        }
                    }
                }
            }
        }
        return dedupe(results)
    }

    // Haskell: import Data.List, import qualified Data.Map as M
    private static func extractHaskell(root: Node, source: NSString) -> [String] {
        var results: [String] = []
        walk(root) { node in
            if node.nodeType == "import" {
                if let moduleNode = findChildByType(node, type: "module"),
                   let t = nodeText(moduleNode, source: source) {
                    results.append(t)
                }
            }
        }
        return dedupe(results)
    }

    // Zig: const std = @import("std");
    // AST: builtin_function → builtin_identifier "@import" + arguments → string → string_content
    private static func extractZig(root: Node, source: NSString) -> [String] {
        var results: [String] = []
        walk(root) { node in
            if node.nodeType == "builtin_function" {
                if let idNode = findChildByType(node, type: "builtin_identifier"),
                   let idText = nodeText(idNode, source: source), idText == "@import" {
                    if let stringNode = findFirstDescendantOfType(node, type: "string_content"),
                       let content = nodeText(stringNode, source: source) {
                        results.append(content)
                    }
                }
            }
        }
        return dedupe(results)
    }

    // MARK: - Walker helpers

    private static func walk(_ node: Node, visit: (Node) -> Void) {
        visit(node)
        for i in 0..<Int(node.childCount) {
            if let child = node.child(at: i) {
                walk(child, visit: visit)
            }
        }
    }

    private static func children(of node: Node) -> [Node] {
        (0..<Int(node.childCount)).compactMap { node.child(at: $0) }
    }

    private static func nodeText(_ node: Node, source: NSString) -> String? {
        let range = node.range
        guard range.location != NSNotFound, NSMaxRange(range) <= source.length else { return nil }
        return source.substring(with: range)
    }

    private static func stripQuotes(_ s: String) -> String {
        var result = s
        if result.hasPrefix("\"") || result.hasPrefix("'") || result.hasPrefix("<") {
            result.removeFirst()
        }
        if result.hasSuffix("\"") || result.hasSuffix("'") || result.hasSuffix(">") {
            result.removeLast()
        }
        return result
    }

    private static func dedupe(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for item in items where !item.isEmpty && !seen.contains(item) {
            seen.insert(item)
            result.append(item)
        }
        return result
    }

    private static func findChildByType(_ node: Node, type: String) -> Node? {
        for i in 0..<Int(node.childCount) {
            if let child = node.child(at: i), child.nodeType == type {
                return child
            }
        }
        return nil
    }

    private static func findFirstDescendantOfType(_ node: Node, type: String) -> Node? {
        if node.nodeType == type { return node }
        for i in 0..<Int(node.childCount) {
            if let child = node.child(at: i),
               let found = findFirstDescendantOfType(child, type: type) {
                return found
            }
        }
        return nil
    }

    private static func lastDescendantOfType(_ node: Node, type: String, source: NSString) -> String? {
        var last: String? = nil
        walk(node) { n in
            if n.nodeType == type, let t = nodeText(n, source: source) {
                last = t
            }
        }
        return last
    }
}
