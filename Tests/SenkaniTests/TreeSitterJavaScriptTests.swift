import Testing
import Foundation
@testable import Indexer

// MARK: - Suite 1: JavaScript Parsing

@Suite("TreeSitterBackend — JavaScript Parsing")
struct TreeSitterJavaScriptParsingTests {

    @Test func parsesFunctions() {
        let code = """
        function hello() { }
        async function world() { return 42; }
        """
        let entries = indexJS(code)
        let funcs = entries.filter { $0.kind == .function }
        #expect(funcs.count == 2, "Expected 2 functions, got \(funcs.count)")
        #expect(funcs.contains { $0.name == "hello" })
        #expect(funcs.contains { $0.name == "world" })
        #expect(funcs.allSatisfy { $0.engine == "tree-sitter" })
    }

    @Test func parsesArrowFunctionsAreNotMatched() {
        let code = """
        const foo = () => 1;
        const bar = function() { };
        """
        let entries = indexJS(code)
        // Arrow functions and anonymous function expressions assigned to const
        // are intentionally not matched in v1. Documents a known limitation.
        #expect(entries.isEmpty, "Arrow/anonymous functions should not produce entries, got \(entries.map(\.name))")
    }

    @Test func parsesClasses() {
        let code = """
        class Foo { }
        export class Bar extends Foo { }
        """
        let entries = indexJS(code)
        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 2, "Expected 2 classes, got \(classes.count): \(classes.map(\.name))")
        #expect(classes.contains { $0.name == "Foo" })
        #expect(classes.contains { $0.name == "Bar" })
    }

    @Test func parsesClassMethods() {
        let code = """
        class MyClass {
            greet() { return 'hi'; }
            static create() { return new MyClass(); }
        }
        """
        let entries = indexJS(code)
        let classes = entries.filter { $0.kind == .class }
        let methods = entries.filter { $0.kind == .method }

        #expect(classes.count == 1)
        #expect(classes[0].name == "MyClass")
        #expect(methods.count == 2, "Expected 2 methods, got \(methods.count): \(methods.map(\.name))")
        #expect(methods.allSatisfy { $0.container == "MyClass" })
        #expect(methods.contains { $0.name == "greet" })
        #expect(methods.contains { $0.name == "create" })
    }

    @Test func parsesGenerators() {
        let code = """
        function* counter() { yield 1; yield 2; }
        """
        let entries = indexJS(code)
        let funcs = entries.filter { $0.kind == .function }
        #expect(funcs.count == 1, "Expected 1 generator function, got \(funcs.count)")
        #expect(funcs[0].name == "counter")
    }

    @Test func parsesExportedDeclarations() {
        let code = """
        export function publicAPI() { }
        export class PublicClass { }
        export default function defaultExport() { }
        """
        let entries = indexJS(code)
        let funcs = entries.filter { $0.kind == .function }
        let classes = entries.filter { $0.kind == .class }
        #expect(funcs.count == 2, "Expected 2 functions, got \(funcs.count): \(funcs.map(\.name))")
        #expect(classes.count == 1, "Expected 1 class, got \(classes.count): \(classes.map(\.name))")
        #expect(funcs.contains { $0.name == "publicAPI" })
        #expect(classes.contains { $0.name == "PublicClass" })
        #expect(funcs.contains { $0.name == "defaultExport" })
    }

    @Test func handlesCommentsCorrectly() {
        let code = """
        // function fake() {}
        /* class Fake {} */
        function real() { return 1; }
        """
        let entries = indexJS(code)
        #expect(entries.count == 1, "Expected 1 entry (only 'real'), got \(entries.count): \(entries.map(\.name))")
        #expect(entries[0].name == "real")
    }

    @Test func handlesJSXInJSFile() {
        let code = """
        function Component() { return <div>hi</div>; }
        """
        let entries = indexJS(code)
        let funcs = entries.filter { $0.kind == .function }
        #expect(funcs.count == 1, "Expected 1 function, got \(funcs.count)")
        #expect(funcs[0].name == "Component")
    }
}

// MARK: - Suite 2: JavaScript Realistic

@Suite("TreeSitterBackend — JavaScript Realistic")
struct TreeSitterJavaScriptRealisticTests {

    @Test func parsesNodeStyleModule() {
        let code = """
        const fs = require('fs');

        function readConfig() {
            return JSON.parse(fs.readFileSync('./config.json'));
        }

        function writeConfig(data) {
            fs.writeFileSync('./config.json', JSON.stringify(data));
        }

        module.exports = { readConfig, writeConfig };
        """
        let entries = indexJS(code)
        let funcs = entries.filter { $0.kind == .function }
        #expect(funcs.count == 2, "Expected 2 functions, got \(funcs.count): \(funcs.map(\.name))")
        #expect(funcs.contains { $0.name == "readConfig" })
        #expect(funcs.contains { $0.name == "writeConfig" })
        #expect(entries.allSatisfy { $0.engine == "tree-sitter" })
    }

    @Test func parsesESMModule() {
        let code = """
        import { EventEmitter } from 'events';

        export class UserService extends EventEmitter {
            constructor() {
                super();
                this.users = [];
            }

            addUser(name) {
                this.users.push(name);
            }

            getCount() {
                return this.users.length;
            }
        }

        export function createService() {
            return new UserService();
        }
        """
        let entries = indexJS(code)
        #expect(entries.contains { $0.name == "UserService" && $0.kind == .class },
                "Should find UserService class")
        #expect(entries.contains { $0.name == "createService" && $0.kind == .function },
                "Should find createService function")
        let methods = entries.filter { $0.kind == .method && $0.container == "UserService" }
        #expect(methods.count >= 2, "Should find at least 2 methods in UserService, got \(methods.count): \(methods.map(\.name))")
    }
}

// MARK: - Suite 3: JavaScript Performance

@Suite("TreeSitterBackend — JavaScript Performance")
struct TreeSitterJavaScriptPerformanceTests {

    @Test func javascriptFileParsesUnder10ms() {
        var source = ""
        for i in 0..<5 {
            source += "class C\(i) {\n"
            for j in 0..<6 {
                source += "    method_\(j)() { return \(j); }\n"
            }
            source += "}\n\n"
        }
        for i in 0..<30 {
            source += "function fn\(i)(x) { return x + \(i); }\n"
        }

        let tmpDir = NSTemporaryDirectory() + "senkani-js-perf-\(UUID().uuidString)"
        let filePath = "perf_test.js"
        let fullPath = tmpDir + "/" + filePath
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        try? source.write(toFile: fullPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let clock = ContinuousClock()
        var entries: [IndexEntry] = []
        let elapsed = clock.measure {
            entries = TreeSitterBackend.index(files: [filePath], language: "javascript", projectRoot: tmpDir)
        }

        let ms = Double(elapsed.components.attoseconds) / 1e15
        // 5 classes + 30 methods + 30 functions = 65
        #expect(entries.count >= 60, "Should find >= 60 symbols, got \(entries.count)")
        #expect(ms < 10.0, "Parse should be under 10ms, was \(String(format: "%.2f", ms))ms")
    }

    @Test func javascriptCoexistsWithTypeScript() {
        let jsCode = """
        function setup() { }
        class App { }
        """
        let tsCode = """
        interface Config { debug: boolean; }
        function setup(c: Config): void { }
        """

        let tmpDir = NSTemporaryDirectory() + "senkani-jsts-coexist-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        try? jsCode.write(toFile: tmpDir + "/test.js", atomically: true, encoding: .utf8)
        try? tsCode.write(toFile: tmpDir + "/test.ts", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        // Parse JS first
        let jsEntries = TreeSitterBackend.index(files: ["test.js"], language: "javascript", projectRoot: tmpDir)
        // Then TS
        let tsEntries = TreeSitterBackend.index(files: ["test.ts"], language: "typescript", projectRoot: tmpDir)
        // Then JS again (proves no state leak)
        let jsEntries2 = TreeSitterBackend.index(files: ["test.js"], language: "javascript", projectRoot: tmpDir)

        // JS should find: setup (function), App (class)
        #expect(jsEntries.contains { $0.name == "setup" && $0.kind == .function })
        #expect(jsEntries.contains { $0.name == "App" && $0.kind == .class })

        // TS should find: Config (interface), setup (function)
        #expect(tsEntries.contains { $0.name == "Config" && $0.kind == .interface })
        #expect(tsEntries.contains { $0.name == "setup" && $0.kind == .function })

        // Second JS pass should match first
        #expect(jsEntries2.count == jsEntries.count, "JS should produce same results on re-parse")
        #expect(jsEntries2.map(\.name) == jsEntries.map(\.name))
    }
}

// MARK: - Helper

private func indexJS(_ code: String) -> [IndexEntry] {
    let tmpDir = NSTemporaryDirectory() + "senkani-js-test-\(UUID().uuidString)"
    let filePath = "test.js"
    let fullPath = tmpDir + "/" + filePath

    try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    try? code.write(toFile: fullPath, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }

    return TreeSitterBackend.index(files: [filePath], language: "javascript", projectRoot: tmpDir)
}
