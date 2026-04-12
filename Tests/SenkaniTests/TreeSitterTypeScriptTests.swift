import Testing
import Foundation
@testable import Indexer

// MARK: - Suite 1: TypeScript Parsing

@Suite("TreeSitterBackend — TypeScript Parsing")
struct TreeSitterTypeScriptParsingTests {

    @Test func parsesFunctions() {
        let code = """
        function hello() { }
        async function world() { }
        """
        let entries = indexTypeScript(code)
        let funcs = entries.filter { $0.kind == .function }
        #expect(funcs.count == 2, "Expected 2 functions, got \(funcs.count)")
        #expect(funcs.contains { $0.name == "hello" })
        #expect(funcs.contains { $0.name == "world" })
        #expect(funcs.allSatisfy { $0.engine == "tree-sitter" })
    }

    @Test func parsesClasses() {
        let code = """
        class Foo { }
        export class Bar extends Foo { }
        """
        let entries = indexTypeScript(code)
        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 2, "Expected 2 classes, got \(classes.count): \(classes.map(\.name))")
        #expect(classes.contains { $0.name == "Foo" })
        #expect(classes.contains { $0.name == "Bar" })
    }

    @Test func parsesInterfaces() {
        let code = """
        interface Props { name: string; }
        interface State extends Props { }
        """
        let entries = indexTypeScript(code)
        let interfaces = entries.filter { $0.kind == .interface }
        #expect(interfaces.count == 2, "Expected 2 interfaces, got \(interfaces.count): \(interfaces.map(\.name))")
        #expect(interfaces.contains { $0.name == "Props" })
        #expect(interfaces.contains { $0.name == "State" })
    }

    @Test func parsesTypeAliases() {
        let code = """
        type ID = string;
        type Result<T> = { ok: true; value: T }
        """
        let entries = indexTypeScript(code)
        let types = entries.filter { $0.kind == .type }
        #expect(types.count == 2, "Expected 2 type aliases, got \(types.count): \(types.map(\.name))")
        #expect(types.contains { $0.name == "ID" })
        #expect(types.contains { $0.name == "Result" })
    }

    @Test func parsesEnums() {
        let code = """
        enum Color { Red, Green }
        const enum Status { Active }
        """
        let entries = indexTypeScript(code)
        let enums = entries.filter { $0.kind == .enum }
        #expect(enums.count == 2, "Expected 2 enums, got \(enums.count): \(enums.map(\.name))")
        #expect(enums.contains { $0.name == "Color" })
        #expect(enums.contains { $0.name == "Status" })
    }

    @Test func parsesClassMethods() {
        let code = """
        class Greeter {
            greet() { return "hello"; }
            static create() { return new Greeter(); }
        }
        """
        let entries = indexTypeScript(code)
        let classes = entries.filter { $0.kind == .class }
        let methods = entries.filter { $0.kind == .method }

        #expect(classes.count == 1)
        #expect(classes[0].name == "Greeter")
        #expect(methods.count == 2, "Expected 2 methods, got \(methods.count): \(methods.map(\.name))")
        #expect(methods.allSatisfy { $0.container == "Greeter" })
        #expect(methods.contains { $0.name == "greet" })
        #expect(methods.contains { $0.name == "create" })
    }

    @Test func handlesCommentsCorrectly() {
        let code = """
        // function fake() {}
        /* class Fake {} */
        function real() { return 1; }
        """
        let entries = indexTypeScript(code)
        #expect(entries.count == 1, "Expected 1 entry (only 'real'), got \(entries.count): \(entries.map(\.name))")
        #expect(entries[0].name == "real")
    }
}

// MARK: - Suite 2: TSX Parsing with JSX

@Suite("TreeSitterBackend — TSX Parsing with JSX")
struct TreeSitterTSXParsingTests {

    @Test func parsesReactFunctionComponent() {
        let code = """
        interface Props { name: string; }
        export function Greeting({ name }: Props) { return <div>Hello, {name}!</div>; }
        """
        let entries = indexTSX(code)
        let names = entries.map(\.name)
        #expect(entries.contains { $0.name == "Props" && $0.kind == .interface },
                "Should find Props interface, got: \(names)")
        #expect(entries.contains { $0.name == "Greeting" && $0.kind == .function },
                "Should find Greeting function, got: \(names)")
    }

    @Test func parsesReactClassComponent() {
        let code = """
        class App extends React.Component {
            render() { return <h1>Hello</h1>; }
        }
        """
        let entries = indexTSX(code)
        #expect(entries.contains { $0.name == "App" && $0.kind == .class })
        #expect(entries.contains { $0.name == "render" && $0.kind == .method && $0.container == "App" })
    }

    @Test func parsesGenericsAndJSXTogether() {
        let code = """
        function identity<T>(value: T): T { return value; }
        function Wrapper<T>({ children }: { children: T }) { return <div>{children}</div>; }
        """
        let entries = indexTSX(code)
        let funcs = entries.filter { $0.kind == .function }
        #expect(funcs.count == 2, "Expected 2 functions, got \(funcs.count): \(funcs.map(\.name))")
        #expect(funcs.contains { $0.name == "identity" })
        #expect(funcs.contains { $0.name == "Wrapper" })
    }
}

// MARK: - Suite 3: TS/TSX Realistic

@Suite("TreeSitterBackend — TS/TSX Realistic")
struct TreeSitterRealisticTests {

    @Test func parsesRealisticTypeScriptFile() {
        let code = """
        import { EventEmitter } from 'events';

        interface Config {
            debug: boolean;
            maxRetries: number;
        }

        type Result<T> = { ok: true; value: T } | { ok: false; error: string };

        class UserService extends EventEmitter {
            constructor(private config: Config) {
                super();
            }

            async getUser(id: string): Promise<Result<User>> {
                return { ok: true, value: { id, name: 'test' } };
            }

            static create(config: Config): UserService {
                return new UserService(config);
            }
        }

        enum Role {
            Admin = 'admin',
            User = 'user',
        }

        export function createService(debug: boolean = false): UserService {
            return UserService.create({ debug, maxRetries: 3 });
        }
        """
        let entries = indexTypeScript(code)
        let names = entries.map(\.name)

        // Should find: Config (interface), Result (type), UserService (class),
        //              constructor + getUser + create (methods), Role (enum), createService (function)
        #expect(entries.contains { $0.name == "Config" && $0.kind == .interface }, "Missing Config, got: \(names)")
        #expect(entries.contains { $0.name == "Result" && $0.kind == .type }, "Missing Result, got: \(names)")
        #expect(entries.contains { $0.name == "UserService" && $0.kind == .class }, "Missing UserService, got: \(names)")
        #expect(entries.contains { $0.name == "Role" && $0.kind == .enum }, "Missing Role, got: \(names)")
        #expect(entries.contains { $0.name == "createService" && $0.kind == .function }, "Missing createService, got: \(names)")
        #expect(entries.allSatisfy { $0.engine == "tree-sitter" })
    }

    @Test func parsesRealisticTSXFile() {
        let code = """
        import React, { useState } from 'react';

        interface ButtonProps {
            label: string;
            onClick: () => void;
            disabled?: boolean;
        }

        export function Button({ label, onClick, disabled = false }: ButtonProps) {
            const [pressed, setPressed] = useState(false);

            const handleClick = () => {
                setPressed(true);
                onClick();
            };

            return (
                <button
                    className={pressed ? 'pressed' : ''}
                    onClick={handleClick}
                    disabled={disabled}
                >
                    {label}
                </button>
            );
        }
        """
        let entries = indexTSX(code)
        #expect(entries.contains { $0.name == "ButtonProps" && $0.kind == .interface },
                "Should find ButtonProps interface, got: \(entries.map(\.name))")
        #expect(entries.contains { $0.name == "Button" && $0.kind == .function },
                "Should find Button component function, got: \(entries.map(\.name))")
    }
}

// MARK: - Suite 4: TypeScript Performance

@Suite("TreeSitterBackend — TypeScript Performance")
struct TreeSitterTypeScriptPerformanceTests {

    @Test func typescriptFileParsesUnder10ms() {
        var source = ""
        for i in 0..<5 {
            source += "interface I\(i) { value: string; }\n\n"
            source += "class C\(i) {\n"
            for j in 0..<6 {
                source += "    method_\(j)(): void {}\n"
            }
            source += "}\n\n"
        }
        for i in 0..<30 {
            source += "function fn\(i)(x: number): number { return x; }\n"
        }

        let (entries, ms) = measureIndex(source, language: "typescript")
        // 5 interfaces + 5 classes + 30 methods + 30 functions = 70
        #expect(entries.count >= 65, "Should find >= 65 symbols, got \(entries.count)")
        #expect(ms < 10.0, "Parse should be under 10ms, was \(String(format: "%.2f", ms))ms")
    }

    @Test func tsxFileParsesUnder10ms() {
        var source = ""
        for i in 0..<10 {
            source += """
            interface Props\(i) { name: string; }
            export function Component\(i)({ name }: Props\(i)) {
                return <div className="c\(i)">{name}</div>;
            }

            """
        }

        let (entries, ms) = measureIndex(source, language: "tsx")
        // 10 interfaces + 10 functions = 20
        #expect(entries.count >= 20, "Should find >= 20 symbols, got \(entries.count)")
        #expect(ms < 10.0, "Parse should be under 10ms, was \(String(format: "%.2f", ms))ms")
    }

    @Test func tsxAndTsCoexist() {
        let tsCode = """
        interface Config { debug: boolean; }
        function setup(c: Config): void {}
        """
        let tsxCode = """
        interface Props { name: string; }
        function App({ name }: Props) { return <h1>{name}</h1>; }
        """

        let tmpDir = NSTemporaryDirectory() + "senkani-coexist-tstsx-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        try? tsCode.write(toFile: tmpDir + "/test.ts", atomically: true, encoding: .utf8)
        try? tsxCode.write(toFile: tmpDir + "/test.tsx", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        // Parse TypeScript first
        let tsEntries = TreeSitterBackend.index(files: ["test.ts"], language: "typescript", projectRoot: tmpDir)
        // Then TSX
        let tsxEntries = TreeSitterBackend.index(files: ["test.tsx"], language: "tsx", projectRoot: tmpDir)
        // Then TypeScript again (proves no state leak)
        let tsEntries2 = TreeSitterBackend.index(files: ["test.ts"], language: "typescript", projectRoot: tmpDir)

        // TypeScript should find: Config (interface), setup (function)
        #expect(tsEntries.contains { $0.name == "Config" && $0.kind == .interface })
        #expect(tsEntries.contains { $0.name == "setup" && $0.kind == .function })

        // TSX should find: Props (interface), App (function)
        #expect(tsxEntries.contains { $0.name == "Props" && $0.kind == .interface })
        #expect(tsxEntries.contains { $0.name == "App" && $0.kind == .function })

        // Second TypeScript pass should match first
        #expect(tsEntries2.count == tsEntries.count, "TS should produce same results on re-parse")
        #expect(tsEntries2.map(\.name) == tsEntries.map(\.name))
    }
}

// MARK: - Helpers

private func indexTypeScript(_ code: String) -> [IndexEntry] {
    indexLanguage(code, language: "typescript", ext: "ts")
}

private func indexTSX(_ code: String) -> [IndexEntry] {
    indexLanguage(code, language: "tsx", ext: "tsx")
}

private func indexLanguage(_ code: String, language: String, ext: String) -> [IndexEntry] {
    let tmpDir = NSTemporaryDirectory() + "senkani-\(language)-test-\(UUID().uuidString)"
    let filePath = "test.\(ext)"
    let fullPath = tmpDir + "/" + filePath

    try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    try? code.write(toFile: fullPath, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }

    return TreeSitterBackend.index(files: [filePath], language: language, projectRoot: tmpDir)
}

private func measureIndex(_ code: String, language: String) -> ([IndexEntry], Double) {
    let ext = language == "tsx" ? "tsx" : "ts"
    let tmpDir = NSTemporaryDirectory() + "senkani-\(language)-perf-\(UUID().uuidString)"
    let filePath = "perf_test.\(ext)"
    let fullPath = tmpDir + "/" + filePath

    try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    try? code.write(toFile: fullPath, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }

    let clock = ContinuousClock()
    var entries: [IndexEntry] = []
    let elapsed = clock.measure {
        entries = TreeSitterBackend.index(files: [filePath], language: language, projectRoot: tmpDir)
    }

    let ms = Double(elapsed.components.attoseconds) / 1e15
    return (entries, ms)
}
