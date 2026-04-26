import Testing
import Foundation
@testable import Indexer

// MARK: - Suite 1: Rust Parsing

@Suite("TreeSitterBackend — Rust Parsing")
struct TreeSitterRustParsingTests {

    @Test func parsesTopLevelFunctions() {
        let code = """
        fn hello() {}
        pub fn world() -> String { String::new() }
        """
        let entries = indexRust(code)
        let funcs = entries.filter { $0.kind == .function }
        #expect(funcs.count == 2, "Expected 2 functions, got \(funcs.count)")
        #expect(funcs.contains { $0.name == "hello" })
        #expect(funcs.contains { $0.name == "world" })
        #expect(funcs.allSatisfy { $0.container == nil })
        #expect(funcs.allSatisfy { $0.engine == "tree-sitter" })
    }

    @Test func parsesStructs() {
        let code = """
        struct User { name: String }
        struct Empty;
        pub struct Counter(i32);
        """
        let entries = indexRust(code)
        let structs = entries.filter { $0.kind == .struct }
        #expect(structs.count == 3, "Expected 3 structs, got \(structs.count)")
        #expect(structs.contains { $0.name == "User" })
        #expect(structs.contains { $0.name == "Empty" })
        #expect(structs.contains { $0.name == "Counter" })
    }

    @Test func parsesEnums() {
        let code = """
        enum Color { Red, Green, Blue }
        pub enum MyResult<T, E> { Ok(T), Err(E) }
        """
        let entries = indexRust(code)
        let enums = entries.filter { $0.kind == .enum }
        #expect(enums.count == 2, "Expected 2 enums, got \(enums.count)")
        #expect(enums.contains { $0.name == "Color" })
        #expect(enums.contains { $0.name == "MyResult" })
    }

    @Test func parsesTraits() {
        let code = """
        trait Greet {
            fn greet(&self) -> String;
        }
        pub trait Render {
            fn render(&self) -> String;
        }
        """
        let entries = indexRust(code)
        let traits = entries.filter { $0.kind == .protocol }
        #expect(traits.count == 2, "Expected 2 traits, got \(traits.count)")
        #expect(traits.contains { $0.name == "Greet" })
        #expect(traits.contains { $0.name == "Render" })
    }

    @Test func parsesTypeAliases() {
        let code = """
        type UserId = u64;
        type Name = String;
        """
        let entries = indexRust(code)
        let types = entries.filter { $0.kind == .type }
        #expect(types.count == 2, "Expected 2 type aliases, got \(types.count)")
        #expect(types.contains { $0.name == "UserId" })
        #expect(types.contains { $0.name == "Name" })
    }

    @Test func parsesInherentImplMethods() {
        let code = """
        struct User { name: String }
        impl User {
            fn greet(&self) -> String { format!("hi, {}", self.name) }
            fn name(&self) -> &str { &self.name }
        }
        """
        let entries = indexRust(code)
        let structs = entries.filter { $0.kind == .struct }
        let methods = entries.filter { $0.kind == .method }
        #expect(structs.count == 1)
        #expect(structs[0].name == "User")
        #expect(methods.count == 2, "Expected 2 methods, got \(methods.count)")
        #expect(methods.allSatisfy { $0.container == "User" })
        #expect(methods.contains { $0.name == "greet" })
        #expect(methods.contains { $0.name == "name" })
    }

    @Test func parsesTraitImplMethods() {
        let code = """
        struct User;
        impl Display for User {
            fn fmt(&self, f: &mut Formatter) -> Result { write!(f, "User") }
        }
        """
        let entries = indexRust(code)
        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 1, "Expected 1 method, got \(methods.count)")
        #expect(methods[0].name == "fmt")
        #expect(methods[0].container == "User", "Container should be User, got \(methods[0].container ?? "nil")")
    }

    @Test func parsesGenericImplMethods() {
        let code = """
        struct Wrapper<T> { value: T }
        impl<T> Wrapper<T> {
            fn new(value: T) -> Self { Wrapper { value } }
            fn get(&self) -> &T { &self.value }
        }
        """
        let entries = indexRust(code)
        let structs = entries.filter { $0.kind == .struct }
        let methods = entries.filter { $0.kind == .method }
        #expect(structs.count == 1)
        #expect(structs[0].name == "Wrapper")
        #expect(methods.count == 2, "Expected 2 methods, got \(methods.count)")
        #expect(methods.allSatisfy { $0.container == "Wrapper" },
                "Container should be Wrapper (no generics), got \(methods.map { $0.container ?? "nil" })")
    }

    @Test func mixedTopLevelAndImplFunctions() {
        let code = """
        fn main() { println!("hello"); }

        struct App { running: bool }

        impl App {
            fn start(&mut self) { self.running = true; }
            fn stop(&mut self) { self.running = false; }
        }
        """
        let entries = indexRust(code)
        let topLevel = entries.filter { $0.kind == .function }
        let methods = entries.filter { $0.kind == .method }
        #expect(topLevel.count == 1, "Expected 1 top-level function, got \(topLevel.count)")
        #expect(topLevel[0].name == "main")
        #expect(topLevel[0].container == nil)
        #expect(methods.count == 2, "Expected 2 methods, got \(methods.count)")
        #expect(methods.allSatisfy { $0.container == "App" })
    }

    @Test func handlesCommentsCorrectly() {
        let code = """
        // fn fake() {}
        /* struct Fake; */
        fn real() {}
        """
        let entries = indexRust(code)
        #expect(entries.count == 1, "Expected 1 entry (only 'real'), got \(entries.count)")
        #expect(entries[0].name == "real")
    }
}

// MARK: - Suite 2: Rust Realistic

@Suite("TreeSitterBackend — Rust Realistic")
struct TreeSitterRustRealisticTests {

    @Test func parsesRealisticRustFile() {
        let code = """
        use std::fmt;

        pub struct Server {
            port: u16,
            running: bool,
        }

        pub trait Handler {
            fn handle(&self, request: &str) -> String;
        }

        impl Server {
            pub fn new(port: u16) -> Self {
                Server { port, running: false }
            }

            pub fn start(&mut self) {
                self.running = true;
            }

            pub fn port(&self) -> u16 {
                self.port
            }
        }

        impl fmt::Display for Server {
            fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
                write!(f, "Server({})", self.port)
            }
        }

        pub fn create_server(port: u16) -> Server {
            Server::new(port)
        }
        """
        let entries = indexRust(code)

        // Struct
        #expect(entries.contains { $0.name == "Server" && $0.kind == .struct },
                "Should find Server struct")

        // Trait
        #expect(entries.contains { $0.name == "Handler" && $0.kind == .protocol },
                "Should find Handler trait")

        // Top-level function
        #expect(entries.contains { $0.name == "create_server" && $0.kind == .function },
                "Should find create_server function")

        // Inherent impl methods (new, start, port)
        let inherentMethods = entries.filter { $0.kind == .method && $0.container == "Server" }
        let methodNames = inherentMethods.map(\.name).sorted()
        #expect(inherentMethods.count == 4,
                "Expected 4 Server methods (new, start, port, fmt), got \(inherentMethods.count): \(methodNames)")
        #expect(methodNames.contains("new"))
        #expect(methodNames.contains("start"))
        #expect(methodNames.contains("port"))
        #expect(methodNames.contains("fmt"))

        // All entries should be tree-sitter
        #expect(entries.allSatisfy { $0.engine == "tree-sitter" })
    }
}

// MARK: - Suite 3: Rust Performance

@Suite("TreeSitterBackend — Rust Performance")
struct TreeSitterRustPerformanceTests {

    @Test func rustFileParsesUnder10ms() {
        var source = ""
        for i in 0..<5 {
            source += "struct S\(i) { field: i32 }\n\n"
            source += "impl S\(i) {\n"
            for j in 0..<6 {
                source += "    fn method_\(j)(&self) -> i32 { \(j) }\n"
            }
            source += "}\n\n"
        }
        for i in 0..<30 {
            source += "fn fn\(i)(x: i32) -> i32 { x + \(i) }\n"
        }

        let tmpDir = NSTemporaryDirectory() + "senkani-rust-perf-\(UUID().uuidString)"
        let filePath = "perf_test.rs"
        let fullPath = tmpDir + "/" + filePath
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        try? source.write(toFile: fullPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let clock = ContinuousClock()
        var entries: [IndexEntry] = []
        let elapsed = clock.measure {
            entries = (try? TreeSitterBackend.index(files: [filePath], language: "rust", projectRoot: tmpDir)) ?? []
        }

        let ms = Double(elapsed.components.attoseconds) / 1e15
        // 5 structs + 30 methods + 30 functions = 65
        #expect(entries.count >= 60, "Should find >= 60 symbols, got \(entries.count)")
        #expect(ms < 10.0, "Parse should be under 10ms, was \(String(format: "%.2f", ms))ms")
    }

    @Test func rustCoexistsWithOtherLanguages() {
        let goCode = """
        package main

        type App struct {}
        func (a *App) Run() {}
        func setup() {}
        """
        let rustCode = """
        struct App { running: bool }
        impl App {
            fn run(&self) {}
        }
        fn setup() {}
        """
        let swiftCode = """
        class App {
            func run() {}
        }
        func setup() {}
        """

        let tmpDir = NSTemporaryDirectory() + "senkani-rust-coexist-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        try? goCode.write(toFile: tmpDir + "/main.go", atomically: true, encoding: .utf8)
        try? rustCode.write(toFile: tmpDir + "/lib.rs", atomically: true, encoding: .utf8)
        try? swiftCode.write(toFile: tmpDir + "/App.swift", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        // Parse Go
        let goEntries = (try? TreeSitterBackend.index(files: ["main.go"], language: "go", projectRoot: tmpDir)) ?? []
        // Then Rust
        let rustEntries = (try? TreeSitterBackend.index(files: ["lib.rs"], language: "rust", projectRoot: tmpDir)) ?? []
        // Then Swift
        let swiftEntries = (try? TreeSitterBackend.index(files: ["App.swift"], language: "swift", projectRoot: tmpDir)) ?? []
        // Then Rust again (proves no state leak)
        let rustEntries2 = (try? TreeSitterBackend.index(files: ["lib.rs"], language: "rust", projectRoot: tmpDir)) ?? []

        // Go: App (struct), Run (method on App), setup (function)
        #expect(goEntries.contains { $0.name == "App" && $0.kind == .struct })
        #expect(goEntries.contains { $0.name == "Run" && $0.kind == .method })
        #expect(goEntries.contains { $0.name == "setup" && $0.kind == .function })

        // Rust: App (struct), run (method on App), setup (function)
        #expect(rustEntries.contains { $0.name == "App" && $0.kind == .struct })
        #expect(rustEntries.contains { $0.name == "run" && $0.kind == .method && $0.container == "App" })
        #expect(rustEntries.contains { $0.name == "setup" && $0.kind == .function })

        // Swift: App (class), run (method), setup (function)
        #expect(swiftEntries.contains { $0.name == "App" && $0.kind == .class })
        #expect(swiftEntries.contains { $0.name == "setup" && $0.kind == .function })

        // Second Rust pass should match first
        #expect(rustEntries2.count == rustEntries.count, "Rust should produce same results on re-parse")
        #expect(rustEntries2.map(\.name).sorted() == rustEntries.map(\.name).sorted())
    }
}

// MARK: - Helper

private func indexRust(_ code: String) -> [IndexEntry] {
    let tmpDir = NSTemporaryDirectory() + "senkani-rust-test-\(UUID().uuidString)"
    let filePath = "test.rs"
    let fullPath = tmpDir + "/" + filePath

    try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    try? code.write(toFile: fullPath, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }

    return (try? TreeSitterBackend.index(files: [filePath], language: "rust", projectRoot: tmpDir)) ?? []
}
