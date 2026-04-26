import Foundation
import Testing
@testable import Indexer

// MARK: - C++ Parsing Tests

@Suite("TreeSitterBackend — C++ Parsing")
struct CppParsingTests {

    @Test("Free functions")
    func parsesFreeFunctions() {
        let source = """
        int add(int a, int b) {
            return a + b;
        }

        void noop() { }
        """
        let entries = indexCpp(source)
        #expect(entries.count == 2)
        #expect(entries[0].name == "add")
        #expect(entries[0].kind == .function)
        #expect(entries[0].container == nil)
        #expect(entries[1].name == "noop")
        #expect(entries[1].kind == .function)
        #expect(entries[1].container == nil)
    }

    @Test("Classes")
    func parsesClasses() {
        let source = """
        class Foo {
        public:
            void greet();
        };

        class Bar : public Foo {
        public:
            int count();
        };
        """
        let entries = indexCpp(source)
        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 2)
        #expect(classes[0].name == "Foo")
        #expect(classes[1].name == "Bar")

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 2)
        #expect(methods[0].container == "Foo")
        #expect(methods[1].container == "Bar")
    }

    @Test("Structs")
    func parsesStructs() {
        let source = """
        struct Point {
            int x;
            int y;
        };

        struct Empty { };
        """
        let entries = indexCpp(source)
        let structs = entries.filter { $0.kind == .struct }
        #expect(structs.count == 2)
        #expect(structs[0].name == "Point")
        #expect(structs[1].name == "Empty")
    }

    @Test("Enums")
    func parsesEnums() {
        let source = """
        enum Color { RED, GREEN, BLUE };
        enum class Status { Active, Inactive };
        """
        let entries = indexCpp(source)
        #expect(entries.count == 2)
        #expect(entries[0].name == "Color")
        #expect(entries[0].kind == .enum)
        #expect(entries[1].name == "Status")
        #expect(entries[1].kind == .enum)
    }

    @Test("In-class methods")
    func parsesInClassMethods() {
        let source = """
        class Service {
        public:
            void start() { }
            void stop() { }
        private:
            bool running = false;
        };
        """
        let entries = indexCpp(source)
        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 1)
        #expect(classes[0].name == "Service")

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 2)
        #expect(methods.allSatisfy { $0.container == "Service" })
        let names = Set(methods.map(\.name))
        #expect(names.contains("start"))
        #expect(names.contains("stop"))
    }

    @Test("Out-of-class methods")
    func parsesOutOfClassMethods() {
        let source = """
        class Renderer {
        public:
            void draw();
            void clear();
        };

        void Renderer::draw() {
            // implementation
        }

        void Renderer::clear() {
            // implementation
        }
        """
        let entries = indexCpp(source)
        let rendererEntries = entries.filter { $0.container == "Renderer" }
        // 2 in-class declarations + 2 out-of-class definitions
        #expect(rendererEntries.count == 4)
        #expect(rendererEntries.allSatisfy { $0.kind == .method })

        let drawEntries = rendererEntries.filter { $0.name == "draw" }
        #expect(drawEntries.count == 2)
        let clearEntries = rendererEntries.filter { $0.name == "clear" }
        #expect(clearEntries.count == 2)
    }

    @Test("Qualified name methods with pointer return")
    func parsesQualifiedNameMethods() {
        let source = """
        void MyClass::staticMethod() {
            // body
        }

        int *MyClass::pointerMethod() {
            return nullptr;
        }
        """
        let entries = indexCpp(source)
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.kind == .method })
        #expect(entries.allSatisfy { $0.container == "MyClass" })
        let names = Set(entries.map(\.name))
        #expect(names.contains("staticMethod"))
        #expect(names.contains("pointerMethod"))
    }

    @Test("Namespaces")
    func parsesNamespaces() {
        let source = """
        namespace foo {
            void bar() { }
            namespace nested {
                void baz() { }
            }
        }
        """
        let entries = indexCpp(source)
        let namespaces = entries.filter { $0.kind == .extension }
        #expect(namespaces.count == 2)
        #expect(namespaces[0].name == "foo")
        #expect(namespaces[1].name == "nested")

        let functions = entries.filter { $0.kind == .function }
        #expect(functions.count == 2)
        // Namespaces don't set container
        #expect(functions.allSatisfy { $0.container == nil })
    }

    @Test("Templates")
    func parsesTemplates() {
        let source = """
        template<typename T>
        class Vector {
        public:
            void push(T value) { }
        };

        template<typename T>
        T identity(T value) {
            return value;
        }
        """
        let entries = indexCpp(source)
        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 1)
        #expect(classes[0].name == "Vector")

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 1)
        #expect(methods[0].name == "push")
        #expect(methods[0].container == "Vector")

        let functions = entries.filter { $0.kind == .function }
        #expect(functions.count == 1)
        #expect(functions[0].name == "identity")
    }

    @Test("Using aliases")
    func parsesUsingAliases() {
        let source = """
        using StringList = int;
        using Callback = void(*)(int);
        """
        let entries = indexCpp(source)
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.kind == .type })
        let names = Set(entries.map(\.name))
        #expect(names.contains("StringList"))
        #expect(names.contains("Callback"))
    }

    @Test("Comments ignored")
    func handlesCommentsCorrectly() {
        let source = """
        // class Fake {};
        /* void fake_func() { } */
        void real() { }
        """
        let entries = indexCpp(source)
        #expect(entries.count == 1)
        #expect(entries[0].name == "real")
        #expect(entries[0].kind == .function)
    }
}

// MARK: - C++ Realistic Tests

@Suite("TreeSitterBackend — C++ Realistic")
struct CppRealisticTests {

    @Test("Realistic C++ file")
    func parsesRealisticCppFile() {
        let source = """
        namespace engine {

        enum class RenderMode { Wireframe, Solid, Textured };

        class Renderer {
        public:
            Renderer();
            void draw();
            void clear();
        private:
            int frameCount;
        };

        Renderer::Renderer() { }

        void Renderer::draw() {
            // draw implementation
        }

        void Renderer::clear() {
            // clear implementation
        }

        struct Vertex {
            float x, y, z;
        };

        template<typename T>
        T clamp(T value, T lo, T hi) {
            return value < lo ? lo : value > hi ? hi : value;
        }

        using Color = unsigned int;

        } // namespace engine
        """
        let entries = indexCpp(source)

        // namespace engine
        let namespaces = entries.filter { $0.kind == .extension }
        #expect(namespaces.count == 1)
        #expect(namespaces[0].name == "engine")

        // enum class RenderMode
        let enums = entries.filter { $0.kind == .enum }
        #expect(enums.count == 1)
        #expect(enums[0].name == "RenderMode")

        // class Renderer
        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 1)
        #expect(classes[0].name == "Renderer")

        // Renderer methods: 3 in-class declarations + 3 out-of-class definitions
        let rendererMethods = entries.filter { $0.container == "Renderer" }
        #expect(rendererMethods.count == 6)
        #expect(rendererMethods.allSatisfy { $0.kind == .method })

        // struct Vertex
        let structs = entries.filter { $0.kind == .struct }
        #expect(structs.count == 1)
        #expect(structs[0].name == "Vertex")

        // template function clamp
        let functions = entries.filter { $0.kind == .function }
        #expect(functions.count == 1)
        #expect(functions[0].name == "clamp")

        // using Color
        let types = entries.filter { $0.kind == .type }
        #expect(types.count == 1)
        #expect(types[0].name == "Color")

        // All entries from tree-sitter
        #expect(entries.allSatisfy { $0.engine == "tree-sitter" })
    }
}

// MARK: - C++ Performance Tests

@Suite("TreeSitterBackend — C++ Performance")
struct CppPerformanceTests {

    @Test("C++ file parses under 10ms")
    func cppFileParsesUnder10ms() {
        var source = ""
        for i in 0..<5 {
            source += "namespace ns\(i) {\n"
            source += "class Widget\(i) {\npublic:\n"
            for j in 0..<6 {
                source += "    void method\(j)() { }\n"
            }
            source += "};\n"
            source += "} // namespace\n\n"
        }
        for i in 0..<10 {
            source += "void free_func_\(i)(int x) { }\n"
        }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let entries = indexCpp(source)
            #expect(entries.count > 0)
        }
        #expect(elapsed < .milliseconds(10))
    }

    @Test("C++ coexists with C and Rust")
    func cppCoexistsWithOtherLanguages() {
        let tmpDir = NSTemporaryDirectory() + "senkani-cpp-coexist-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        // C file
        let cSource = "int add(int a, int b) { return a + b; }\n"
        try! cSource.write(toFile: tmpDir + "/math.c", atomically: true, encoding: .utf8)

        // C++ file
        let cppSource = "class Foo {\npublic:\n    void bar() { }\n};\n"
        try! cppSource.write(toFile: tmpDir + "/foo.cpp", atomically: true, encoding: .utf8)

        // Rust file
        let rsSource = "fn greet() {\n    println!(\"hello\");\n}\n"
        try! rsSource.write(toFile: tmpDir + "/lib.rs", atomically: true, encoding: .utf8)

        let cEntries = (try? TreeSitterBackend.index(files: ["math.c"], language: "c", projectRoot: tmpDir)) ?? []
        let cppEntries = (try? TreeSitterBackend.index(files: ["foo.cpp"], language: "cpp", projectRoot: tmpDir)) ?? []
        let rsEntries = (try? TreeSitterBackend.index(files: ["lib.rs"], language: "rust", projectRoot: tmpDir)) ?? []

        #expect(cEntries.count == 1)
        #expect(cEntries[0].name == "add")

        #expect(cppEntries.count == 2) // Foo class + bar method
        #expect(cppEntries.contains { $0.name == "Foo" && $0.kind == .class })
        #expect(cppEntries.contains { $0.name == "bar" && $0.kind == .method })

        #expect(rsEntries.count == 1)
        #expect(rsEntries[0].name == "greet")
    }
}

// MARK: - Helper

private func indexCpp(_ source: String) -> [IndexEntry] {
    let tmpDir = NSTemporaryDirectory() + "senkani-cpp-test-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }
    let file = "test.cpp"
    try! source.write(toFile: tmpDir + "/" + file, atomically: true, encoding: .utf8)
    return (try? TreeSitterBackend.index(files: [file], language: "cpp", projectRoot: tmpDir)) ?? []
}
