import Foundation
import Testing
@testable import Indexer

// MARK: - PHP Parsing Tests

@Suite("TreeSitterBackend — PHP Parsing")
struct PhpParsingTests {

    @Test("Classes")
    func parsesClasses() {
        let source = """
        <?php
        class Foo { }
        abstract class Bar { }
        """
        let entries = indexPhp(source)
        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 2)
        #expect(classes[0].name == "Foo")
        #expect(classes[1].name == "Bar")
    }

    @Test("Interfaces")
    func parsesInterfaces() {
        let source = """
        <?php
        interface Greeter {
            public function greet(): string;
        }
        interface Counter {
            public function count(): int;
        }
        """
        let entries = indexPhp(source)
        let interfaces = entries.filter { $0.kind == .interface }
        #expect(interfaces.count == 2)
        #expect(interfaces[0].name == "Greeter")
        #expect(interfaces[1].name == "Counter")
    }

    @Test("Traits")
    func parsesTraits() {
        let source = """
        <?php
        trait Cacheable {
            public function cache() { }
        }
        trait Loggable {
            public function log($msg) { }
        }
        """
        let entries = indexPhp(source)
        let traits = entries.filter { $0.kind == .class }
        #expect(traits.count == 2)
        #expect(traits[0].name == "Cacheable")
        #expect(traits[1].name == "Loggable")

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 2)
        #expect(methods[0].container == "Cacheable")
        #expect(methods[1].container == "Loggable")
    }

    @Test("Enums")
    func parsesEnums() {
        let source = """
        <?php
        enum Color { case Red; case Green; case Blue; }
        enum Status: string { case Active = 'active'; case Inactive = 'inactive'; }
        """
        let entries = indexPhp(source)
        let enums = entries.filter { $0.kind == .enum }
        #expect(enums.count == 2)
        #expect(enums[0].name == "Color")
        #expect(enums[1].name == "Status")
    }

    @Test("Top-level functions")
    func parsesTopLevelFunctions() {
        let source = """
        <?php
        function hello() {
            return "hi";
        }
        function compute($x, $y) {
            return $x + $y;
        }
        """
        let entries = indexPhp(source)
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.kind == .function })
        #expect(entries.allSatisfy { $0.container == nil })
        let names = Set(entries.map(\.name))
        #expect(names.contains("hello"))
        #expect(names.contains("compute"))
    }

    @Test("Class methods")
    func parsesClassMethods() {
        let source = """
        <?php
        class User {
            public function greet() { return "hello"; }
            public static function create($name) { return new self($name); }
            private function validate() { }
        }
        """
        let entries = indexPhp(source)

        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 1)
        #expect(classes[0].name == "User")

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 3)
        #expect(methods.allSatisfy { $0.container == "User" })
        let names = Set(methods.map(\.name))
        #expect(names.contains("greet"))
        #expect(names.contains("create"))
        #expect(names.contains("validate"))
    }

    @Test("Properties with $ sigil")
    func parsesPropertiesWithDollarSigil() {
        let source = """
        <?php
        class Config {
            public $host;
            private $port;
            protected static $instance;
        }
        """
        let entries = indexPhp(source)

        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 1)
        #expect(classes[0].name == "Config")

        let props = entries.filter { $0.kind == .property }
        #expect(props.count == 3)
        #expect(props.allSatisfy { $0.container == "Config" })
        let propNames = Set(props.map(\.name))
        #expect(propNames.contains("$host"))
        #expect(propNames.contains("$port"))
        #expect(propNames.contains("$instance"))
    }

    @Test("Constructors and destructors")
    func parsesConstructorsAndDestructors() {
        let source = """
        <?php
        class Resource {
            public function __construct($name) { }
            public function __destruct() { }
        }
        """
        let entries = indexPhp(source)

        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 1)

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 2)
        #expect(methods.allSatisfy { $0.container == "Resource" })
        let names = Set(methods.map(\.name))
        #expect(names.contains("__construct"))
        #expect(names.contains("__destruct"))
    }

    @Test("Nested classes")
    func parsesNestedClasses() {
        let source = """
        <?php
        class Outer {
            public function hello() { }
        }
        class Inner {
            public function world() { }
        }
        """
        let entries = indexPhp(source)

        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 2)
        #expect(classes[0].name == "Outer")
        #expect(classes[1].name == "Inner")

        let helloMethod = entries.filter { $0.name == "hello" }
        #expect(helloMethod.count == 1)
        #expect(helloMethod[0].container == "Outer")

        let worldMethod = entries.filter { $0.name == "world" }
        #expect(worldMethod.count == 1)
        #expect(worldMethod[0].container == "Inner")
    }

    @Test("Namespaces don't set container")
    func parsesNamespacesWithoutContainer() {
        let source = """
        <?php
        namespace Acme\\Web {
            class Controller { }
            function helper() { }
        }
        """
        let entries = indexPhp(source)

        let namespaces = entries.filter { $0.kind == .extension }
        #expect(namespaces.count == 1)
        #expect(namespaces[0].name == "Acme\\Web")

        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 1)
        #expect(classes[0].name == "Controller")
        #expect(classes[0].container == nil)

        let functions = entries.filter { $0.kind == .function }
        #expect(functions.count == 1)
        #expect(functions[0].container == nil)
    }

    @Test("Interface methods")
    func parsesInterfaceMethods() {
        let source = """
        <?php
        interface Repository {
            public function find(int $id): mixed;
            public function save($entity): void;
        }
        """
        let entries = indexPhp(source)

        let interfaces = entries.filter { $0.kind == .interface }
        #expect(interfaces.count == 1)
        #expect(interfaces[0].name == "Repository")

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 2)
        #expect(methods.allSatisfy { $0.container == "Repository" })
    }

    @Test("Comments ignored")
    func handlesCommentsCorrectly() {
        let source = """
        <?php
        // class Fake { }
        /* interface IFake { } */
        class Real { }
        """
        let entries = indexPhp(source)
        #expect(entries.count == 1)
        #expect(entries[0].name == "Real")
        #expect(entries[0].kind == .class)
    }
}

// MARK: - PHP Realistic Tests

@Suite("TreeSitterBackend — PHP Realistic")
struct PhpRealisticTests {

    @Test("Realistic PHP file")
    func parsesRealisticPhpFile() {
        let source = """
        <?php
        namespace Acme\\Services {

        enum UserStatus { case Active; case Suspended; }

        interface UserRepositoryInterface {
            public function find(int $id): mixed;
            public function delete(int $id): bool;
        }

        trait Cacheable {
            public function cacheKey(): string { return ''; }
        }

        class UserService {
            public $name;
            private $connection;

            public function __construct($connection) {
                $this->connection = $connection;
            }

            public function getUser(int $id) {
                return null;
            }

            public static function create($name) {
                return new self($name);
            }
        }

        function helpers_boot() {
            return true;
        }

        }
        """
        let entries = indexPhp(source)

        // namespace Acme\Services
        let namespaces = entries.filter { $0.kind == .extension }
        #expect(namespaces.count == 1)
        #expect(namespaces[0].name == "Acme\\Services")

        // enum UserStatus
        let enums = entries.filter { $0.kind == .enum }
        #expect(enums.count == 1)
        #expect(enums[0].name == "UserStatus")

        // interface UserRepositoryInterface
        let interfaces = entries.filter { $0.kind == .interface }
        #expect(interfaces.count == 1)
        #expect(interfaces[0].name == "UserRepositoryInterface")

        // Interface methods
        let ifaceMethods = entries.filter { $0.kind == .method && $0.container == "UserRepositoryInterface" }
        #expect(ifaceMethods.count == 2)

        // trait Cacheable
        let traits = entries.filter { $0.kind == .class && $0.name == "Cacheable" }
        #expect(traits.count == 1)

        // Trait method
        let traitMethods = entries.filter { $0.kind == .method && $0.container == "Cacheable" }
        #expect(traitMethods.count == 1)
        #expect(traitMethods[0].name == "cacheKey")

        // class UserService
        let userService = entries.filter { $0.name == "UserService" && $0.kind == .class }
        #expect(userService.count == 1)

        // UserService properties with $ sigil
        let props = entries.filter { $0.kind == .property && $0.container == "UserService" }
        #expect(props.count == 2)
        let propNames = Set(props.map(\.name))
        #expect(propNames.contains("$name"))
        #expect(propNames.contains("$connection"))

        // UserService methods: __construct, getUser, create = 3
        let serviceMethods = entries.filter { $0.kind == .method && $0.container == "UserService" }
        #expect(serviceMethods.count == 3)
        let methodNames = Set(serviceMethods.map(\.name))
        #expect(methodNames.contains("__construct"))
        #expect(methodNames.contains("getUser"))
        #expect(methodNames.contains("create"))

        // Top-level function (namespace doesn't set container)
        let functions = entries.filter { $0.kind == .function }
        #expect(functions.count == 1)
        #expect(functions[0].name == "helpers_boot")
        #expect(functions[0].container == nil)

        // All entries from tree-sitter
        #expect(entries.allSatisfy { $0.engine == "tree-sitter" })
    }
}

// MARK: - PHP Performance Tests

@Suite("TreeSitterBackend — PHP Performance")
struct PhpPerformanceTests {

    @Test("PHP file parses under 10ms")
    func phpFileParsesUnder10ms() {
        var source = "<?php\n\n"
        for i in 0..<5 {
            source += "class Widget\(i) {\n"
            for j in 0..<6 {
                source += "    public function method\(j)() { }\n"
            }
            for k in 0..<2 {
                source += "    public $prop\(k);\n"
            }
            source += "}\n\n"
        }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let entries = indexPhp(source)
            #expect(entries.count > 0)
        }
        #expect(elapsed < .milliseconds(10))
    }

    @Test("PHP coexists with other languages")
    func phpCoexistsWithOtherLanguages() {
        let tmpDir = NSTemporaryDirectory() + "senkani-php-coexist-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        // PHP file
        let phpSource = "<?php\nclass Greeter {\n    public function greet() { }\n}\n"
        try! phpSource.write(toFile: tmpDir + "/greeter.php", atomically: true, encoding: .utf8)

        // Ruby file
        let rubySource = "class Greeter\n  def greet\n  end\nend\n"
        try! rubySource.write(toFile: tmpDir + "/greeter.rb", atomically: true, encoding: .utf8)

        // Python file
        let pySource = "class Greeter:\n    def greet(self):\n        pass\n"
        try! pySource.write(toFile: tmpDir + "/greeter.py", atomically: true, encoding: .utf8)

        let phpEntries = (try? TreeSitterBackend.index(files: ["greeter.php"], language: "php", projectRoot: tmpDir)) ?? []
        let rubyEntries = (try? TreeSitterBackend.index(files: ["greeter.rb"], language: "ruby", projectRoot: tmpDir)) ?? []
        let pyEntries = (try? TreeSitterBackend.index(files: ["greeter.py"], language: "python", projectRoot: tmpDir)) ?? []

        #expect(phpEntries.count == 2) // class + method
        #expect(phpEntries.contains { $0.name == "Greeter" && $0.kind == .class })
        #expect(phpEntries.contains { $0.name == "greet" && $0.kind == .method })

        #expect(rubyEntries.count == 2) // class + method
        #expect(rubyEntries.contains { $0.name == "Greeter" && $0.kind == .class })

        #expect(pyEntries.count == 2) // class + method
        #expect(pyEntries.contains { $0.name == "Greeter" && $0.kind == .class })
    }
}

// MARK: - Helper

private func indexPhp(_ source: String) -> [IndexEntry] {
    let tmpDir = NSTemporaryDirectory() + "senkani-php-test-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }
    let file = "test.php"
    try! source.write(toFile: tmpDir + "/" + file, atomically: true, encoding: .utf8)
    return (try? TreeSitterBackend.index(files: [file], language: "php", projectRoot: tmpDir)) ?? []
}
