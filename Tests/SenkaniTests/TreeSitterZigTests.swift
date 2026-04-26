import Foundation
import Testing
@testable import Indexer

// MARK: - Zig Parsing Tests

@Suite("TreeSitterBackend — Zig Parsing")
struct ZigParsingTests {

    @Test("Top-level functions")
    func parsesTopLevelFunctions() {
        let source = """
        fn add(a: i32, b: i32) i32 {
            return a + b;
        }

        pub fn main() void {
            return;
        }
        """
        let entries = indexZig(source)
        let fns = entries.filter { $0.kind == .function }
        #expect(fns.count == 2)
        let names = Set(fns.map(\.name))
        #expect(names.contains("add"))
        #expect(names.contains("main"))
        #expect(fns.allSatisfy { $0.container == nil })
    }

    @Test("Struct types")
    func parsesStructTypes() {
        let source = """
        const Point = struct {
            x: f32,
            y: f32,
        };

        const Empty = struct {};
        """
        let entries = indexZig(source)
        let structs = entries.filter { $0.kind == .struct }
        #expect(structs.count == 2)
        let names = Set(structs.map(\.name))
        #expect(names.contains("Point"))
        #expect(names.contains("Empty"))
    }

    @Test("Enum types")
    func parsesEnumTypes() {
        let source = """
        const Color = enum {
            red,
            green,
            blue,
        };

        const Status = enum(u8) {
            active = 1,
            inactive = 0,
        };
        """
        let entries = indexZig(source)
        let enums = entries.filter { $0.kind == .enum }
        #expect(enums.count == 2)
        let names = Set(enums.map(\.name))
        #expect(names.contains("Color"))
        #expect(names.contains("Status"))
    }

    @Test("Union types")
    func parsesUnionTypes() {
        let source = """
        const Value = union(enum) {
            int: i32,
            float: f32,
            string: []const u8,
        };
        """
        let entries = indexZig(source)
        let structs = entries.filter { $0.kind == .struct }
        #expect(structs.count == 1)
        #expect(structs[0].name == "Value")
    }

    @Test("Struct methods")
    func parsesStructMethods() {
        let source = """
        const Counter = struct {
            count: i32,

            fn increment(self: *Counter) void {
                self.count += 1;
            }

            fn reset(self: *Counter) void {
                self.count = 0;
            }
        };
        """
        let entries = indexZig(source)

        let structs = entries.filter { $0.kind == .struct }
        #expect(structs.count == 1)
        #expect(structs[0].name == "Counter")

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 2)
        #expect(methods.allSatisfy { $0.container == "Counter" })
        let names = Set(methods.map(\.name))
        #expect(names.contains("increment"))
        #expect(names.contains("reset"))
    }

    @Test("Struct fields")
    func parsesStructFields() {
        let source = """
        const User = struct {
            name: []const u8,
            age: u32,
            email: ?[]const u8,
        };
        """
        let entries = indexZig(source)

        let structs = entries.filter { $0.kind == .struct }
        #expect(structs.count == 1)
        #expect(structs[0].name == "User")

        let props = entries.filter { $0.kind == .property }
        #expect(props.count == 3)
        #expect(props.allSatisfy { $0.container == "User" })
        let names = Set(props.map(\.name))
        #expect(names.contains("name"))
        #expect(names.contains("age"))
        #expect(names.contains("email"))
    }

    @Test("Nested structs and methods")
    func parsesNestedStructsAndMethods() {
        let source = """
        const Outer = struct {
            const Inner = struct {
                value: i32,

                fn get(self: *Inner) i32 {
                    return self.value;
                }
            };

            fn outerMethod(self: *Outer) void {
                return;
            }
        };
        """
        let entries = indexZig(source)

        // Outer struct
        let outer = entries.filter { $0.name == "Outer" && $0.kind == .struct }
        #expect(outer.count == 1)
        #expect(outer[0].container == nil)

        // Inner struct nested in Outer
        let inner = entries.filter { $0.name == "Inner" && $0.kind == .struct }
        #expect(inner.count == 1)
        #expect(inner[0].container == "Outer")

        // Inner's field
        let value = entries.filter { $0.name == "value" && $0.kind == .property }
        #expect(value.count == 1)
        #expect(value[0].container == "Inner")

        // Inner's method
        let get = entries.filter { $0.name == "get" && $0.kind == .method }
        #expect(get.count == 1)
        #expect(get[0].container == "Inner")

        // Outer's method
        let outerMethod = entries.filter { $0.name == "outerMethod" && $0.kind == .method }
        #expect(outerMethod.count == 1)
        #expect(outerMethod[0].container == "Outer")
    }

    @Test("Test blocks")
    func parsesTestBlocks() {
        let source = """
        fn add(a: i32, b: i32) i32 {
            return a + b;
        }

        test "add returns sum" {
            return;
        }

        test "empty test" {}
        """
        let entries = indexZig(source)
        let tests = entries.filter { $0.name != "add" && $0.kind == .function }
        #expect(tests.count == 2)
        // Test names are extracted from string literals
        let testNames = Set(tests.map(\.name))
        #expect(testNames.contains("add returns sum"))
        #expect(testNames.contains("empty test"))
        #expect(tests.allSatisfy { $0.container == nil })
    }

    @Test("Skips top-level constants")
    func skipsTopLevelConstants() {
        let source = """
        const std = @import("std");
        const MAX_SIZE: u32 = 1024;
        const pi: f64 = 3.14159;

        fn use_constants() void {
            return;
        }
        """
        let entries = indexZig(source)
        #expect(entries.count == 1)
        #expect(entries[0].name == "use_constants")
        #expect(entries[0].kind == .function)
        // None of the const bindings should produce entries
        #expect(!entries.contains { $0.name == "std" })
        #expect(!entries.contains { $0.name == "MAX_SIZE" })
        #expect(!entries.contains { $0.name == "pi" })
    }

    @Test("Comments ignored")
    func handlesCommentsCorrectly() {
        let source = """
        // fn fake() void {}
        // const FakeStruct = struct {};

        fn real() void {
            return;
        }
        """
        let entries = indexZig(source)
        #expect(entries.count == 1)
        #expect(entries[0].name == "real")
        #expect(entries[0].kind == .function)
    }
}

// MARK: - Zig Realistic Tests

@Suite("TreeSitterBackend — Zig Realistic")
struct ZigRealisticTests {

    @Test("Realistic Zig file")
    func parsesRealisticZigFile() {
        let source = """
        const std = @import("std");
        const Allocator = std.mem.Allocator;
        const ArrayList = std.ArrayList;

        const Config = struct {
            max_retries: u32,
            timeout_ms: u64,
            debug: bool,

            fn init() Config {
                return Config{
                    .max_retries = 3,
                    .timeout_ms = 5000,
                    .debug = false,
                };
            }

            fn withDebug(self: Config) Config {
                var copy = self;
                copy.debug = true;
                return copy;
            }
        };

        const Logger = struct {
            level: u8,

            fn info(self: *Logger, msg: []const u8) void {
                _ = self;
                _ = msg;
            }

            fn warn(self: *Logger, msg: []const u8) void {
                _ = self;
                _ = msg;
            }
        };

        const Status = enum {
            running,
            stopped,
            error_state,
        };

        fn createLogger() Logger {
            return Logger{ .level = 0 };
        }

        fn processConfig(config: Config) void {
            _ = config;
        }

        test "Config init" {
            const config = Config.init();
            try std.testing.expectEqual(@as(u32, 3), config.max_retries);
        }

        test "Logger creation" {
            const logger = createLogger();
            try std.testing.expectEqual(@as(u8, 0), logger.level);
        }
        """
        let entries = indexZig(source)

        // Struct types: Config, Logger
        let structs = entries.filter { $0.kind == .struct }
        #expect(structs.count == 2)
        let structNames = Set(structs.map(\.name))
        #expect(structNames.contains("Config"))
        #expect(structNames.contains("Logger"))

        // Enum: Status
        let enums = entries.filter { $0.kind == .enum }
        #expect(enums.count == 1)
        #expect(enums[0].name == "Status")

        // Config methods: init, withDebug
        let configMethods = entries.filter { $0.kind == .method && $0.container == "Config" }
        #expect(configMethods.count == 2)
        let configMethodNames = Set(configMethods.map(\.name))
        #expect(configMethodNames.contains("init"))
        #expect(configMethodNames.contains("withDebug"))

        // Logger methods: info, warn
        let loggerMethods = entries.filter { $0.kind == .method && $0.container == "Logger" }
        #expect(loggerMethods.count == 2)

        // Config fields: max_retries, timeout_ms, debug
        let configFields = entries.filter { $0.kind == .property && $0.container == "Config" }
        #expect(configFields.count == 3)

        // Logger field: level
        let loggerFields = entries.filter { $0.kind == .property && $0.container == "Logger" }
        #expect(loggerFields.count == 1)

        // Top-level functions: createLogger, processConfig
        let topFns = entries.filter { $0.kind == .function && $0.container == nil }
        // 2 real functions + 2 test blocks = 4
        #expect(topFns.count == 4)
        let fnNames = Set(topFns.map(\.name))
        #expect(fnNames.contains("createLogger"))
        #expect(fnNames.contains("processConfig"))
        #expect(fnNames.contains("Config init"))
        #expect(fnNames.contains("Logger creation"))

        // Top-level imports should NOT produce entries
        #expect(!entries.contains { $0.name == "std" })
        #expect(!entries.contains { $0.name == "Allocator" && $0.kind != .struct })
        #expect(!entries.contains { $0.name == "ArrayList" })

        // All from tree-sitter
        #expect(entries.allSatisfy { $0.engine == "tree-sitter" })
    }
}

// MARK: - Zig Performance Tests

@Suite("TreeSitterBackend — Zig Performance")
struct ZigPerformanceTests {

    @Test("Zig file parses under 10ms")
    func zigFileParsesUnder10ms() {
        var source = "const std = @import(\"std\");\n\n"
        for i in 0..<5 {
            source += "const Type_\(i) = struct {\n"
            source += "    value: i32,\n"
            for j in 0..<5 {
                source += "    fn method_\(j)(self: *Type_\(i)) void { _ = self; }\n"
            }
            source += "};\n\n"
        }
        for i in 0..<10 {
            source += "fn func_\(i)(x: i32) i32 { return x + \(i); }\n"
        }
        for i in 0..<5 {
            source += "test \"test_\(i)\" {}\n"
        }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let entries = indexZig(source)
            #expect(entries.count > 0)
        }
        #expect(elapsed < .milliseconds(10))
    }

    @Test("Zig coexists with other languages")
    func zigCoexistsWithOtherLanguages() {
        let tmpDir = NSTemporaryDirectory() + "senkani-zig-coexist-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        // Zig file
        let zigSource = "const Greeter = struct {\n    fn greet() void {}\n};\n"
        try! zigSource.write(toFile: tmpDir + "/greeter.zig", atomically: true, encoding: .utf8)

        // Haskell file
        let haskellSource = "module Main where\n\ngreet :: String -> String\ngreet name = \"hi, \" ++ name\n"
        try! haskellSource.write(toFile: tmpDir + "/Main.hs", atomically: true, encoding: .utf8)

        // Rust file
        let rustSource = "struct Greeter;\nimpl Greeter {\n    fn greet(&self) {}\n}\n"
        try! rustSource.write(toFile: tmpDir + "/greeter.rs", atomically: true, encoding: .utf8)

        let zigEntries = (try? TreeSitterBackend.index(files: ["greeter.zig"], language: "zig", projectRoot: tmpDir)) ?? []
        let haskellEntries = (try? TreeSitterBackend.index(files: ["Main.hs"], language: "haskell", projectRoot: tmpDir)) ?? []
        let rustEntries = (try? TreeSitterBackend.index(files: ["greeter.rs"], language: "rust", projectRoot: tmpDir)) ?? []

        // Zig: struct Greeter + method greet = 2
        #expect(zigEntries.count == 2)
        #expect(zigEntries.contains { $0.name == "Greeter" && $0.kind == .struct })
        #expect(zigEntries.contains { $0.name == "greet" && $0.kind == .method })

        // Haskell: function greet = 1
        #expect(haskellEntries.count == 1)
        #expect(haskellEntries.contains { $0.name == "greet" && $0.kind == .function })

        // Rust: struct Greeter + method greet = 2
        #expect(rustEntries.count == 2)
        #expect(rustEntries.contains { $0.name == "Greeter" && $0.kind == .struct })
    }
}

// MARK: - Helper

private func indexZig(_ source: String) -> [IndexEntry] {
    let tmpDir = NSTemporaryDirectory() + "senkani-zig-test-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }
    let file = "test.zig"
    try! source.write(toFile: tmpDir + "/" + file, atomically: true, encoding: .utf8)
    return (try? TreeSitterBackend.index(files: [file], language: "zig", projectRoot: tmpDir)) ?? []
}
