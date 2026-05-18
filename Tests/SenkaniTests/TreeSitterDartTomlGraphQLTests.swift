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

// MARK: - Dart Depth-Stress Tests

@Suite("TreeSitterBackend — Dart Depth Stress")
struct TreeSitterDartDepthStressTests {

    // Chain child of `indexer-backends-iterative-walk-refactor-2026-05-11`.
    // Generates a top-level variable initializer whose expression is a
    // deeply-nested parenthesized chain, bracketed by two top-level
    // functions, and indexes the file WITHOUT `runOnLargeStackThread`
    // to prove the iterative walk is cooperative-pool-safe.
    //
    // Why a top-level variable initializer, not a function body: Dart's
    // `function_signature` switch arm emits + returns without walking
    // the function body, so depth inside `{...}` is not walked. The
    // deep chain must live in a node whose descendants fall through the
    // default arm (reverse-push children). A top-level variable
    // initializer satisfies this: the variable declaration descends via
    // default-arm pushes through the initializer expression chain. The
    // pre-refactor recursive walk would consume ~2200 Swift call frames
    // and crash on the cooperative pool's smaller stack; the iterative
    // form runs in heap-allocated work-stack memory.
    @Test("Depth-stress iterative walk does not overflow")
    func testDepthStressIterative() {
        let depth = 2200
        let opens = String(repeating: "(", count: depth)
        let closes = String(repeating: ")", count: depth)
        let source = """
        void first() {}

        final int x = \(opens)0\(closes);

        void last() {}
        """

        let entries = indexLang(source, language: "dart", ext: "dart")
        let funcs = entries.filter { $0.kind == .function }
        #expect(funcs.map(\.name) == ["first", "last"],
                "Symbol order must remain left-to-right pre-order")
        #expect(funcs.allSatisfy { $0.container == nil },
                "Top-level Dart functions carry no container")
    }
}

// MARK: - GraphQL Depth-Stress Tests

@Suite("TreeSitterBackend — GraphQL Depth Stress")
struct TreeSitterGraphQLDepthStressTests {

    // Chain child of `indexer-backends-iterative-walk-refactor-2026-05-11`.
    // Generates a top-level executable operation whose selection set
    // nests 2200 levels deep, bracketed by two top-level
    // `object_type_definition`s, and indexes the file WITHOUT
    // `runOnLargeStackThread` to prove the iterative walk is
    // cooperative-pool-safe.
    //
    // Why nested selection sets, not nested types: GraphQL's
    // `object_type_definition` (and the other definition kinds) emit
    // the entry without descent — so depth inside `{ field: Type }`
    // bodies is not walked. The deep chain must live in a node whose
    // descendants fall through the default arm (reverse-push children
    // with container preserved). A top-level `operation_definition`
    // (e.g. `query Deep { … }`) satisfies this: the recursive walker
    // descends through `executable_definition` → `operation_definition`
    // → `selection_set` → `selection` → `field` → `selection_set` (…),
    // none of which match `definitionKind`. The pre-refactor recursive
    // walk would consume thousands of Swift call frames at this depth
    // and crash on the cooperative pool's smaller stack; the iterative
    // form runs in heap-allocated work-stack memory.
    @Test("Depth-stress iterative walk does not overflow")
    func testDepthStressIterative() {
        let depth = 2200
        // Build `a { a { a { … __typename … } } }` with `depth`
        // levels of nesting. Each level is the field `a` with a
        // selection set, terminated by a leaf field `__typename`.
        let opens = String(repeating: "a { ", count: depth)
        let closes = String(repeating: " }", count: depth)
        let source = """
        type First { id: ID! }

        query Deep {
        \(opens)__typename\(closes)
        }

        type Last { id: ID! }
        """

        let entries = indexLang(source, language: "graphql", ext: "graphql")
        let classes = entries.filter { $0.kind == .class }
        #expect(classes.map(\.name) == ["First", "Last"],
                "Bracketing object_type_definition symbols must emit in left-to-right pre-order")
        #expect(classes.allSatisfy { $0.container == nil },
                "Top-level GraphQL definitions carry no container")
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
