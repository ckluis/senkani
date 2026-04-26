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
