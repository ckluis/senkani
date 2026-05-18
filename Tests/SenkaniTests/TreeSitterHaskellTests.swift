import Foundation
import Testing
@testable import Indexer

// MARK: - Haskell Parsing Tests

@Suite("TreeSitterBackend — Haskell Parsing")
struct HaskellParsingTests {

    @Test("Simple functions")
    func parsesSimpleFunctions() {
        let source = """
        module Main where

        hello :: String
        hello = "hi"

        add :: Int -> Int -> Int
        add x y = x + y
        """
        let entries = indexHaskell(source)
        let fns = entries.filter { $0.kind == .function }
        #expect(fns.count == 2)
        let names = Set(fns.map(\.name))
        #expect(names.contains("hello"))
        #expect(names.contains("add"))
        #expect(fns.allSatisfy { $0.container == nil })
    }

    @Test("Functions without signatures")
    func parsesFunctionsWithoutSignatures() {
        let source = """
        module Main where

        double x = x * 2

        triple x = x * 3
        """
        let entries = indexHaskell(source)
        let fns = entries.filter { $0.kind == .function }
        #expect(fns.count == 2)
        let names = Set(fns.map(\.name))
        #expect(names.contains("double"))
        #expect(names.contains("triple"))
    }

    @Test("Multi-equation function dedup")
    func parsesMultiEquationFunctionDedup() {
        let source = """
        module Main where

        factorial :: Int -> Int
        factorial 0 = 1
        factorial n = n * factorial (n - 1)
        """
        let entries = indexHaskell(source)
        let fns = entries.filter { $0.kind == .function }
        // Should produce exactly ONE entry for factorial (deduped)
        #expect(fns.count == 1)
        #expect(fns[0].name == "factorial")
    }

    @Test("Data types")
    func parsesDataTypes() {
        let source = """
        module Main where

        data Color = Red | Green | Blue

        data Maybe a = Nothing | Just a
        """
        let entries = indexHaskell(source)
        let types = entries.filter { $0.kind == .type }
        #expect(types.count == 2)
        let names = Set(types.map(\.name))
        #expect(names.contains("Color"))
        #expect(names.contains("Maybe"))
    }

    @Test("Newtype")
    func parsesNewtype() {
        let source = """
        module Main where

        newtype Age = Age Int

        newtype Wrapper a = Wrapper { unwrap :: a }
        """
        let entries = indexHaskell(source)
        let types = entries.filter { $0.kind == .type }
        #expect(types.count == 2)
        let names = Set(types.map(\.name))
        #expect(names.contains("Age"))
        #expect(names.contains("Wrapper"))
    }

    @Test("Type synonyms")
    func parsesTypeSynonyms() {
        let source = """
        module Main where

        type Name = String

        type Pair a b = (a, b)
        """
        let entries = indexHaskell(source)
        let types = entries.filter { $0.kind == .type }
        #expect(types.count == 2)
        let names = Set(types.map(\.name))
        #expect(names.contains("Name"))
        #expect(names.contains("Pair"))
    }

    @Test("Type class")
    func parsesTypeClass() {
        let source = """
        module Main where

        class Greeter g where
          greet :: g -> String
          hello :: g -> String
          hello g = greet g
        """
        let entries = indexHaskell(source)

        let protocols = entries.filter { $0.kind == .protocol }
        #expect(protocols.count == 1)
        #expect(protocols[0].name == "Greeter")
        #expect(protocols[0].container == nil)

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 2)
        #expect(methods.allSatisfy { $0.container == "Greeter" })
        let names = Set(methods.map(\.name))
        // hello has both a signature and default implementation — deduped to 1 entry
        #expect(names.contains("greet"))
        #expect(names.contains("hello"))
    }

    @Test("Instance")
    func parsesInstance() {
        let source = """
        module Main where

        class Describable a where
          describe :: a -> String

        instance Describable Int where
          describe x = "an integer"
        """
        let entries = indexHaskell(source)

        let protocols = entries.filter { $0.kind == .protocol }
        #expect(protocols.count == 1)
        #expect(protocols[0].name == "Describable")

        let extensions = entries.filter { $0.kind == .extension }
        #expect(extensions.count == 1)
        #expect(extensions[0].name == "Describable")

        // Class body has signature-only "describe" as method
        let classMethods = entries.filter { $0.kind == .method && $0.container == "Describable" }
        #expect(classMethods.count >= 1)
        #expect(classMethods.contains { $0.name == "describe" })
    }

    @Test("Nested class methods")
    func parsesNestedClassMethods() {
        let source = """
        module Main where

        class Eq a where
          eq :: a -> a -> Bool
          neq :: a -> a -> Bool
          neq x y = not (eq x y)
        """
        let entries = indexHaskell(source)

        let protocols = entries.filter { $0.kind == .protocol }
        #expect(protocols.count == 1)
        #expect(protocols[0].name == "Eq")

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 2)
        #expect(methods.allSatisfy { $0.container == "Eq" })
        let names = Set(methods.map(\.name))
        #expect(names.contains("eq"))
        #expect(names.contains("neq"))
    }

    @Test("Comments ignored")
    func handlesCommentsCorrectly() {
        let source = """
        module Main where

        -- This is a comment
        -- add :: Int -> Int -> Int
        -- add x y = x + y

        {- Block comment
           with multiple lines -}

        real :: Int -> Int
        real x = x + 1
        """
        let entries = indexHaskell(source)
        let fns = entries.filter { $0.kind == .function }
        #expect(fns.count == 1)
        #expect(fns[0].name == "real")
        #expect(!entries.contains { $0.name == "add" })
    }
}

// MARK: - Haskell Realistic Tests

@Suite("TreeSitterBackend — Haskell Realistic")
struct HaskellRealisticTests {

    @Test("Realistic Haskell module")
    func parsesRealisticHaskellModule() {
        let source = """
        module Data.Stack where

        data Stack a = Empty | Push a (Stack a)

        type IntStack = Stack Int

        newtype Size = Size Int

        class Container c where
          empty :: c a
          insert :: a -> c a -> c a
          toList :: c a -> [a]

        instance Container Stack where
          empty = Empty
          insert x s = Push x s
          toList Empty = []
          toList (Push x s) = x : toList s

        isEmpty :: Stack a -> Bool
        isEmpty Empty = True
        isEmpty _ = False

        size :: Stack a -> Int
        size Empty = 0
        size (Push _ rest) = 1 + size rest

        push :: a -> Stack a -> Stack a
        push x s = Push x s

        pop :: Stack a -> Stack a
        pop Empty = Empty
        pop (Push _ rest) = rest

        peek :: Stack a -> Maybe a
        peek Empty = Nothing
        peek (Push x _) = Just x
        """
        let entries = indexHaskell(source)

        // Types: Stack, IntStack (type synonym), Size (newtype) = 3
        let types = entries.filter { $0.kind == .type }
        #expect(types.count == 3)
        let typeNames = Set(types.map(\.name))
        #expect(typeNames.contains("Stack"))
        #expect(typeNames.contains("IntStack"))
        #expect(typeNames.contains("Size"))

        // Type class: Container
        let protocols = entries.filter { $0.kind == .protocol }
        #expect(protocols.count == 1)
        #expect(protocols[0].name == "Container")

        // Class methods (3 sig-only) + instance methods (3 implementations) = 6
        // Both scopes use container "Container" since instance's name field is the class name
        let containerMethods = entries.filter { $0.kind == .method && $0.container == "Container" }
        #expect(containerMethods.count == 6)
        let containerMethodNames = Set(containerMethods.map(\.name))
        #expect(containerMethodNames.contains("empty"))
        #expect(containerMethodNames.contains("insert"))
        #expect(containerMethodNames.contains("toList"))

        // Instance: Container
        let extensions = entries.filter { $0.kind == .extension }
        #expect(extensions.count == 1)
        #expect(extensions[0].name == "Container")

        // Top-level functions: isEmpty, size, push, pop, peek = 5 (each deduped)
        let fns = entries.filter { $0.kind == .function }
        #expect(fns.count == 5)
        let fnNames = Set(fns.map(\.name))
        #expect(fnNames.contains("isEmpty"))
        #expect(fnNames.contains("size"))
        #expect(fnNames.contains("push"))
        #expect(fnNames.contains("pop"))
        #expect(fnNames.contains("peek"))

        // All from tree-sitter
        #expect(entries.allSatisfy { $0.engine == "tree-sitter" })
    }
}

// MARK: - Haskell Performance Tests

@Suite("TreeSitterBackend — Haskell Performance")
struct HaskellPerformanceTests {

    @Test("Haskell file parses under 10ms")
    func haskellFileParsesUnder10ms() {
        var source = "module BigModule where\n\n"
        for i in 0..<20 {
            source += "func_\(i) :: Int -> Int\n"
            source += "func_\(i) x = x + \(i)\n\n"
        }
        source += "data MyType = A | B | C\n\n"
        source += "type Alias = Int\n"
        // Median-of-3 — see DependencyGraphPerfGateTests for canonical
        // pattern. Threshold widened 10 ms → 50 ms (matching Kotlin/Elixir
        // pattern in this file family): in-isolation typical was already
        // ~10 ms, leaving zero headroom for parallel-runner CPU contention.
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for _ in 0..<3 {
            let elapsed = clock.measure {
                let entries = indexHaskell(source)
                #expect(entries.count > 0)
            }
            samples.append(elapsed)
        }
        let median = samples.sorted()[1]
        #expect(
            median < .milliseconds(50),
            "median of 3 Haskell parses: \(samples) → median \(median)"
        )
    }

    @Test("Haskell coexists with other languages")
    func haskellCoexistsWithOtherLanguages() {
        let tmpDir = NSTemporaryDirectory() + "senkani-haskell-coexist-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        // Haskell file
        let haskellSource = "module Main where\n\ngreet :: String -> String\ngreet name = \"hi, \" ++ name\n"
        try! haskellSource.write(toFile: tmpDir + "/Main.hs", atomically: true, encoding: .utf8)

        // Elixir file
        let elixirSource = "defmodule Greeter do\n  def greet(name), do: \"hi, \" <> name\nend\n"
        try! elixirSource.write(toFile: tmpDir + "/greeter.ex", atomically: true, encoding: .utf8)

        // Scala file
        let scalaSource = "class Greeter {\n  def greet(name: String): String = s\"hi, $name\"\n}\n"
        try! scalaSource.write(toFile: tmpDir + "/Greeter.scala", atomically: true, encoding: .utf8)

        let haskellEntries = (try? TreeSitterBackend.index(files: ["Main.hs"], language: "haskell", projectRoot: tmpDir)) ?? []
        let elixirEntries = (try? TreeSitterBackend.index(files: ["greeter.ex"], language: "elixir", projectRoot: tmpDir)) ?? []
        let scalaEntries = (try? TreeSitterBackend.index(files: ["Greeter.scala"], language: "scala", projectRoot: tmpDir)) ?? []

        // Haskell: function greet = 1
        #expect(haskellEntries.count == 1)
        #expect(haskellEntries.contains { $0.name == "greet" && $0.kind == .function })

        // Elixir: module Greeter + method greet = 2
        #expect(elixirEntries.count == 2)
        #expect(elixirEntries.contains { $0.name == "Greeter" && $0.kind == .class })

        // Scala: class Greeter + method greet = 2
        #expect(scalaEntries.count == 2)
        #expect(scalaEntries.contains { $0.name == "Greeter" && $0.kind == .class })
    }
}

// MARK: - Haskell Depth Stress

@Suite("TreeSitterBackend — Haskell Depth Stress")
struct TreeSitterHaskellDepthStressTests {

    // Chain child of `indexer-backends-iterative-walk-refactor-2026-05-11`.
    // Generates a top-level value binding whose right-hand side is a
    // 2200-deep lambda chain, bracketed by two top-level function
    // declarations, and indexes the file WITHOUT `runOnLargeStackThread`
    // to prove the iterative walk is cooperative-pool-safe.
    //
    // Why lambdas (not parenthesized expressions like the other chain
    // children's fixtures): tree-sitter-haskell 0.23.1's GLR parser
    // exhausts internal state at ~125 nested parens (`(((…)))`) and
    // returns no tree, so the parens fixture used by the C / Cpp /
    // CSharp / Dart / Elixir / GraphQL chain predecessors cannot reach
    // 2000-depth on Haskell. Right-associative lambda chains
    // (`\x -> \x -> \x -> … 0`) avoid the precedence-resolution
    // explosion and parse cleanly at 2200 depth.
    //
    // Note on what the walker traverses: HaskellBackend's pre-refactor
    // recursion sites were (i) walk's default arm (line 56), and
    // (ii) walkDeclarations' class/instance body recursion (lines
    // 116/130). Both of those operate on declarations-grouping nodes
    // (`declarations` / `class_declarations` / `instance_declarations`);
    // the `function`/`bind` arm emits a binding symbol WITHOUT
    // descending into its expression body, so the deep lambda chain
    // is not directly walked in this fixture. The test still validates
    // the iterative-form correctness contract: (a) the iterative
    // walker emits the bracketing top-level symbols in source order
    // on a deep parse tree, (b) the iterative form is defense-in-depth
    // / grammar-update-future-proofing — if a future tree-sitter-
    // haskell update or backend change starts descending through value-
    // binding bodies, the structural guarantee that no AST shape can
    // consume Swift call frames already holds.
    @Test("Depth-stress iterative walk does not overflow")
    func testDepthStressIterative() {
        let depth = 2200
        let lambdas = String(repeating: "\\x -> ", count: depth)
        let source = """
        first :: Int -> Int
        first n = n

        x = \(lambdas)0

        last :: Int -> Int
        last n = n
        """

        let entries = indexHaskell(source)
        let funcs = entries.filter { $0.kind == .function }
        #expect(funcs.map(\.name) == ["first", "x", "last"],
                "Bracketing top-level Haskell functions and value binding must emit in left-to-right pre-order")
        #expect(funcs.allSatisfy { $0.container == nil },
                "Top-level Haskell functions and value bindings carry no container")
    }
}

// MARK: - Helper

private func indexHaskell(_ source: String) -> [IndexEntry] {
    let tmpDir = NSTemporaryDirectory() + "senkani-haskell-test-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }
    let file = "test.hs"
    try! source.write(toFile: tmpDir + "/" + file, atomically: true, encoding: .utf8)
    return (try? TreeSitterBackend.index(files: [file], language: "haskell", projectRoot: tmpDir)) ?? []
}
