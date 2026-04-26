import Foundation
import Testing
@testable import Indexer

// MARK: - Ruby Parsing Tests

@Suite("TreeSitterBackend — Ruby Parsing")
struct RubyParsingTests {

    @Test("Classes")
    func parsesClasses() {
        let source = """
        class Foo
        end

        class Bar < Foo
        end
        """
        let entries = indexRuby(source)
        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 2)
        #expect(classes[0].name == "Foo")
        #expect(classes[1].name == "Bar")
    }

    @Test("Modules")
    func parsesModules() {
        let source = """
        module Greetings
        end

        module Math::Helpers
        end
        """
        let entries = indexRuby(source)
        let modules = entries.filter { $0.kind == .extension }
        #expect(modules.count == 2)
        #expect(modules[0].name == "Greetings")
        #expect(modules[1].name == "Math::Helpers")
    }

    @Test("Instance methods")
    func parsesInstanceMethods() {
        let source = """
        class User
          def greet
            "hello"
          end
          def name=(value)
            @name = value
          end
        end
        """
        let entries = indexRuby(source)

        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 1)
        #expect(classes[0].name == "User")

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 2)
        #expect(methods.allSatisfy { $0.container == "User" })
        let names = Set(methods.map(\.name))
        #expect(names.contains("greet"))
        #expect(names.contains("name="))
    }

    @Test("Singleton methods")
    func parsesSingletonMethods() {
        let source = """
        class User
          def self.create(name)
            User.new(name)
          end
          def self.find(id)
            nil
          end
        end
        """
        let entries = indexRuby(source)

        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 1)
        #expect(classes[0].name == "User")

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 2)
        #expect(methods.allSatisfy { $0.container == "User" })
        let names = Set(methods.map(\.name))
        #expect(names.contains("create"))
        #expect(names.contains("find"))
    }

    @Test("Mixed instance and singleton methods")
    func parsesMixedInstanceAndSingletonMethods() {
        let source = """
        class Service
          def self.start
          end
          def stop
          end
          def self.status
          end
        end
        """
        let entries = indexRuby(source)

        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 1)
        #expect(classes[0].name == "Service")

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 3)
        #expect(methods.allSatisfy { $0.container == "Service" })
        let names = Set(methods.map(\.name))
        #expect(names.contains("start"))
        #expect(names.contains("stop"))
        #expect(names.contains("status"))
    }

    @Test("Nested classes")
    func parsesNestedClasses() {
        let source = """
        class Outer
          class Inner
            def hello
            end
          end
        end
        """
        let entries = indexRuby(source)

        let outer = entries.filter { $0.name == "Outer" && $0.kind == .class }
        #expect(outer.count == 1)
        #expect(outer[0].container == nil)

        let inner = entries.filter { $0.name == "Inner" && $0.kind == .class }
        #expect(inner.count == 1)
        #expect(inner[0].container == "Outer")

        let method = entries.filter { $0.name == "hello" }
        #expect(method.count == 1)
        #expect(method[0].container == "Inner")
    }

    @Test("Module as container")
    func parsesModuleAsContainer() {
        let source = """
        module Helpers
          def self.format(value)
            value.to_s
          end
          def parse(text)
            text.split
          end
        end
        """
        let entries = indexRuby(source)

        let modules = entries.filter { $0.kind == .extension }
        #expect(modules.count == 1)
        #expect(modules[0].name == "Helpers")

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 2)
        #expect(methods.allSatisfy { $0.container == "Helpers" })
        let names = Set(methods.map(\.name))
        #expect(names.contains("format"))
        #expect(names.contains("parse"))
    }

    @Test("Nested modules and classes")
    func parsesNestedModulesAndClasses() {
        let source = """
        module Acme
          class User
            def name
            end
          end
        end
        """
        let entries = indexRuby(source)

        let modules = entries.filter { $0.kind == .extension }
        #expect(modules.count == 1)
        #expect(modules[0].name == "Acme")

        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 1)
        #expect(classes[0].name == "User")
        #expect(classes[0].container == "Acme")

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 1)
        #expect(methods[0].name == "name")
        #expect(methods[0].container == "User")
    }

    @Test("Top-level methods")
    func parsesTopLevelMethods() {
        let source = """
        def hello
          "hi"
        end

        def compute(x, y)
          x + y
        end
        """
        let entries = indexRuby(source)
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.kind == .function })
        #expect(entries.allSatisfy { $0.container == nil })
        let names = Set(entries.map(\.name))
        #expect(names.contains("hello"))
        #expect(names.contains("compute"))
    }

    @Test("Comments ignored")
    func handlesCommentsCorrectly() {
        let source = """
        # class Fake
        #   def fake_method
        #   end
        # end

        class Real
        end
        """
        let entries = indexRuby(source)
        #expect(entries.count == 1)
        #expect(entries[0].name == "Real")
        #expect(entries[0].kind == .class)
    }
}

// MARK: - Ruby Realistic Tests

@Suite("TreeSitterBackend — Ruby Realistic")
struct RubyRealisticTests {

    @Test("Realistic Ruby file")
    func parsesRealisticRubyFile() {
        let source = """
        require 'json'
        require 'net/http'

        module Acme
          module Services
            class UserService
              attr_reader :name, :age

              def initialize(name, age)
                @name = name
                @age = age
              end

              def greet
                "Hello, #{@name}"
              end

              def to_json
                { name: @name, age: @age }.to_json
              end

              def self.create(name, age)
                new(name, age)
              end

              class Validator
                def valid?(user)
                  true
                end
              end
            end

            module Formatting
              def self.format_name(name)
                name.strip.capitalize
              end
            end
          end
        end
        """
        let entries = indexRuby(source)

        // module Acme
        let acme = entries.filter { $0.name == "Acme" && $0.kind == .extension }
        #expect(acme.count == 1)
        #expect(acme[0].container == nil)

        // module Services (nested in Acme)
        let services = entries.filter { $0.name == "Services" && $0.kind == .extension }
        #expect(services.count == 1)
        #expect(services[0].container == "Acme")

        // class UserService (nested in Services)
        let userService = entries.filter { $0.name == "UserService" && $0.kind == .class }
        #expect(userService.count == 1)
        #expect(userService[0].container == "Services")

        // UserService methods: initialize, greet, to_json (instance) + create (singleton) = 4
        let serviceMethods = entries.filter { $0.kind == .method && $0.container == "UserService" }
        #expect(serviceMethods.count == 4)
        let methodNames = Set(serviceMethods.map(\.name))
        #expect(methodNames.contains("initialize"))
        #expect(methodNames.contains("greet"))
        #expect(methodNames.contains("to_json"))
        #expect(methodNames.contains("create"))

        // Nested class Validator
        let validator = entries.filter { $0.name == "Validator" && $0.kind == .class }
        #expect(validator.count == 1)
        #expect(validator[0].container == "UserService")

        // Validator method
        let validMethod = entries.filter { $0.name == "valid?" }
        #expect(validMethod.count == 1)
        #expect(validMethod[0].container == "Validator")

        // module Formatting (nested in Services)
        let formatting = entries.filter { $0.name == "Formatting" && $0.kind == .extension }
        #expect(formatting.count == 1)
        #expect(formatting[0].container == "Services")

        // Formatting method
        let formatMethod = entries.filter { $0.name == "format_name" }
        #expect(formatMethod.count == 1)
        #expect(formatMethod[0].container == "Formatting")

        // All entries from tree-sitter
        #expect(entries.allSatisfy { $0.engine == "tree-sitter" })
    }
}

// MARK: - Ruby Performance Tests

@Suite("TreeSitterBackend — Ruby Performance")
struct RubyPerformanceTests {

    @Test("Ruby file parses under 10ms")
    func rubyFileParsesUnder10ms() {
        var source = "require 'json'\n\n"
        for i in 0..<2 {
            source += "module Mod\(i)\n"
        }
        for i in 0..<5 {
            source += "class Widget\(i)\n"
            for j in 0..<6 {
                source += "  def method\(j)\n  end\n"
            }
            source += "end\n\n"
        }
        for i in 0..<2 {
            source += "end\n"
        }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let entries = indexRuby(source)
            #expect(entries.count > 0)
        }
        #expect(elapsed < .milliseconds(10))
    }

    @Test("Ruby coexists with other languages")
    func rubyCoexistsWithOtherLanguages() {
        let tmpDir = NSTemporaryDirectory() + "senkani-ruby-coexist-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        // Java file
        let javaSource = "public class Greeter {\n    public void greet() { }\n}\n"
        try! javaSource.write(toFile: tmpDir + "/Greeter.java", atomically: true, encoding: .utf8)

        // Ruby file
        let rubySource = "class Greeter\n  def greet\n  end\nend\n"
        try! rubySource.write(toFile: tmpDir + "/greeter.rb", atomically: true, encoding: .utf8)

        // Python file
        let pySource = "class Greeter:\n    def greet(self):\n        pass\n"
        try! pySource.write(toFile: tmpDir + "/greeter.py", atomically: true, encoding: .utf8)

        let javaEntries = (try? TreeSitterBackend.index(files: ["Greeter.java"], language: "java", projectRoot: tmpDir)) ?? []
        let rubyEntries = (try? TreeSitterBackend.index(files: ["greeter.rb"], language: "ruby", projectRoot: tmpDir)) ?? []
        let pyEntries = (try? TreeSitterBackend.index(files: ["greeter.py"], language: "python", projectRoot: tmpDir)) ?? []

        #expect(javaEntries.count == 2) // class + method
        #expect(javaEntries.contains { $0.name == "Greeter" && $0.kind == .class })

        #expect(rubyEntries.count == 2) // class + method
        #expect(rubyEntries.contains { $0.name == "Greeter" && $0.kind == .class })
        #expect(rubyEntries.contains { $0.name == "greet" && $0.kind == .method })

        #expect(pyEntries.count == 2) // class + method
        #expect(pyEntries.contains { $0.name == "Greeter" && $0.kind == .class })
    }
}

// MARK: - Helper

private func indexRuby(_ source: String) -> [IndexEntry] {
    let tmpDir = NSTemporaryDirectory() + "senkani-ruby-test-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }
    let file = "test.rb"
    try! source.write(toFile: tmpDir + "/" + file, atomically: true, encoding: .utf8)
    return (try? TreeSitterBackend.index(files: [file], language: "ruby", projectRoot: tmpDir)) ?? []
}
