import Testing
import Foundation
@testable import Indexer

// MARK: - Suite 1: Java Parsing

@Suite("TreeSitterBackend — Java Parsing")
struct TreeSitterJavaParsingTests {

    @Test func parsesClasses() {
        let code = """
        public class Foo { }
        class Bar extends Foo { }
        """
        let entries = indexJava(code)
        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 2, "Expected 2 classes, got \(classes.count)")
        #expect(classes.contains { $0.name == "Foo" })
        #expect(classes.contains { $0.name == "Bar" })
    }

    @Test func parsesInterfaces() {
        let code = """
        public interface Greeter {
            String greet();
        }
        interface Counter {
            int count();
        }
        """
        let entries = indexJava(code)
        let interfaces = entries.filter { $0.kind == .interface }
        #expect(interfaces.count == 2, "Expected 2 interfaces, got \(interfaces.count)")
        #expect(interfaces.contains { $0.name == "Greeter" })
        #expect(interfaces.contains { $0.name == "Counter" })
    }

    @Test func parsesEnums() {
        let code = """
        public enum Color { RED, GREEN, BLUE }
        enum Status { ACTIVE, INACTIVE }
        """
        let entries = indexJava(code)
        let enums = entries.filter { $0.kind == .enum }
        #expect(enums.count == 2, "Expected 2 enums, got \(enums.count)")
        #expect(enums.contains { $0.name == "Color" })
        #expect(enums.contains { $0.name == "Status" })
    }

    @Test func parsesRecords() {
        let code = """
        public record User(String name, int age) {}
        record Point(double x, double y) {}
        """
        let entries = indexJava(code)
        let records = entries.filter { $0.kind == .struct }
        #expect(records.count == 2, "Expected 2 records, got \(records.count)")
        #expect(records.contains { $0.name == "User" })
        #expect(records.contains { $0.name == "Point" })
    }

    @Test func parsesAnnotationTypes() {
        let code = """
        public @interface Audit {
            String value();
        }
        """
        let entries = indexJava(code)
        let annotations = entries.filter { $0.kind == .protocol }
        #expect(annotations.count == 1, "Expected 1 annotation type, got \(annotations.count)")
        #expect(annotations[0].name == "Audit")
    }

    @Test func parsesClassMethods() {
        let code = """
        public class Service {
            public String greet() { return "hi"; }
            private int count() { return 0; }
            public static Service create() { return new Service(); }
        }
        """
        let entries = indexJava(code)
        let classes = entries.filter { $0.kind == .class }
        let methods = entries.filter { $0.kind == .method }
        #expect(classes.count == 1)
        #expect(classes[0].name == "Service")
        #expect(methods.count == 3, "Expected 3 methods, got \(methods.count)")
        #expect(methods.allSatisfy { $0.container == "Service" })
        #expect(methods.contains { $0.name == "greet" })
        #expect(methods.contains { $0.name == "count" })
        #expect(methods.contains { $0.name == "create" })
    }

    @Test func parsesConstructors() {
        let code = """
        public class User {
            private String name;
            public User() {}
            public User(String name) { this.name = name; }
        }
        """
        let entries = indexJava(code)
        let classes = entries.filter { $0.kind == .class }
        let constructors = entries.filter { $0.kind == .method && $0.name == "User" }
        #expect(classes.count == 1)
        #expect(constructors.count == 2, "Expected 2 constructors, got \(constructors.count)")
        #expect(constructors.allSatisfy { $0.container == "User" })
    }

    @Test func parsesNestedClasses() {
        let code = """
        public class Outer {
            public class Inner {
                public void method() {}
            }
            public static class StaticNested {
                public void other() {}
            }
        }
        """
        let entries = indexJava(code)

        // Outer class
        #expect(entries.contains { $0.name == "Outer" && $0.kind == .class && $0.container == nil })

        // Inner class with container Outer
        #expect(entries.contains { $0.name == "Inner" && $0.kind == .class && $0.container == "Outer" })

        // method with container Inner
        #expect(entries.contains { $0.name == "method" && $0.kind == .method && $0.container == "Inner" })

        // StaticNested with container Outer
        #expect(entries.contains { $0.name == "StaticNested" && $0.kind == .class && $0.container == "Outer" })

        // other with container StaticNested
        #expect(entries.contains { $0.name == "other" && $0.kind == .method && $0.container == "StaticNested" })
    }

    @Test func nestedMethodsResolveToInnermostContainer() {
        let code = """
        public class Service {
            public class Builder {
                public Builder withName(String name) { return this; }
            }
        }
        """
        let entries = indexJava(code)
        let withName = entries.filter { $0.name == "withName" }
        #expect(withName.count == 1, "Expected 1 withName method, got \(withName.count)")
        #expect(withName[0].container == "Builder",
                "Container should be Builder (innermost), got \(withName[0].container ?? "nil")")
    }

    @Test func handlesCommentsCorrectly() {
        let code = """
        // public class Fake {}
        /* interface FakeIface {} */
        public class Real {}
        """
        let entries = indexJava(code)
        #expect(entries.count == 1, "Expected 1 entry (only 'Real'), got \(entries.count)")
        #expect(entries[0].name == "Real")
    }
}

// MARK: - Suite 2: Java Realistic

@Suite("TreeSitterBackend — Java Realistic")
struct TreeSitterJavaRealisticTests {

    @Test func parsesRealisticJavaFile() {
        let code = """
        package com.example.app;

        import java.util.List;

        public class UserService {
            private final List<String> users;

            public UserService() {
                this.users = new ArrayList<>();
            }

            public void addUser(String name) {
                users.add(name);
            }

            public String getUser(int index) {
                return users.get(index);
            }

            public int count() {
                return users.size();
            }

            public static class Builder {
                public Builder withCapacity(int cap) { return this; }
                public UserService build() { return new UserService(); }
            }
        }

        public record UserDTO(String name, int age) {}

        public enum Role { ADMIN, USER, GUEST }
        """
        let entries = indexJava(code)

        // UserService class
        #expect(entries.contains { $0.name == "UserService" && $0.kind == .class },
                "Should find UserService class")

        // Constructor
        #expect(entries.contains { $0.name == "UserService" && $0.kind == .method && $0.container == "UserService" },
                "Should find UserService constructor")

        // Methods on UserService
        let serviceMethods = entries.filter { $0.kind == .method && $0.container == "UserService" }
        let methodNames = serviceMethods.map(\.name)
        #expect(methodNames.contains("addUser"))
        #expect(methodNames.contains("getUser"))
        #expect(methodNames.contains("count"))

        // Nested Builder class
        #expect(entries.contains { $0.name == "Builder" && $0.kind == .class && $0.container == "UserService" },
                "Should find nested Builder class")

        // Builder methods
        let builderMethods = entries.filter { $0.kind == .method && $0.container == "Builder" }
        #expect(builderMethods.count == 2, "Expected 2 Builder methods, got \(builderMethods.count)")

        // Record
        #expect(entries.contains { $0.name == "UserDTO" && $0.kind == .struct },
                "Should find UserDTO record")

        // Enum
        #expect(entries.contains { $0.name == "Role" && $0.kind == .enum },
                "Should find Role enum")

        // All tree-sitter
        #expect(entries.allSatisfy { $0.engine == "tree-sitter" })
    }
}

// MARK: - Suite 3: Java Performance

@Suite("TreeSitterBackend — Java Performance")
struct TreeSitterJavaPerformanceTests {

    @Test func javaFileParsesUnder10ms() {
        var source = ""
        for i in 0..<5 {
            source += "public class C\(i) {\n"
            for j in 0..<6 {
                source += "    public int method\(j)() { return \(j); }\n"
            }
            source += "    public static class Nested\(i) {\n"
            source += "        public void inner() {}\n"
            source += "    }\n"
            source += "}\n\n"
        }

        let tmpDir = NSTemporaryDirectory() + "senkani-java-perf-\(UUID().uuidString)"
        let filePath = "PerfTest.java"
        let fullPath = tmpDir + "/" + filePath
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        try? source.write(toFile: fullPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let clock = ContinuousClock()
        var entries: [IndexEntry] = []
        let elapsed = clock.measure {
            entries = TreeSitterBackend.index(files: [filePath], language: "java", projectRoot: tmpDir)
        }

        let ms = Double(elapsed.components.attoseconds) / 1e15
        // 5 classes + 30 methods + 5 nested classes + 5 inner methods = 45
        #expect(entries.count >= 40, "Should find >= 40 symbols, got \(entries.count)")
        #expect(ms < 10.0, "Parse should be under 10ms, was \(String(format: "%.2f", ms))ms")
    }

    @Test func javaCoexistsWithOtherLanguages() {
        let rustCode = """
        struct App { running: bool }
        impl App {
            fn run(&self) {}
        }
        fn setup() {}
        """
        let javaCode = """
        public class App {
            public void run() {}
            public static App setup() { return new App(); }
        }
        """
        let tsCode = """
        interface Config { debug: boolean; }
        class App {
            run(): void {}
        }
        function setup(): void {}
        """

        let tmpDir = NSTemporaryDirectory() + "senkani-java-coexist-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        try? rustCode.write(toFile: tmpDir + "/lib.rs", atomically: true, encoding: .utf8)
        try? javaCode.write(toFile: tmpDir + "/App.java", atomically: true, encoding: .utf8)
        try? tsCode.write(toFile: tmpDir + "/app.ts", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        // Parse Rust
        let rustEntries = TreeSitterBackend.index(files: ["lib.rs"], language: "rust", projectRoot: tmpDir)
        // Then Java
        let javaEntries = TreeSitterBackend.index(files: ["App.java"], language: "java", projectRoot: tmpDir)
        // Then TypeScript
        let tsEntries = TreeSitterBackend.index(files: ["app.ts"], language: "typescript", projectRoot: tmpDir)
        // Then Java again (proves no state leak)
        let javaEntries2 = TreeSitterBackend.index(files: ["App.java"], language: "java", projectRoot: tmpDir)

        // Rust
        #expect(rustEntries.contains { $0.name == "App" && $0.kind == .struct })
        #expect(rustEntries.contains { $0.name == "run" && $0.kind == .method })
        #expect(rustEntries.contains { $0.name == "setup" && $0.kind == .function })

        // Java
        #expect(javaEntries.contains { $0.name == "App" && $0.kind == .class })
        #expect(javaEntries.contains { $0.name == "run" && $0.kind == .method && $0.container == "App" })
        #expect(javaEntries.contains { $0.name == "setup" && $0.kind == .method && $0.container == "App" })

        // TypeScript
        #expect(tsEntries.contains { $0.name == "Config" && $0.kind == .interface })
        #expect(tsEntries.contains { $0.name == "App" && $0.kind == .class })
        #expect(tsEntries.contains { $0.name == "setup" && $0.kind == .function })

        // Second Java pass should match first
        #expect(javaEntries2.count == javaEntries.count, "Java should produce same results on re-parse")
        #expect(javaEntries2.map(\.name).sorted() == javaEntries.map(\.name).sorted())
    }
}

// MARK: - Helper

private func indexJava(_ code: String) -> [IndexEntry] {
    let tmpDir = NSTemporaryDirectory() + "senkani-java-test-\(UUID().uuidString)"
    let filePath = "Test.java"
    let fullPath = tmpDir + "/" + filePath

    try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    try? code.write(toFile: fullPath, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }

    return TreeSitterBackend.index(files: [filePath], language: "java", projectRoot: tmpDir)
}
