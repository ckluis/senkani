import Foundation
import Testing
@testable import Indexer

// MARK: - C Parsing Tests

@Suite("C Parsing")
struct CParsingTests {

    @Test("Simple function definition")
    func testSimpleFunction() {
        let source = """
        int add(int a, int b) {
            return a + b;
        }
        """
        let entries = index(source)
        #expect(entries.count == 1)
        #expect(entries[0].name == "add")
        #expect(entries[0].kind == .function)
        #expect(entries[0].container == nil)
    }

    @Test("Void function with no params")
    func testVoidFunction() {
        let source = """
        void noop(void) {
        }
        """
        let entries = index(source)
        #expect(entries.count == 1)
        #expect(entries[0].name == "noop")
        #expect(entries[0].kind == .function)
    }

    @Test("Function prototype (forward declaration)")
    func testFunctionPrototype() {
        let source = """
        void foo(int x);
        """
        let entries = index(source)
        #expect(entries.count == 1)
        #expect(entries[0].name == "foo")
        #expect(entries[0].kind == .function)
        #expect(entries[0].container == nil)
    }

    @Test("Pointer-returning function definition")
    func testPointerReturnFunction() {
        let source = """
        int *find(int *arr, int len) {
            return &arr[0];
        }
        """
        let entries = index(source)
        #expect(entries.count == 1)
        #expect(entries[0].name == "find")
        #expect(entries[0].kind == .function)
    }

    @Test("Pointer-returning function prototype")
    func testPointerReturnPrototype() {
        let source = """
        char *strdup(const char *s);
        """
        let entries = index(source)
        #expect(entries.count == 1)
        #expect(entries[0].name == "strdup")
        #expect(entries[0].kind == .function)
    }

    @Test("Struct definition")
    func testStructDefinition() {
        let source = """
        struct Point {
            int x;
            int y;
        };
        """
        let entries = index(source)
        #expect(entries.count == 1)
        #expect(entries[0].name == "Point")
        #expect(entries[0].kind == .struct)
    }

    @Test("Union definition")
    func testUnionDefinition() {
        let source = """
        union Value {
            int i;
            float f;
        };
        """
        let entries = index(source)
        #expect(entries.count == 1)
        #expect(entries[0].name == "Value")
        #expect(entries[0].kind == .struct)
    }

    @Test("Enum definition")
    func testEnumDefinition() {
        let source = """
        enum Color {
            RED,
            GREEN,
            BLUE
        };
        """
        let entries = index(source)
        #expect(entries.count == 1)
        #expect(entries[0].name == "Color")
        #expect(entries[0].kind == .enum)
    }

    @Test("Simple typedef")
    func testSimpleTypedef() {
        let source = """
        typedef unsigned int uint32;
        """
        let entries = index(source)
        #expect(entries.count == 1)
        #expect(entries[0].name == "uint32")
        #expect(entries[0].kind == .type)
    }

    @Test("Typedef struct (anonymous struct with typedef name)")
    func testTypedefStruct() {
        let source = """
        typedef struct {
            int x;
            int y;
        } Point;
        """
        let entries = index(source)
        #expect(entries.count == 1)
        #expect(entries[0].name == "Point")
        #expect(entries[0].kind == .type)
    }
}

// MARK: - C Realistic Tests

@Suite("C Realistic")
struct CRealisticTests {

    @Test("Realistic C header file")
    func testCHeaderFile() {
        let source = """
        typedef unsigned int my_size_t;

        struct Buffer {
            char *data;
            my_size_t len;
            my_size_t cap;
        };

        typedef struct {
            int x;
            int y;
        } Point;

        enum LogLevel {
            LOG_DEBUG,
            LOG_INFO,
            LOG_WARN,
            LOG_ERROR
        };

        void buffer_init(struct Buffer *buf);
        void buffer_free(struct Buffer *buf);
        char *buffer_to_string(struct Buffer *buf);
        int point_distance(Point a, Point b);
        """
        let entries = index(source)
        // my_size_t typedef, Buffer struct, Point typedef, LogLevel enum, 4 prototypes
        #expect(entries.count == 8)

        let functions = entries.filter { $0.kind == .function }
        #expect(functions.count == 4)
        let names = Set(functions.map(\.name))
        #expect(names.contains("buffer_init"))
        #expect(names.contains("buffer_free"))
        #expect(names.contains("buffer_to_string"))
        #expect(names.contains("point_distance"))

        let structs = entries.filter { $0.kind == .struct }
        #expect(structs.count == 1)
        #expect(structs[0].name == "Buffer")

        let enums = entries.filter { $0.kind == .enum }
        #expect(enums.count == 1)
        #expect(enums[0].name == "LogLevel")

        let types = entries.filter { $0.kind == .type }
        #expect(types.count == 2)

        // All C symbols should have no container
        for entry in entries {
            #expect(entry.container == nil)
        }
    }
}

// MARK: - C Performance Tests

@Suite("C Performance")
struct CPerformanceTests {

    @Test("Empty file returns no entries")
    func testEmptyFile() {
        let entries = index("")
        #expect(entries.count == 0)
    }

    @Test("Large file with many functions")
    func testLargeFile() {
        var lines: [String] = []
        for i in 0..<200 {
            lines.append("int func_\(i)(int x) { return x + \(i); }")
        }
        let source = lines.joined(separator: "\n")
        let entries = index(source)
        #expect(entries.count == 200)
        #expect(entries.allSatisfy { $0.kind == .function })
        #expect(entries.allSatisfy { $0.container == nil })
    }
}

// MARK: - C Depth-Stress Tests

@Suite("TreeSitterBackend — C Depth Stress")
struct TreeSitterCDepthStressTests {

    // Chain child of `indexer-backends-iterative-walk-refactor-2026-05-11`.
    // Generates a top-level variable declaration whose initializer is
    // a deeply-nested parenthesized-expression chain, and indexes the
    // file WITHOUT `runOnLargeStackThread` to prove the iterative walk
    // is cooperative-pool-safe. Two function prototypes bracket the
    // deep expression to assert pre-order symbol emission.
    //
    // Why parenthesized expressions, not compound statements: in C the
    // `function_definition` switch arm extracts and returns without
    // walking the function body, so depth inside `{...}` is not
    // walked. The deep chain must live inside a `declaration` (no
    // function declarator → recurses children) whose descendants fall
    // into the `default` arm. The pre-refactor walk would consume
    // ~2200 Swift call frames descending the parenthesized_expression
    // chain and crash on the cooperative pool's smaller stack. The
    // iterative form runs in heap-allocated work-stack memory.
    @Test("Depth-stress iterative walk does not overflow")
    func testDepthStressIterative() {
        let depth = 2200
        let opens = String(repeating: "(", count: depth)
        let closes = String(repeating: ")", count: depth)
        let source = """
        int first(void);

        int x = \(opens)0\(closes);

        int last(void);
        """

        let entries = index(source)
        let funcs = entries.filter { $0.kind == .function }
        #expect(funcs.map(\.name) == ["first", "last"],
                "Symbol order must remain left-to-right pre-order")
        #expect(funcs.allSatisfy { $0.container == nil },
                "Top-level C function prototypes carry no container")
    }
}

// MARK: - Helper

private func index(_ source: String) -> [IndexEntry] {
    let tmpDir = NSTemporaryDirectory() + "senkani-c-test-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }
    let file = "test.c"
    try! source.write(toFile: tmpDir + "/" + file, atomically: true, encoding: .utf8)
    return (try? TreeSitterBackend.index(files: [file], language: "c", projectRoot: tmpDir)) ?? []
}
