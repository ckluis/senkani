import Foundation
import Testing
@testable import Indexer

// MARK: - C# Parsing Tests

@Suite("TreeSitterBackend — C# Parsing")
struct CSharpParsingTests {

    @Test("Classes")
    func parsesClasses() {
        let source = """
        public class Foo { }
        internal class Bar : Foo { }
        """
        let entries = indexCSharp(source)
        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 2)
        #expect(classes[0].name == "Foo")
        #expect(classes[1].name == "Bar")
    }

    @Test("Interfaces")
    func parsesInterfaces() {
        let source = """
        public interface IGreeter {
            string Greet();
        }
        interface ICounter {
            int Count();
        }
        """
        let entries = indexCSharp(source)
        let interfaces = entries.filter { $0.kind == .interface }
        #expect(interfaces.count == 2)
        #expect(interfaces[0].name == "IGreeter")
        #expect(interfaces[1].name == "ICounter")
    }

    @Test("Structs")
    func parsesStructs() {
        let source = """
        public struct Point {
            public int X;
            public int Y;
        }
        struct Empty { }
        """
        let entries = indexCSharp(source)
        let structs = entries.filter { $0.kind == .struct }
        #expect(structs.count == 2)
        #expect(structs[0].name == "Point")
        #expect(structs[1].name == "Empty")
    }

    @Test("Records")
    func parsesRecords() {
        let source = """
        public record User(string Name, int Age);
        record struct Point(double X, double Y);
        """
        let entries = indexCSharp(source)
        let records = entries.filter { $0.kind == .struct }
        #expect(records.count == 2)
        #expect(records[0].name == "User")
        #expect(records[1].name == "Point")
    }

    @Test("Enums")
    func parsesEnums() {
        let source = """
        public enum Color { Red, Green, Blue }
        enum Status { Active, Inactive }
        """
        let entries = indexCSharp(source)
        let enums = entries.filter { $0.kind == .enum }
        #expect(enums.count == 2)
        #expect(enums[0].name == "Color")
        #expect(enums[1].name == "Status")
    }

    @Test("Class methods and properties")
    func parsesClassMethodsAndProperties() {
        let source = """
        public class User {
            public string Name { get; set; }
            public int Age { get; private set; }
            public string Greet() { return "hi"; }
        }
        """
        let entries = indexCSharp(source)

        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 1)
        #expect(classes[0].name == "User")

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 1)
        #expect(methods[0].name == "Greet")
        #expect(methods[0].container == "User")

        let props = entries.filter { $0.kind == .property }
        #expect(props.count == 2)
        #expect(props.allSatisfy { $0.container == "User" })
        let propNames = Set(props.map(\.name))
        #expect(propNames.contains("Name"))
        #expect(propNames.contains("Age"))
    }

    @Test("Constructors")
    func parsesConstructors() {
        let source = """
        public class User {
            private string _name;
            public User() { }
            public User(string name) { _name = name; }
        }
        """
        let entries = indexCSharp(source)

        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 1)
        #expect(classes[0].name == "User")

        let ctors = entries.filter { $0.kind == .method && $0.name == "User" }
        #expect(ctors.count == 2)
        #expect(ctors.allSatisfy { $0.container == "User" })
    }

    @Test("Destructors")
    func parsesDestructors() {
        let source = """
        public class FileHandle {
            public FileHandle() { }
            ~FileHandle() { }
        }
        """
        let entries = indexCSharp(source)

        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 1)
        #expect(classes[0].name == "FileHandle")

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 2)
        #expect(methods.allSatisfy { $0.container == "FileHandle" })
        // Both constructor and destructor share the class name
        #expect(methods.allSatisfy { $0.name == "FileHandle" })
    }

    @Test("Nested classes")
    func parsesNestedClasses() {
        let source = """
        public class Outer {
            public class Inner {
                public void Method() { }
            }
            public static class StaticNested {
                public static void Other() { }
            }
        }
        """
        let entries = indexCSharp(source)

        let outer = entries.filter { $0.name == "Outer" && $0.kind == .class }
        #expect(outer.count == 1)
        #expect(outer[0].container == nil)

        let inner = entries.filter { $0.name == "Inner" && $0.kind == .class }
        #expect(inner.count == 1)
        #expect(inner[0].container == "Outer")

        let method = entries.filter { $0.name == "Method" }
        #expect(method.count == 1)
        #expect(method[0].container == "Inner")

        let staticNested = entries.filter { $0.name == "StaticNested" && $0.kind == .class }
        #expect(staticNested.count == 1)
        #expect(staticNested[0].container == "Outer")

        let other = entries.filter { $0.name == "Other" }
        #expect(other.count == 1)
        #expect(other[0].container == "StaticNested")
    }

    @Test("Namespaces")
    func parsesNamespaces() {
        let source = """
        namespace Acme.Web {
            public class Controller { }
            namespace Internal {
                public class Helper { }
            }
        }
        """
        let entries = indexCSharp(source)

        let namespaces = entries.filter { $0.kind == .extension }
        #expect(namespaces.count == 2)
        #expect(namespaces[0].name == "Acme.Web")
        #expect(namespaces[1].name == "Internal")

        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 2)
        // Namespaces don't set container
        #expect(classes.allSatisfy { $0.container == nil })
    }

    @Test("Delegates")
    func parsesDelegates() {
        let source = """
        public delegate void EventHandler(object sender, EventArgs e);
        public delegate T Func<T>();
        """
        let entries = indexCSharp(source)
        let delegates = entries.filter { $0.kind == .type }
        #expect(delegates.count == 2)
        #expect(delegates[0].name == "EventHandler")
        #expect(delegates[1].name == "Func")
    }

    @Test("Comments ignored")
    func handlesCommentsCorrectly() {
        let source = """
        // public class Fake { }
        /* interface IFake { } */
        public class Real { }
        """
        let entries = indexCSharp(source)
        #expect(entries.count == 1)
        #expect(entries[0].name == "Real")
        #expect(entries[0].kind == .class)
    }
}

// MARK: - C# Realistic Tests

@Suite("TreeSitterBackend — C# Realistic")
struct CSharpRealisticTests {

    @Test("Realistic C# file")
    func parsesRealisticCSharpFile() {
        let source = """
        using System;
        using System.Threading.Tasks;

        namespace Acme.Services {

        public enum UserStatus { Active, Suspended, Deleted }

        public record UserRecord(string Name, int Age);

        public class UserService {
            private readonly string _connectionString;

            public string ServiceName { get; set; }
            public int MaxRetries { get; private set; }

            public UserService() { }

            public UserService(string connectionString) {
                _connectionString = connectionString;
            }

            ~UserService() { }

            public string GetUser(int id) {
                return "user";
            }

            public async Task<bool> DeleteUser(int id) {
                return true;
            }

            public class CacheEntry {
                public string Key { get; set; }
                public void Invalidate() { }
            }
        }

        public interface IUserRepository {
            string Find(int id);
        }

        public delegate void UserChanged(int userId);

        } // namespace
        """
        let entries = indexCSharp(source)

        // namespace Acme.Services
        let namespaces = entries.filter { $0.kind == .extension }
        #expect(namespaces.count == 1)
        #expect(namespaces[0].name == "Acme.Services")

        // enum UserStatus
        let enums = entries.filter { $0.kind == .enum }
        #expect(enums.count == 1)
        #expect(enums[0].name == "UserStatus")

        // record UserRecord
        let records = entries.filter { $0.kind == .struct }
        #expect(records.count == 1)
        #expect(records[0].name == "UserRecord")

        // class UserService
        let userService = entries.filter { $0.name == "UserService" && $0.kind == .class }
        #expect(userService.count == 1)

        // UserService properties: ServiceName, MaxRetries
        let props = entries.filter { $0.kind == .property && $0.container == "UserService" }
        #expect(props.count == 2)
        let propNames = Set(props.map(\.name))
        #expect(propNames.contains("ServiceName"))
        #expect(propNames.contains("MaxRetries"))

        // UserService methods: 2 constructors + destructor + GetUser + DeleteUser = 5
        let serviceMethods = entries.filter { $0.kind == .method && $0.container == "UserService" }
        #expect(serviceMethods.count == 5)

        // Nested class CacheEntry
        let cacheEntry = entries.filter { $0.name == "CacheEntry" && $0.kind == .class }
        #expect(cacheEntry.count == 1)
        #expect(cacheEntry[0].container == "UserService")

        // CacheEntry property and method
        let cacheProps = entries.filter { $0.kind == .property && $0.container == "CacheEntry" }
        #expect(cacheProps.count == 1)
        #expect(cacheProps[0].name == "Key")

        let cacheMethods = entries.filter { $0.kind == .method && $0.container == "CacheEntry" }
        #expect(cacheMethods.count == 1)
        #expect(cacheMethods[0].name == "Invalidate")

        // interface IUserRepository
        let interfaces = entries.filter { $0.kind == .interface }
        #expect(interfaces.count == 1)
        #expect(interfaces[0].name == "IUserRepository")

        // delegate UserChanged
        let delegates = entries.filter { $0.kind == .type }
        #expect(delegates.count == 1)
        #expect(delegates[0].name == "UserChanged")

        // All entries from tree-sitter
        #expect(entries.allSatisfy { $0.engine == "tree-sitter" })
    }
}

// MARK: - C# Performance Tests

@Suite("TreeSitterBackend — C# Performance")
struct CSharpPerformanceTests {

    @Test("C# file parses under 10ms")
    func csharpFileParsesUnder10ms() {
        var source = "using System;\n\n"
        for i in 0..<5 {
            source += "namespace NS\(i) {\n"
            source += "public class Widget\(i) {\n"
            for j in 0..<6 {
                source += "    public void Method\(j)() { }\n"
            }
            for k in 0..<2 {
                source += "    public string Prop\(k) { get; set; }\n"
            }
            source += "}\n"
            source += "} // namespace\n\n"
        }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let entries = indexCSharp(source)
            #expect(entries.count > 0)
        }
        #expect(elapsed < .milliseconds(10))
    }
}

// MARK: - Helper

private func indexCSharp(_ source: String) -> [IndexEntry] {
    let tmpDir = NSTemporaryDirectory() + "senkani-csharp-test-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }
    let file = "test.cs"
    try! source.write(toFile: tmpDir + "/" + file, atomically: true, encoding: .utf8)
    return (try? TreeSitterBackend.index(files: [file], language: "csharp", projectRoot: tmpDir)) ?? []
}
