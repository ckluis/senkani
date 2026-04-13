import Foundation
import Testing
import SwiftTreeSitter
@testable import Indexer

@Suite("TreeSitterBackend — HTML/CSS")
struct HtmlCssTests {

    @Test("HTML grammar loads")
    func htmlGrammarLoads() {
        #expect(TreeSitterBackend.supports("html"))
        #expect(TreeSitterBackend.language(for: "html") != nil)
    }

    @Test("CSS grammar loads")
    func cssGrammarLoads() {
        #expect(TreeSitterBackend.supports("css"))
        #expect(TreeSitterBackend.language(for: "css") != nil)
    }

    @Test("HTML parses a document")
    func htmlParses() {
        let language = TreeSitterBackend.language(for: "html")!
        let parser = Parser()
        try! parser.setLanguage(language)
        let tree = parser.parse("<html><body><h1>Hello</h1></body></html>")
        #expect(tree != nil)
        #expect(tree?.rootNode != nil)
    }

    @Test("CSS parses a stylesheet")
    func cssParses() {
        let language = TreeSitterBackend.language(for: "css")!
        let parser = Parser()
        try! parser.setLanguage(language)
        let tree = parser.parse("body { color: red; font-size: 16px; }")
        #expect(tree != nil)
        #expect(tree?.rootNode != nil)
    }

    @Test("HTML FileWalker mapping")
    func htmlFileWalkerMapping() {
        #expect(FileWalker.languageMap["html"] == "html")
        #expect(FileWalker.languageMap["htm"] == "html")
    }

    @Test("CSS FileWalker mapping")
    func cssFileWalkerMapping() {
        #expect(FileWalker.languageMap["css"] == "css")
    }

    @Test("HTML GrammarManifest entry")
    func htmlGrammarManifestEntry() {
        let info = GrammarManifest.grammar(for: "html")
        #expect(info != nil)
        #expect(info?.repo == "tree-sitter/tree-sitter-html")
    }

    @Test("CSS GrammarManifest entry")
    func cssGrammarManifestEntry() {
        let info = GrammarManifest.grammar(for: "css")
        #expect(info != nil)
        #expect(info?.repo == "tree-sitter/tree-sitter-css")
    }
}
