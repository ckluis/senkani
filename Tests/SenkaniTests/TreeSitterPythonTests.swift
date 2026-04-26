import Testing
import Foundation
@testable import Indexer

// MARK: - Suite 1: Correctness

@Suite("TreeSitterBackend — Python Parsing")
struct TreeSitterPythonParsingTests {

    @Test func parsesPythonFunctions() {
        let code = """
        def hello():
            pass

        async def world():
            return 42
        """
        let entries = indexPython(code)
        let funcs = entries.filter { $0.kind == .function }
        #expect(funcs.count == 2, "Expected 2 functions, got \(funcs.count)")
        #expect(funcs.contains { $0.name == "hello" })
        #expect(funcs.contains { $0.name == "world" })
    }

    @Test func parsesPythonClasses() {
        let code = """
        class Foo:
            pass

        class Bar(Foo):
            pass
        """
        let entries = indexPython(code)
        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 2, "Expected 2 classes, got \(classes.count)")
        #expect(classes.contains { $0.name == "Foo" })
        #expect(classes.contains { $0.name == "Bar" })
    }

    @Test func parsesClassMethods() {
        let code = """
        class MyClass:
            def __init__(self):
                pass
            def method(self):
                return 1
        """
        let entries = indexPython(code)
        #expect(entries.contains { $0.name == "MyClass" && $0.kind == .class })

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 2, "Expected 2 methods, got \(methods.count)")
        #expect(methods.contains { $0.name == "__init__" && $0.container == "MyClass" })
        #expect(methods.contains { $0.name == "method" && $0.container == "MyClass" })
    }

    @Test func decoratedFunctionsCountedOnce() {
        let code = """
        @property
        def name(self):
            return self._name

        @staticmethod
        def handler():
            pass
        """
        let entries = indexPython(code)
        let funcs = entries.filter { $0.kind == .function || $0.kind == .method }
        #expect(funcs.count == 2, "Decorated functions should produce exactly 2 entries, got \(funcs.count): \(funcs.map(\.name))")
        #expect(funcs.contains { $0.name == "name" })
        #expect(funcs.contains { $0.name == "handler" })
    }

    @Test func nestedClassesHandled() {
        let code = """
        class Outer:
            class Inner:
                def method(self):
                    pass
        """
        let entries = indexPython(code)
        #expect(entries.contains { $0.name == "Outer" && $0.kind == .class && $0.container == nil })
        #expect(entries.contains { $0.name == "Inner" && $0.kind == .class && $0.container == "Outer" })
        #expect(entries.contains { $0.name == "method" && $0.kind == .method && $0.container == "Inner" })
    }

    @Test func handlesCommentsCorrectly() {
        let code = """
        # def fake_function(): pass
        \"\"\"
        def also_fake(): pass
        \"\"\"
        def real():
            pass
        """
        let entries = indexPython(code)
        #expect(entries.count == 1, "Expected 1 entry (only 'real'), got \(entries.count): \(entries.map(\.name))")
        #expect(entries[0].name == "real")
    }

    @Test func handlesDocstrings() {
        let code = """
        def documented():
            \"\"\"This is a docstring\"\"\"
            return 42
        """
        let entries = indexPython(code)
        #expect(entries.count == 1)
        #expect(entries[0].name == "documented")
    }
}

// MARK: - Suite 2: Real Files

@Suite("TreeSitterBackend — Python Real Files")
struct TreeSitterPythonRealFileTests {

    @Test func parsesRealPythonFile() {
        let code = """
        import os
        from typing import List, Optional
        from dataclasses import dataclass

        @dataclass
        class Config:
            debug: bool = False
            verbose: bool = True
            max_retries: int = 3

        class UserService:
            def __init__(self, config: Config):
                self._config = config
                self._users: List[str] = []

            def add_user(self, name: str) -> bool:
                if name in self._users:
                    return False
                self._users.append(name)
                return True

            @property
            def user_count(self) -> int:
                return len(self._users)

            @staticmethod
            def validate_name(name: str) -> bool:
                return len(name) > 0

        def create_service(debug: bool = False) -> UserService:
            config = Config(debug=debug)
            return UserService(config)

        async def fetch_users(url: str) -> List[str]:
            pass

        if __name__ == "__main__":
            svc = create_service()
        """
        let entries = indexPython(code)

        // Should find: Config, UserService, __init__, add_user, user_count,
        //              validate_name, create_service, fetch_users
        let names = entries.map(\.name)
        #expect(entries.count >= 8, "Expected >= 8 symbols in real Python file, got \(entries.count): \(names)")
        #expect(entries.contains { $0.name == "Config" && $0.kind == .class })
        #expect(entries.contains { $0.name == "UserService" && $0.kind == .class })
        #expect(entries.contains { $0.name == "__init__" && $0.container == "UserService" })
        #expect(entries.contains { $0.name == "add_user" && $0.container == "UserService" })
        #expect(entries.contains { $0.name == "create_service" && $0.kind == .function })
        #expect(entries.contains { $0.name == "fetch_users" && $0.kind == .function })
        #expect(entries.allSatisfy { $0.engine == "tree-sitter" })
    }
}

// MARK: - Suite 3: Performance

@Suite("TreeSitterBackend — Python Performance")
struct TreeSitterPythonPerformanceTests {

    @Test func pythonFileParsesUnder5ms() {
        // Build a synthetic Python file with ~50 functions and 10 classes
        var source = ""
        for i in 0..<10 {
            source += "class MyClass\(i):\n"
            for j in 0..<5 {
                source += "    def method_\(i)_\(j)(self):\n"
                source += "        pass\n\n"
            }
            source += "\n"
        }

        let tmpDir = NSTemporaryDirectory() + "senkani-py-perf-\(UUID().uuidString)"
        let filePath = "perf_test.py"
        let fullPath = tmpDir + "/" + filePath
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        try? source.write(toFile: fullPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let clock = ContinuousClock()
        var entries: [IndexEntry] = []
        let elapsed = clock.measure {
            entries = (try? TreeSitterBackend.index(files: [filePath], language: "python", projectRoot: tmpDir)) ?? []
        }

        let ms = Double(elapsed.components.attoseconds) / 1e15
        #expect(entries.count >= 60, "Should find 10 classes + 50 methods, got \(entries.count)")
        #expect(ms < 5.0, "Parse should be under 5ms, was \(String(format: "%.2f", ms))ms")
    }

    @Test func pythonAndSwiftCoexist() {
        let swiftCode = """
        struct Point {
            var x: Double
            func distance() -> Double { return 0 }
        }
        """
        let pythonCode = """
        class Point:
            def __init__(self, x, y):
                self.x = x
            def distance(self):
                return 0
        """

        let tmpDir = NSTemporaryDirectory() + "senkani-coexist-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        try? swiftCode.write(toFile: tmpDir + "/test.swift", atomically: true, encoding: .utf8)
        try? pythonCode.write(toFile: tmpDir + "/test.py", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        // Parse Swift first
        let swiftEntries = (try? TreeSitterBackend.index(files: ["test.swift"], language: "swift", projectRoot: tmpDir)) ?? []
        // Then Python
        let pythonEntries = (try? TreeSitterBackend.index(files: ["test.py"], language: "python", projectRoot: tmpDir)) ?? []
        // Then Swift again (proves no state leak)
        let swiftEntries2 = (try? TreeSitterBackend.index(files: ["test.swift"], language: "swift", projectRoot: tmpDir)) ?? []

        // Swift should find: Point (struct), x (property), distance (method)
        #expect(swiftEntries.contains { $0.name == "Point" && $0.kind == .struct })
        #expect(swiftEntries.contains { $0.name == "distance" && $0.kind == .method })

        // Python should find: Point (class), __init__ (method), distance (method)
        #expect(pythonEntries.contains { $0.name == "Point" && $0.kind == .class })
        #expect(pythonEntries.contains { $0.name == "__init__" && $0.kind == .method })
        #expect(pythonEntries.contains { $0.name == "distance" && $0.kind == .method })

        // Second Swift pass should match first
        #expect(swiftEntries2.count == swiftEntries.count, "Swift should produce same results on re-parse")
        #expect(swiftEntries2.map(\.name) == swiftEntries.map(\.name))
    }
}

// MARK: - Helper

private func indexPython(_ code: String) -> [IndexEntry] {
    let tmpDir = NSTemporaryDirectory() + "senkani-py-test-\(UUID().uuidString)"
    let filePath = "test.py"
    let fullPath = tmpDir + "/" + filePath

    try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    try? code.write(toFile: fullPath, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }

    return (try? TreeSitterBackend.index(files: [filePath], language: "python", projectRoot: tmpDir)) ?? []
}
