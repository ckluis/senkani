import Foundation
import Testing
@testable import Indexer

// MARK: - Kotlin Parsing Tests

@Suite("TreeSitterBackend — Kotlin Parsing")
struct KotlinParsingTests {

    @Test("Top-level functions")
    func parsesTopLevelFunctions() {
        let source = """
        fun hello(): String = "hi"
        fun add(a: Int, b: Int): Int { return a + b }
        """
        let entries = indexKotlin(source)
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.kind == .function })
        #expect(entries.allSatisfy { $0.container == nil })
        let names = Set(entries.map(\.name))
        #expect(names.contains("hello"))
        #expect(names.contains("add"))
    }

    @Test("Classes")
    func parsesClasses() {
        let source = """
        class Foo
        class Bar : Foo()
        data class Point(val x: Int, val y: Int)
        sealed class Result
        """
        let entries = indexKotlin(source)
        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 4)
        let names = Set(classes.map(\.name))
        #expect(names.contains("Foo"))
        #expect(names.contains("Bar"))
        #expect(names.contains("Point"))
        #expect(names.contains("Result"))
    }

    @Test("Interfaces")
    func parsesInterfaces() {
        let source = """
        interface Greeter {
            fun greet(): String
        }
        interface Counter {
            fun count(): Int
        }
        """
        let entries = indexKotlin(source)
        // Kotlin interfaces parse as class_declaration — we emit .class
        let types = entries.filter { $0.kind == .class }
        #expect(types.count == 2)
        let names = Set(types.map(\.name))
        #expect(names.contains("Greeter"))
        #expect(names.contains("Counter"))

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 2)
    }

    @Test("Object declarations")
    func parsesObjectDeclarations() {
        let source = """
        object Logger {
            fun log(msg: String) {}
        }
        object Config {
            val debug = true
        }
        """
        let entries = indexKotlin(source)

        let objects = entries.filter { $0.kind == .class }
        #expect(objects.count == 2)
        let objectNames = Set(objects.map(\.name))
        #expect(objectNames.contains("Logger"))
        #expect(objectNames.contains("Config"))

        let logMethod = entries.filter { $0.name == "log" }
        #expect(logMethod.count == 1)
        #expect(logMethod[0].kind == .method)
        #expect(logMethod[0].container == "Logger")

        let debugProp = entries.filter { $0.name == "debug" }
        #expect(debugProp.count == 1)
        #expect(debugProp[0].kind == .property)
        #expect(debugProp[0].container == "Config")
    }

    @Test("Class methods")
    func parsesClassMethods() {
        let source = """
        class Service {
            fun start() {}
            private fun stop() {}
            fun restart() { stop(); start() }
        }
        """
        let entries = indexKotlin(source)

        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 1)
        #expect(classes[0].name == "Service")

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 3)
        #expect(methods.allSatisfy { $0.container == "Service" })
        let names = Set(methods.map(\.name))
        #expect(names.contains("start"))
        #expect(names.contains("stop"))
        #expect(names.contains("restart"))
    }

    @Test("Properties")
    func parsesProperties() {
        let source = """
        class User {
            var age: Int = 0
            val email: String? = null
        }
        """
        let entries = indexKotlin(source)

        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 1)
        #expect(classes[0].name == "User")

        let props = entries.filter { $0.kind == .property }
        #expect(props.count == 2)
        #expect(props.allSatisfy { $0.container == "User" })
        let propNames = Set(props.map(\.name))
        #expect(propNames.contains("age"))
        #expect(propNames.contains("email"))
    }

    @Test("Companion object")
    func parsesCompanionObject() {
        let source = """
        class User(val name: String) {
            fun greet() = "hi"
            companion object {
                fun create(name: String) = User(name)
            }
        }
        """
        let entries = indexKotlin(source)

        let classes = entries.filter { $0.kind == .class }
        let classNames = Set(classes.map(\.name))
        #expect(classNames.contains("User"))
        #expect(classNames.contains("Companion"))

        let companion = classes.first { $0.name == "Companion" }!
        #expect(companion.container == "User")

        let greet = entries.filter { $0.name == "greet" }
        #expect(greet.count == 1)
        #expect(greet[0].kind == .method)
        #expect(greet[0].container == "User")

        let create = entries.filter { $0.name == "create" }
        #expect(create.count == 1)
        #expect(create[0].kind == .method)
        #expect(create[0].container == "Companion")
    }

    @Test("Named companion object")
    func parsesNamedCompanionObject() {
        let source = """
        class User {
            companion object Factory {
                fun build(): User = User()
            }
        }
        """
        let entries = indexKotlin(source)

        let classes = entries.filter { $0.kind == .class }
        let classNames = Set(classes.map(\.name))
        #expect(classNames.contains("User"))
        #expect(classNames.contains("Factory"))

        let factory = classes.first { $0.name == "Factory" }!
        #expect(factory.container == "User")

        let build = entries.filter { $0.name == "build" }
        #expect(build.count == 1)
        #expect(build[0].kind == .method)
        #expect(build[0].container == "Factory")
    }

    @Test("Nested classes")
    func parsesNestedClasses() {
        let source = """
        class Outer {
            class Inner {
                fun method() {}
            }
            inner class Member {
                fun other() {}
            }
        }
        """
        let entries = indexKotlin(source)

        let outer = entries.filter { $0.name == "Outer" && $0.kind == .class }
        #expect(outer.count == 1)
        #expect(outer[0].container == nil)

        let inner = entries.filter { $0.name == "Inner" && $0.kind == .class }
        #expect(inner.count == 1)
        #expect(inner[0].container == "Outer")

        let method = entries.filter { $0.name == "method" }
        #expect(method.count == 1)
        #expect(method[0].container == "Inner")

        let member = entries.filter { $0.name == "Member" && $0.kind == .class }
        #expect(member.count == 1)
        #expect(member[0].container == "Outer")

        let other = entries.filter { $0.name == "other" }
        #expect(other.count == 1)
        #expect(other[0].container == "Member")
    }

    @Test("Type aliases")
    func parsesTypeAliases() {
        let source = """
        typealias UserId = String
        typealias Callback = (Int) -> Unit
        """
        let entries = indexKotlin(source)
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.kind == .type })
        let names = Set(entries.map(\.name))
        #expect(names.contains("UserId"))
        #expect(names.contains("Callback"))
    }

    @Test("Comments ignored")
    func handlesCommentsCorrectly() {
        let source = """
        // fun fakeFunction() {}
        /* class FakeClass */
        fun real() {}
        """
        let entries = indexKotlin(source)
        #expect(entries.count == 1)
        #expect(entries[0].name == "real")
        #expect(entries[0].kind == .function)
    }
}

// MARK: - Kotlin Realistic Tests

@Suite("TreeSitterBackend — Kotlin Realistic")
struct KotlinRealisticTests {

    @Test("Realistic Kotlin file")
    func parsesRealisticKotlinFile() {
        let source = """
        package com.acme.services

        import java.util.UUID

        data class User(val name: String, val age: Int)

        sealed class Result {
            data class Success(val data: Any) : Result()
            data class Error(val message: String) : Result()
        }

        class UserService {
            val maxRetries: Int = 3
            var lastError: String? = null

            fun getUser(id: Int): User? {
                return null
            }

            fun deleteUser(id: Int): Boolean {
                return true
            }

            companion object {
                fun create(): UserService = UserService()
            }
        }

        object AppConfig {
            val debug = false
            fun load() {}
        }

        fun topLevelHelper(): String = "help"

        typealias UserId = String
        """
        let entries = indexKotlin(source)

        // data class User
        let user = entries.filter { $0.name == "User" && $0.kind == .class }
        #expect(user.count == 1)
        #expect(user[0].container == nil)

        // sealed class Result
        let result = entries.filter { $0.name == "Result" && $0.kind == .class && $0.container == nil }
        #expect(result.count == 1)

        // Nested data classes inside Result
        let success = entries.filter { $0.name == "Success" && $0.kind == .class }
        #expect(success.count == 1)
        #expect(success[0].container == "Result")

        let error = entries.filter { $0.name == "Error" && $0.kind == .class }
        #expect(error.count == 1)
        #expect(error[0].container == "Result")

        // class UserService
        let userService = entries.filter { $0.name == "UserService" && $0.kind == .class }
        #expect(userService.count == 1)

        // UserService properties
        let serviceProps = entries.filter { $0.kind == .property && $0.container == "UserService" }
        #expect(serviceProps.count == 2)
        let propNames = Set(serviceProps.map(\.name))
        #expect(propNames.contains("maxRetries"))
        #expect(propNames.contains("lastError"))

        // UserService methods: getUser, deleteUser
        let serviceMethods = entries.filter { $0.kind == .method && $0.container == "UserService" }
        #expect(serviceMethods.count == 2)
        let methodNames = Set(serviceMethods.map(\.name))
        #expect(methodNames.contains("getUser"))
        #expect(methodNames.contains("deleteUser"))

        // Companion object
        let companion = entries.filter { $0.name == "Companion" && $0.kind == .class }
        #expect(companion.count == 1)
        #expect(companion[0].container == "UserService")

        // Companion method
        let create = entries.filter { $0.name == "create" }
        #expect(create.count == 1)
        #expect(create[0].container == "Companion")

        // object AppConfig
        let appConfig = entries.filter { $0.name == "AppConfig" && $0.kind == .class }
        #expect(appConfig.count == 1)
        #expect(appConfig[0].container == nil)

        let configProps = entries.filter { $0.kind == .property && $0.container == "AppConfig" }
        #expect(configProps.count == 1)
        #expect(configProps[0].name == "debug")

        let configMethods = entries.filter { $0.kind == .method && $0.container == "AppConfig" }
        #expect(configMethods.count == 1)
        #expect(configMethods[0].name == "load")

        // Top-level function
        let topLevel = entries.filter { $0.name == "topLevelHelper" }
        #expect(topLevel.count == 1)
        #expect(topLevel[0].kind == .function)
        #expect(topLevel[0].container == nil)

        // Type alias
        let typeAlias = entries.filter { $0.name == "UserId" }
        #expect(typeAlias.count == 1)
        #expect(typeAlias[0].kind == .type)

        // All entries from tree-sitter
        #expect(entries.allSatisfy { $0.engine == "tree-sitter" })
    }
}

// MARK: - Kotlin Performance Tests

@Suite("TreeSitterBackend — Kotlin Performance")
struct KotlinPerformanceTests {

    @Test("Kotlin file parses under 50ms")
    func kotlinFileParsesUnder10ms() {
        var source = "package com.example\n\n"
        for i in 0..<5 {
            source += "class Widget\(i) {\n"
            for j in 0..<6 {
                source += "    fun method\(j)() {}\n"
            }
            for k in 0..<2 {
                source += "    val prop\(k): Int = 0\n"
            }
            if i < 2 {
                source += "    companion object {\n"
                source += "        fun factory(): Widget\(i) = Widget\(i)()\n"
                source += "    }\n"
            }
            source += "}\n\n"
        }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let entries = indexKotlin(source)
            #expect(entries.count > 0)
        }
        // Widened 10ms → 50ms 2026-04-21: original 10ms bound flakes on
        // loaded machines (see spec/testing.md "Harness hang"). 50ms still
        // catches a real regression — a reverted tree-sitter parse costs
        // ~500ms — without false-firing when a sibling @Test hogs the
        // cooperative pool.
        #expect(elapsed < .milliseconds(50))
    }
}

// MARK: - Helper

private func indexKotlin(_ source: String) -> [IndexEntry] {
    let tmpDir = NSTemporaryDirectory() + "senkani-kotlin-test-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }
    let file = "test.kt"
    try! source.write(toFile: tmpDir + "/" + file, atomically: true, encoding: .utf8)
    return (try? TreeSitterBackend.index(files: [file], language: "kotlin", projectRoot: tmpDir)) ?? []
}
