import Testing
import Foundation
@testable import Indexer

// MARK: - Suite 1: Go Parsing

@Suite("TreeSitterBackend — Go Parsing")
struct TreeSitterGoParsingTests {

    @Test func parsesFunctions() {
        let code = """
        package main

        func hello() {}
        func world(x int) string { return "" }
        """
        let entries = indexGo(code)
        let funcs = entries.filter { $0.kind == .function }
        #expect(funcs.count == 2, "Expected 2 functions, got \(funcs.count)")
        #expect(funcs.contains { $0.name == "hello" })
        #expect(funcs.contains { $0.name == "world" })
        #expect(funcs.allSatisfy { $0.engine == "tree-sitter" })
    }

    @Test func parsesStructTypes() {
        let code = """
        package main

        type User struct {
            Name string
            Age  int
        }

        type Config struct {
            Debug bool
        }
        """
        let entries = indexGo(code)
        let structs = entries.filter { $0.kind == .struct }
        #expect(structs.count == 2, "Expected 2 structs, got \(structs.count)")
        #expect(structs.contains { $0.name == "User" })
        #expect(structs.contains { $0.name == "Config" })
    }

    @Test func parsesInterfaceTypes() {
        let code = """
        package main

        type Reader interface {
            Read(p []byte) (n int, err error)
        }

        type Writer interface {
            Write(p []byte) (n int, err error)
        }
        """
        let entries = indexGo(code)
        let interfaces = entries.filter { $0.kind == .interface }
        #expect(interfaces.count == 2, "Expected 2 interfaces, got \(interfaces.count)")
        #expect(interfaces.contains { $0.name == "Reader" })
        #expect(interfaces.contains { $0.name == "Writer" })
    }

    @Test func parsesTypeAliases() {
        let code = """
        package main

        type ID int
        type Name string
        """
        let entries = indexGo(code)
        let types = entries.filter { $0.kind == .type }
        #expect(types.count == 2, "Expected 2 type aliases, got \(types.count)")
        #expect(types.contains { $0.name == "ID" })
        #expect(types.contains { $0.name == "Name" })
    }

    @Test func parsesValueReceiverMethods() {
        let code = """
        package main

        type User struct {
            Name string
        }

        func (u User) Greet() string {
            return "Hello, " + u.Name
        }

        func (u User) String() string {
            return u.Name
        }
        """
        let entries = indexGo(code)
        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 2, "Expected 2 methods, got \(methods.count)")
        #expect(methods.allSatisfy { $0.container == "User" })
        #expect(methods.contains { $0.name == "Greet" })
        #expect(methods.contains { $0.name == "String" })
    }

    @Test func handlesCommentsCorrectly() {
        let code = """
        package main

        // func fake() {}
        /* type Fake struct {} */
        func real() {}
        """
        let entries = indexGo(code)
        #expect(entries.count == 1, "Expected 1 entry (only 'real'), got \(entries.count)")
        #expect(entries[0].name == "real")
    }

    @Test func parsesPointerReceiverMethods() {
        let code = """
        package main

        type Counter struct {
            count int
        }

        func (c *Counter) Increment() {
            c.count++
        }

        func (c *Counter) Reset() {
            c.count = 0
        }
        """
        let entries = indexGo(code)
        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 2, "Expected 2 methods, got \(methods.count)")
        #expect(methods.allSatisfy { $0.container == "Counter" })
        #expect(methods.contains { $0.name == "Increment" })
        #expect(methods.contains { $0.name == "Reset" })
    }
}

// MARK: - Suite 2: Go Realistic

@Suite("TreeSitterBackend — Go Realistic")
struct TreeSitterGoRealisticTests {

    @Test func parsesHTTPHandlerPattern() {
        let code = """
        package server

        type Server struct {
            port int
        }

        func NewServer(port int) *Server {
            return &Server{port: port}
        }

        func (s *Server) Start() error {
            return nil
        }

        func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
            w.Write([]byte("ok"))
        }

        func (s *Server) handleUsers(w http.ResponseWriter, r *http.Request) {
            w.Write([]byte("users"))
        }
        """
        let entries = indexGo(code)

        // Should find Server struct
        #expect(entries.contains { $0.name == "Server" && $0.kind == .struct },
                "Should find Server struct")

        // Should find NewServer as a top-level function (no receiver)
        #expect(entries.contains { $0.name == "NewServer" && $0.kind == .function },
                "Should find NewServer function")

        // Should find 3 methods on Server
        let methods = entries.filter { $0.kind == .method && $0.container == "Server" }
        #expect(methods.count == 3, "Expected 3 Server methods, got \(methods.count)")
        let names = methods.map(\.name).sorted()
        #expect(names == ["Start", "handleHealth", "handleUsers"])
    }

    @Test func parsesInterfaceWithMultipleImplementors() {
        let code = """
        package shapes

        type Shape interface {
            Area() float64
            Perimeter() float64
        }

        type Circle struct {
            Radius float64
        }

        func (c Circle) Area() float64 {
            return 3.14159 * c.Radius * c.Radius
        }

        func (c Circle) Perimeter() float64 {
            return 2 * 3.14159 * c.Radius
        }

        type Rectangle struct {
            Width  float64
            Height float64
        }

        func (r Rectangle) Area() float64 {
            return r.Width * r.Height
        }

        func (r Rectangle) Perimeter() float64 {
            return 2 * (r.Width + r.Height)
        }
        """
        let entries = indexGo(code)

        // Interface
        #expect(entries.contains { $0.name == "Shape" && $0.kind == .interface })

        // Structs
        #expect(entries.contains { $0.name == "Circle" && $0.kind == .struct })
        #expect(entries.contains { $0.name == "Rectangle" && $0.kind == .struct })

        // Circle methods
        let circleMethods = entries.filter { $0.kind == .method && $0.container == "Circle" }
        #expect(circleMethods.count == 2, "Expected 2 Circle methods, got \(circleMethods.count)")

        // Rectangle methods
        let rectMethods = entries.filter { $0.kind == .method && $0.container == "Rectangle" }
        #expect(rectMethods.count == 2, "Expected 2 Rectangle methods, got \(rectMethods.count)")
    }

    @Test func parsesGroupedTypeDeclaration() {
        let code = """
        package main

        type (
            ID     int
            Name   string
            Status int
        )

        func process(id ID, name Name) {}
        """
        let entries = indexGo(code)
        let types = entries.filter { $0.kind == .type }
        #expect(types.count == 3, "Expected 3 type aliases from grouped declaration, got \(types.count)")
        #expect(types.contains { $0.name == "ID" })
        #expect(types.contains { $0.name == "Name" })
        #expect(types.contains { $0.name == "Status" })
        #expect(entries.contains { $0.name == "process" && $0.kind == .function })
    }
}

// MARK: - Suite 3: Go Performance

@Suite("TreeSitterBackend — Go Performance")
struct TreeSitterGoPerformanceTests {

    @Test func goFileParsesUnder10ms() {
        var source = "package main\n\n"
        for i in 0..<5 {
            source += "type T\(i) struct {\n    Field int\n}\n\n"
            for j in 0..<6 {
                source += "func (t *T\(i)) Method\(j)() int { return \(j) }\n"
            }
            source += "\n"
        }
        for i in 0..<30 {
            source += "func fn\(i)(x int) int { return x + \(i) }\n"
        }

        let tmpDir = NSTemporaryDirectory() + "senkani-go-perf-\(UUID().uuidString)"
        let filePath = "perf_test.go"
        let fullPath = tmpDir + "/" + filePath
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        try? source.write(toFile: fullPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let clock = ContinuousClock()
        var entries: [IndexEntry] = []
        let elapsed = clock.measure {
            entries = (try? TreeSitterBackend.index(files: [filePath], language: "go", projectRoot: tmpDir)) ?? []
        }

        let ms = Double(elapsed.components.attoseconds) / 1e15
        // 5 structs + 30 methods + 30 functions = 65
        #expect(entries.count >= 60, "Should find >= 60 symbols, got \(entries.count)")
        #expect(ms < 10.0, "Parse should be under 10ms, was \(String(format: "%.2f", ms))ms")
    }

    @Test func goCoexistsWithOtherLanguages() {
        let goCode = """
        package main

        type App struct {}
        func (a *App) Run() {}
        func setup() {}
        """
        let jsCode = """
        function setup() { }
        class App { }
        """

        let tmpDir = NSTemporaryDirectory() + "senkani-go-coexist-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        try? goCode.write(toFile: tmpDir + "/main.go", atomically: true, encoding: .utf8)
        try? jsCode.write(toFile: tmpDir + "/app.js", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        // Parse Go first
        let goEntries = (try? TreeSitterBackend.index(files: ["main.go"], language: "go", projectRoot: tmpDir)) ?? []
        // Then JS
        let jsEntries = (try? TreeSitterBackend.index(files: ["app.js"], language: "javascript", projectRoot: tmpDir)) ?? []
        // Then Go again (proves no state leak)
        let goEntries2 = (try? TreeSitterBackend.index(files: ["main.go"], language: "go", projectRoot: tmpDir)) ?? []

        // Go should find: App (struct), Run (method on App), setup (function)
        #expect(goEntries.contains { $0.name == "App" && $0.kind == .struct })
        #expect(goEntries.contains { $0.name == "Run" && $0.kind == .method && $0.container == "App" })
        #expect(goEntries.contains { $0.name == "setup" && $0.kind == .function })

        // JS should find: setup (function), App (class)
        #expect(jsEntries.contains { $0.name == "setup" && $0.kind == .function })
        #expect(jsEntries.contains { $0.name == "App" && $0.kind == .class })

        // Second Go pass should match first
        #expect(goEntries2.count == goEntries.count, "Go should produce same results on re-parse")
        #expect(goEntries2.map(\.name).sorted() == goEntries.map(\.name).sorted())
    }
}

// MARK: - Helper

private func indexGo(_ code: String) -> [IndexEntry] {
    let tmpDir = NSTemporaryDirectory() + "senkani-go-test-\(UUID().uuidString)"
    let filePath = "test.go"
    let fullPath = tmpDir + "/" + filePath

    try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    try? code.write(toFile: fullPath, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }

    return (try? TreeSitterBackend.index(files: [filePath], language: "go", projectRoot: tmpDir)) ?? []
}
