import Foundation
import Testing
@testable import Indexer

@Suite("TreeSitterBackend — Dart / TOML / GraphQL")
struct DartTomlGraphQLTests {

    // MARK: - Wiring

    @Test("Grammars load + wire through supported set + FileWalker + manifest")
    func grammarsWired() {
        for lang in ["dart", "toml", "graphql"] {
            #expect(TreeSitterBackend.supports(lang))
            #expect(TreeSitterBackend.language(for: lang) != nil)
            #expect(GrammarManifest.grammar(for: lang) != nil)
        }
        // FileWalker extension mappings
        #expect(FileWalker.languageMap["dart"] == "dart")
        #expect(FileWalker.languageMap["toml"] == "toml")
        #expect(FileWalker.languageMap["graphql"] == "graphql")
        #expect(FileWalker.languageMap["gql"] == "graphql")
    }

    // MARK: - Dart

    @Test("Dart — top-level function")
    func dartTopLevelFunction() {
        let source = """
        void hello() {
          print('hi');
        }
        """
        let entries = indexLang(source, language: "dart", ext: "dart")
        let funcs = entries.filter { $0.kind == .function && $0.name == "hello" }
        #expect(funcs.count == 1)
        #expect(funcs.first?.container == nil)
    }

    @Test("Dart — class with method")
    func dartClassWithMethod() {
        let source = """
        class Greeter {
          String greet(String name) {
            return 'hi ' + name;
          }
        }
        """
        let entries = indexLang(source, language: "dart", ext: "dart")
        let cls = entries.first { $0.kind == .class && $0.name == "Greeter" }
        #expect(cls != nil)
        let method = entries.first { $0.kind == .method && $0.name == "greet" }
        #expect(method != nil)
        #expect(method?.container == "Greeter")
    }

    @Test("Dart — enum declaration")
    func dartEnumDeclaration() {
        let source = """
        enum Color {
          red, green, blue
        }
        """
        let entries = indexLang(source, language: "dart", ext: "dart")
        let enums = entries.filter { $0.kind == .enum && $0.name == "Color" }
        #expect(enums.count == 1)
        #expect(enums.first?.container == nil)
    }

    // MARK: - TOML

    @Test("TOML — top-level pair")
    func tomlTopLevelPair() {
        let source = """
        name = "senkani"
        version = "0.2.0"
        """
        let entries = indexLang(source, language: "toml", ext: "toml")
        let topVars = entries.filter { $0.kind == .variable && $0.container == nil }
        let names = Set(topVars.map(\.name))
        #expect(names.contains("name"))
        #expect(names.contains("version"))
    }

    @Test("TOML — table header with nested pairs")
    func tomlTable() {
        let source = """
        [database]
        host = "localhost"
        port = 5432
        """
        let entries = indexLang(source, language: "toml", ext: "toml")
        let table = entries.first { $0.kind == .extension && $0.name == "database" }
        #expect(table != nil)
        let host = entries.first { $0.name == "host" }
        #expect(host != nil)
        #expect(host?.container == "database")
        #expect(host?.kind == .property)
    }

    @Test("TOML — table array element")
    func tomlTableArray() {
        let source = """
        [[entries]]
        id = 1

        [[entries]]
        id = 2
        """
        let entries = indexLang(source, language: "toml", ext: "toml")
        let arrays = entries.filter { $0.kind == .extension && $0.name == "entries" }
        #expect(arrays.count == 2)
        let ids = entries.filter { $0.name == "id" && $0.container == "entries" }
        #expect(ids.count == 2)
    }

    // MARK: - GraphQL

    @Test("GraphQL — object type definition")
    func graphqlObjectType() {
        let source = """
        type User {
          id: ID!
          name: String
        }
        """
        let entries = indexLang(source, language: "graphql", ext: "graphql")
        let user = entries.first { $0.kind == .class && $0.name == "User" }
        #expect(user != nil)
    }

    @Test("GraphQL — interface + enum + scalar mix")
    func graphqlMixedDefinitions() {
        let source = """
        interface Node {
          id: ID!
        }

        enum Role {
          ADMIN
          USER
        }

        scalar DateTime
        """
        let entries = indexLang(source, language: "graphql", ext: "graphql")
        #expect(entries.first { $0.kind == .interface && $0.name == "Node" } != nil)
        #expect(entries.first { $0.kind == .enum && $0.name == "Role" } != nil)
        #expect(entries.first { $0.kind == .type && $0.name == "DateTime" } != nil)
    }

    @Test("GraphQL — input + directive definition")
    func graphqlInputAndDirective() {
        let source = """
        input UserInput {
          name: String
        }

        directive @admin on FIELD_DEFINITION
        """
        let entries = indexLang(source, language: "graphql", ext: "graphql")
        let input = entries.first { $0.kind == .struct && $0.name == "UserInput" }
        #expect(input != nil)
        let directive = entries.first { $0.kind == .function && $0.name == "admin" }
        #expect(directive != nil)
    }
}

// MARK: - Helpers

private func indexLang(_ source: String, language: String, ext: String) -> [IndexEntry] {
    let tmpDir = NSTemporaryDirectory() + "senkani-\(language)-test-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }
    let file = "test.\(ext)"
    try! source.write(toFile: tmpDir + "/" + file, atomically: true, encoding: .utf8)
    return (try? TreeSitterBackend.index(files: [file], language: language, projectRoot: tmpDir)) ?? []
}
