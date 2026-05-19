import Testing
import Foundation
@testable import Indexer

@Suite("TreeSitterBackend")
struct TreeSitterBackendTests {

    @Test func supportsSwift() {
        #expect(TreeSitterBackend.supports("swift"))
    }

    @Test func functionsAtTopLevel() {
        let code = """
        import Foundation

        public func doSomething() {
            print("hello")
        }

        private func helper(_ x: Int) -> Bool {
            return x > 0
        }
        """
        let entries = indexSwift(code)
        let funcs = entries.filter { $0.kind == .function }
        #expect(funcs.count == 2, "Expected 2 functions, got \(funcs.count)")
        #expect(funcs.contains { $0.name == "doSomething" })
        #expect(funcs.contains { $0.name == "helper" })
        #expect(funcs.allSatisfy { $0.engine == "tree-sitter" })
    }

    @Test func classWithMethods() {
        let code = """
        class FilterEngine {
            func filter(_ input: String) -> String {
                return input
            }

            func reset() {}
        }
        """
        let entries = indexSwift(code)
        let classEntries = entries.filter { $0.kind == .class }
        let methods = entries.filter { $0.kind == .method }

        #expect(classEntries.count == 1)
        #expect(classEntries[0].name == "FilterEngine")

        #expect(methods.count == 2, "Expected 2 methods, got \(methods.count)")
        #expect(methods.allSatisfy { $0.container == "FilterEngine" })
    }

    @Test func structDeclaration() {
        let code = """
        struct Point {
            var x: Double
            var y: Double

            func distance(to other: Point) -> Double {
                return 0
            }
        }
        """
        let entries = indexSwift(code)
        #expect(entries.contains { $0.name == "Point" && $0.kind == .struct })
        let methods = entries.filter { $0.kind == .method && $0.container == "Point" }
        #expect(methods.contains { $0.name == "distance" })
    }

    @Test func enumDeclaration() {
        let code = """
        enum Direction {
            case north
            case south
            case east
            case west

            func description() -> String {
                return ""
            }
        }
        """
        let entries = indexSwift(code)
        #expect(entries.contains { $0.name == "Direction" && $0.kind == .enum })
    }

    @Test func protocolDeclaration() {
        let code = """
        protocol Indexable {
            func index()
            func search(query: String) -> [String]
        }
        """
        let entries = indexSwift(code)
        #expect(entries.contains { $0.name == "Indexable" && $0.kind == .protocol })
        let methods = entries.filter { $0.kind == .method && $0.container == "Indexable" }
        #expect(methods.count >= 1, "Protocol methods should have container set")
    }

    @Test func extensionDeclaration() {
        let code = """
        extension String {
            func trimmed() -> String {
                return self.trimmingCharacters(in: .whitespaces)
            }
        }
        """
        let entries = indexSwift(code)
        #expect(entries.contains { $0.name == "String" && $0.kind == .extension })
        let methods = entries.filter { $0.kind == .method }
        #expect(methods.contains { $0.name == "trimmed" && $0.container == "String" })
    }

    @Test func initDeclaration() {
        let code = """
        struct Config {
            let debug: Bool

            init(debug: Bool = false) {
                self.debug = debug
            }
        }
        """
        let entries = indexSwift(code)
        let inits = entries.filter { $0.name == "init" }
        #expect(inits.count == 1)
        #expect(inits[0].kind == .method)
        #expect(inits[0].container == "Config")
    }

    @Test func propertyDeclarations() {
        let code = """
        class ViewModel {
            var count: Int = 0
            let name: String = "test"
        }
        """
        let entries = indexSwift(code)
        let props = entries.filter { $0.kind == .property }
        #expect(props.count >= 1, "Expected at least 1 property")
    }

    @Test func lineNumbers() {
        let code = """
        func first() {
        }

        func second() {
        }
        """
        let entries = indexSwift(code)
        let first = entries.first { $0.name == "first" }
        let second = entries.first { $0.name == "second" }
        #expect(first != nil)
        #expect(second != nil)
        #expect(first!.startLine == 1, "first() should start at line 1, was \(first!.startLine)")
        #expect(second!.startLine == 4, "second() should start at line 4, was \(second!.startLine)")
        #expect(first!.endLine! >= first!.startLine, "endLine should be >= startLine")
    }

    @Test func signatureCapture() {
        let code = """
        public func process(input: String, count: Int) -> Bool {
            return true
        }
        """
        let entries = indexSwift(code)
        let fn = entries.first { $0.name == "process" }
        #expect(fn != nil)
        #expect(fn!.signature?.contains("process") == true)
    }

    @Test func nestedTypes() {
        let code = """
        class Outer {
            struct Inner {
                func doWork() {}
            }
        }
        """
        let entries = indexSwift(code)
        #expect(entries.contains { $0.name == "Outer" && $0.kind == .class })
        #expect(entries.contains { $0.name == "Inner" && $0.kind == .struct && $0.container == "Outer" })
        #expect(entries.contains { $0.name == "doWork" && $0.kind == .method && $0.container == "Inner" })
    }

    @Test func emptyFile() {
        let entries = indexSwift("")
        #expect(entries.isEmpty)
    }

    @Test func allDeclarationTypes() {
        let code = """
        public final class FilterEngine: Sendable {
            func filter() {}
        }

        struct FilterResult: Sendable {
            let output: String
        }

        enum SymbolKind: String {
            case function
        }

        protocol Indexable {
            func index()
        }
        """
        let entries = indexSwift(code)
        let kinds = Set(entries.map(\.kind))
        #expect(kinds.contains(SymbolKind.class), "Should find class")
        #expect(kinds.contains(SymbolKind.struct), "Should find struct")
        #expect(kinds.contains(SymbolKind.enum), "Should find enum")
        #expect(kinds.contains(SymbolKind.protocol), "Should find protocol")
    }

    // MARK: - Helper

    private func indexSwift(_ code: String) -> [IndexEntry] {
        let tmpDir = NSTemporaryDirectory() + "senkani-ts-test-\(UUID().uuidString)"
        let filePath = "test.swift"
        let fullPath = tmpDir + "/" + filePath

        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        try? code.write(toFile: fullPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        return (try? TreeSitterBackend.index(files: [filePath], language: "swift", projectRoot: tmpDir)) ?? []
    }
}

@Suite("TreeSitterBackend — Swift Depth Stress")
struct TreeSitterSwiftDepthStressTests {

    // Chain child of `indexer-backends-iterative-walk-refactor-2026-05-11`.
    // Generates a top-level call_expression with deeply-nested
    // parenthesized arguments, and indexes the file WITHOUT
    // `runOnLargeStackThread` to prove the iterative walk is
    // cooperative-pool-safe. Two empty top-level classes bracket the
    // deep expression to assert pre-order symbol emission.
    //
    // Why a top-level call_expression, not a class-body bare
    // expression (the ScalaBackend pattern): tree-sitter-swift's
    // grammar does NOT accept bare parenthesized expressions inside
    // a class body (class body requires declarations, not statements),
    // so a `class Container { (((...0...))) }` fixture forces the
    // parser into deep error-recovery — the recovery itself blew the
    // cooperative-pool stack at depth ~1000 even though the iterative
    // walk handles arbitrary depth. The fix: put the deep chain at
    // top level inside a syntactically-valid construct. A top-level
    // `print(\(opens)0\(closes))` is valid Swift script-mode syntax
    // (tree-sitter-swift accepts top-level expression statements);
    // the parser produces a clean tree (no error recovery), and the
    // call_expression + its parenthesized-argument chain falls
    // through the default arm at every level so the iterative walk's
    // work-stack descends ~2200 deep through heap-backed memory.
    //
    // Why not a property initializer or a function body: Swift's
    // leaf-emit arms (`function_declaration` /
    // `protocol_function_declaration`, `init_declaration`,
    // `property_declaration` / `protocol_property_declaration`) emit
    // and return without descending into the body or initializer
    // subtree, so the deep chain cannot live inside a
    // `let x = (((...)))` property or a function body — the walk
    // would never reach the parens. The deep chain must live in a
    // node whose descendants fall through the default arm
    // (reverse-push children). Top-level call_expression satisfies
    // this — call_expression is not one of the matched arms, so it
    // falls through default and the parenthesized-argument chain
    // pushes ~2200 deep through repeated default-arm descent. The
    // pre-refactor walk would consume ~2200 Swift call frames and
    // crash on the cooperative pool's smaller stack; the iterative
    // form runs in heap-allocated work-stack memory.
    @Test("Depth-stress iterative walk does not overflow")
    func testDepthStressIterative() {
        let depth = 2200
        let opens = String(repeating: "(", count: depth)
        let closes = String(repeating: ")", count: depth)
        let source = """
        class First {}

        print(\(opens)0\(closes))

        class Last {}
        """

        let entries = indexSwiftDepth(source)
        let classes = entries.filter { $0.kind == .class }
        #expect(classes.map(\.name) == ["First", "Last"],
                "Symbol order must remain left-to-right pre-order")
        #expect(classes.allSatisfy { $0.container == nil },
                "Top-level Swift classes carry no container")
    }
}

// MARK: - Helper

private func indexSwiftDepth(_ code: String) -> [IndexEntry] {
    let tmpDir = NSTemporaryDirectory() + "senkani-swift-depth-test-\(UUID().uuidString)"
    let filePath = "test.swift"
    let fullPath = tmpDir + "/" + filePath

    try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    try? code.write(toFile: fullPath, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }

    return (try? TreeSitterBackend.index(files: [filePath], language: "swift", projectRoot: tmpDir)) ?? []
}
