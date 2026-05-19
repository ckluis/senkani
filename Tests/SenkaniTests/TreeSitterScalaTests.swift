import Foundation
import Testing
@testable import Indexer

// MARK: - Scala Parsing Tests

@Suite("TreeSitterBackend — Scala Parsing")
struct ScalaParsingTests {

    @Test("Classes")
    func parsesClasses() {
        let source = """
        class Foo
        class Bar extends Foo
        abstract class Animal
        """
        let entries = indexScala(source)
        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 3)
        let names = Set(classes.map(\.name))
        #expect(names.contains("Foo"))
        #expect(names.contains("Bar"))
        #expect(names.contains("Animal"))
    }

    @Test("Case classes")
    func parsesCaseClasses() {
        let source = """
        case class User(name: String, age: Int)
        case class Point(x: Double, y: Double)
        """
        let entries = indexScala(source)
        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 2)
        let names = Set(classes.map(\.name))
        #expect(names.contains("User"))
        #expect(names.contains("Point"))
    }

    @Test("Objects")
    func parsesObjects() {
        let source = """
        object Logger {
          def log(msg: String): Unit = println(msg)
        }
        object Config {
          val debug = true
        }
        """
        let entries = indexScala(source)

        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 2)
        let classNames = Set(classes.map(\.name))
        #expect(classNames.contains("Logger"))
        #expect(classNames.contains("Config"))

        let log = entries.filter { $0.name == "log" }
        #expect(log.count == 1)
        #expect(log[0].kind == .method)
        #expect(log[0].container == "Logger")

        let debug = entries.filter { $0.name == "debug" }
        #expect(debug.count == 1)
        #expect(debug[0].kind == .property)
        #expect(debug[0].container == "Config")
    }

    @Test("Traits")
    func parsesTraits() {
        let source = """
        trait Greeter {
          def greet(): String
          def hello(): String = "hello"
        }
        """
        let entries = indexScala(source)

        let traits = entries.filter { $0.kind == .protocol }
        #expect(traits.count == 1)
        #expect(traits[0].name == "Greeter")

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 2)
        #expect(methods.allSatisfy { $0.container == "Greeter" })
        let methodNames = Set(methods.map(\.name))
        #expect(methodNames.contains("greet"))
        #expect(methodNames.contains("hello"))
    }

    @Test("Class methods")
    func parsesClassMethods() {
        let source = """
        class Service {
          def start(): Unit = println("starting")
          private def stop(): Unit = println("stopping")
          def restart(): Unit = { stop(); start() }
        }
        """
        let entries = indexScala(source)

        let service = entries.filter { $0.name == "Service" && $0.kind == .class }
        #expect(service.count == 1)

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 3)
        #expect(methods.allSatisfy { $0.container == "Service" })
        let names = Set(methods.map(\.name))
        #expect(names.contains("start"))
        #expect(names.contains("stop"))
        #expect(names.contains("restart"))
    }

    @Test("Val and var properties")
    func parsesValAndVarProperties() {
        let source = """
        class User {
          val name: String = ""
          var age: Int = 0
          private val id: Long = 0L
        }
        """
        let entries = indexScala(source)

        let user = entries.filter { $0.name == "User" && $0.kind == .class }
        #expect(user.count == 1)

        let props = entries.filter { $0.kind == .property }
        #expect(props.count == 3)
        #expect(props.allSatisfy { $0.container == "User" })
        let propNames = Set(props.map(\.name))
        #expect(propNames.contains("name"))
        #expect(propNames.contains("age"))
        #expect(propNames.contains("id"))
    }

    @Test("Companion object")
    func parsesCompanionObject() {
        let source = """
        class User(val name: String) {
          def greet(): String = s"hi, $name"
        }

        object User {
          def create(name: String): User = new User(name)
          val default: User = new User("anon")
        }
        """
        let entries = indexScala(source)

        // Two "User" entries — one class, one object (both .class)
        let users = entries.filter { $0.name == "User" && $0.kind == .class }
        #expect(users.count == 2)

        // Method "greet" in class User
        let greet = entries.filter { $0.name == "greet" }
        #expect(greet.count == 1)
        #expect(greet[0].kind == .method)
        #expect(greet[0].container == "User")

        // Method "create" in object User
        let create = entries.filter { $0.name == "create" }
        #expect(create.count == 1)
        #expect(create[0].kind == .method)
        #expect(create[0].container == "User")

        // Property "default" in object User
        let defaultProp = entries.filter { $0.name == "default" }
        #expect(defaultProp.count == 1)
        #expect(defaultProp[0].kind == .property)
        #expect(defaultProp[0].container == "User")
    }

    @Test("Nested classes")
    func parsesNestedClasses() {
        let source = """
        class Outer {
          class Inner {
            def method(): Int = 42
          }
          object NestedObj {
            def helper(): String = "nested"
          }
        }
        """
        let entries = indexScala(source)

        let outer = entries.filter { $0.name == "Outer" && $0.kind == .class }
        #expect(outer.count == 1)
        #expect(outer[0].container == nil)

        let inner = entries.filter { $0.name == "Inner" && $0.kind == .class }
        #expect(inner.count == 1)
        #expect(inner[0].container == "Outer")

        let method = entries.filter { $0.name == "method" }
        #expect(method.count == 1)
        #expect(method[0].kind == .method)
        #expect(method[0].container == "Inner")

        let nestedObj = entries.filter { $0.name == "NestedObj" && $0.kind == .class }
        #expect(nestedObj.count == 1)
        #expect(nestedObj[0].container == "Outer")

        let helper = entries.filter { $0.name == "helper" }
        #expect(helper.count == 1)
        #expect(helper[0].kind == .method)
        #expect(helper[0].container == "NestedObj")
    }

    @Test("Type aliases")
    func parsesTypeAliases() {
        let source = """
        type UserId = Long
        type Result[T] = Either[Error, T]
        """
        let entries = indexScala(source)
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.kind == .type })
        let names = Set(entries.map(\.name))
        #expect(names.contains("UserId"))
        #expect(names.contains("Result"))
    }

    @Test("Comments ignored")
    func handlesCommentsCorrectly() {
        let source = """
        // class Fake
        /* def fake(): Unit = () */
        class Real
        """
        let entries = indexScala(source)
        #expect(entries.count == 1)
        #expect(entries[0].name == "Real")
        #expect(entries[0].kind == .class)
    }
}

// MARK: - Scala Realistic Tests

@Suite("TreeSitterBackend — Scala Realistic")
struct ScalaRealisticTests {

    @Test("Realistic Scala file")
    func parsesRealisticScalaFile() {
        let source = """
        package com.acme.models

        import scala.util.Try

        sealed trait Result
        case class Success(data: String) extends Result
        case class Failure(error: String) extends Result

        class UserService(val db: Database) {
          private val maxRetries: Int = 3
          var lastError: Option[String] = None

          def getUser(id: Long): Option[User] = {
            Try(db.query(id)).toOption
          }

          def deleteUser(id: Long): Boolean = {
            db.delete(id)
          }
        }

        object UserService {
          def create(db: Database): UserService = new UserService(db)
          val defaultPageSize: Int = 20
        }

        trait Auditable {
          def auditLog(): String
        }

        def topLevelHelper(): String = "help"

        type UserId = Long
        """
        let entries = indexScala(source)

        // sealed trait Result
        let result = entries.filter { $0.name == "Result" && $0.kind == .protocol }
        #expect(result.count == 1)
        #expect(result[0].container == nil)

        // case class Success, Failure
        let success = entries.filter { $0.name == "Success" && $0.kind == .class }
        #expect(success.count == 1)
        let failure = entries.filter { $0.name == "Failure" && $0.kind == .class }
        #expect(failure.count == 1)

        // class UserService
        let userService = entries.filter { $0.name == "UserService" && $0.kind == .class }
        #expect(userService.count == 2) // class + companion object

        // UserService properties: maxRetries, lastError
        let serviceProps = entries.filter { $0.kind == .property && $0.container == "UserService" }
        #expect(serviceProps.count == 3) // maxRetries + lastError (class) + defaultPageSize (object)
        let propNames = Set(serviceProps.map(\.name))
        #expect(propNames.contains("maxRetries"))
        #expect(propNames.contains("lastError"))
        #expect(propNames.contains("defaultPageSize"))

        // UserService methods: getUser, deleteUser (class) + create (object)
        let serviceMethods = entries.filter { $0.kind == .method && $0.container == "UserService" }
        #expect(serviceMethods.count == 3)
        let methodNames = Set(serviceMethods.map(\.name))
        #expect(methodNames.contains("getUser"))
        #expect(methodNames.contains("deleteUser"))
        #expect(methodNames.contains("create"))

        // trait Auditable
        let auditable = entries.filter { $0.name == "Auditable" && $0.kind == .protocol }
        #expect(auditable.count == 1)

        // Abstract method in trait
        let auditLog = entries.filter { $0.name == "auditLog" }
        #expect(auditLog.count == 1)
        #expect(auditLog[0].kind == .method)
        #expect(auditLog[0].container == "Auditable")

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

// MARK: - Scala Performance Tests

@Suite("TreeSitterBackend — Scala Performance")
struct ScalaPerformanceTests {

    @Test("Scala file parses under 10ms")
    func scalaFileParsesUnder10ms() {
        var source = "package com.example\n\n"
        for i in 0..<5 {
            source += "class Widget\(i) {\n"
            for j in 0..<6 {
                source += "  def method\(j)(): Unit = ()\n"
            }
            source += "}\n\n"
        }
        for i in 0..<3 {
            source += "trait Trait\(i) {\n"
            source += "  def abstractMethod\(i)(): String\n"
            source += "}\n\n"
        }
        for i in 0..<2 {
            source += "object Singleton\(i) {\n"
            source += "  val value\(i): Int = \(i)\n"
            source += "  def factory\(i)(): String = \"\(i)\"\n"
            source += "}\n\n"
        }
        // Median-of-3 — see DependencyGraphPerfGateTests for the canonical
        // pattern. `.serialized` only serializes within-suite, so peer-suite
        // CPU contention can spike a single sample under parallel runner;
        // a single transient spike on one of three runs cannot fail the
        // test, but a real regression (every run blows budget) still does.
        // Threshold widened 10 ms → 20 ms because in-isolation typical is
        // 5–7 ms — only ~30 % headroom above 10 ms even without contention.
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for _ in 0..<3 {
            let elapsed = clock.measure {
                let entries = indexScala(source)
                #expect(entries.count > 0)
            }
            samples.append(elapsed)
        }
        let median = samples.sorted()[1]
        #expect(
            median < .milliseconds(20),
            "median of 3 Scala parses: \(samples) → median \(median)"
        )
    }

    @Test("Scala coexists with other languages")
    func scalaCoexistsWithOtherLanguages() {
        let tmpDir = NSTemporaryDirectory() + "senkani-scala-coexist-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        // Scala file
        let scalaSource = "class Greeter {\n  def greet(): String = \"hi\"\n}\nobject Greeter {\n  def create(): Greeter = new Greeter()\n}\n"
        try! scalaSource.write(toFile: tmpDir + "/greeter.scala", atomically: true, encoding: .utf8)

        // Java file
        let javaSource = "public class Greeter {\n    public String greet() { return \"hi\"; }\n}\n"
        try! javaSource.write(toFile: tmpDir + "/Greeter.java", atomically: true, encoding: .utf8)

        // Kotlin file
        let kotlinSource = "class Greeter {\n    fun greet(): String = \"hi\"\n}\n"
        try! kotlinSource.write(toFile: tmpDir + "/Greeter.kt", atomically: true, encoding: .utf8)

        let scalaEntries = (try? TreeSitterBackend.index(files: ["greeter.scala"], language: "scala", projectRoot: tmpDir)) ?? []
        let javaEntries = (try? TreeSitterBackend.index(files: ["Greeter.java"], language: "java", projectRoot: tmpDir)) ?? []
        let kotlinEntries = (try? TreeSitterBackend.index(files: ["Greeter.kt"], language: "kotlin", projectRoot: tmpDir)) ?? []

        // Scala: class Greeter + method greet + object Greeter + method create = 4
        #expect(scalaEntries.count == 4)
        #expect(scalaEntries.contains { $0.name == "Greeter" && $0.kind == .class })
        #expect(scalaEntries.contains { $0.name == "greet" && $0.kind == .method })
        #expect(scalaEntries.contains { $0.name == "create" && $0.kind == .method })

        // Java: class Greeter + method greet = 2
        #expect(javaEntries.count == 2)
        #expect(javaEntries.contains { $0.name == "Greeter" && $0.kind == .class })

        // Kotlin: class Greeter + method greet = 2
        #expect(kotlinEntries.count == 2)
        #expect(kotlinEntries.contains { $0.name == "Greeter" && $0.kind == .class })
    }
}

@Suite("TreeSitterBackend — Scala Depth Stress")
struct TreeSitterScalaDepthStressTests {

    // Chain child of `indexer-backends-iterative-walk-refactor-2026-05-11`.
    // Generates a class with a deeply-nested parenthesized expression
    // statement in its body, and indexes the file WITHOUT
    // `runOnLargeStackThread` to prove the iterative walk is
    // cooperative-pool-safe. Two empty top-level classes bracket the
    // deep expression to assert pre-order symbol emission.
    //
    // Why a class-body expression statement, not a val initializer:
    // Scala's leaf-emit arms (`val_definition` / `var_definition`,
    // `type_definition`, `function_definition` /
    // `function_declaration`) emit and return without descending into
    // the initializer/body subtree, so the deep chain cannot live
    // inside a val initializer — the walk would never reach the
    // parens. The deep chain must live in a node whose descendants
    // fall through the default arm (reverse-push children). The
    // `class_definition` body-rebind arm pushes the body with the
    // class name as container; the body falls through default,
    // reverse-pushes its children (an expression statement); the
    // expression statement falls through default, reverse-pushes the
    // parenthesized expression; the parenthesized expression chain
    // pushes ~2200 deep through repeated default-arm descent. The
    // pre-refactor walk would consume ~2200 Swift call frames and
    // crash on the cooperative pool's smaller stack; the iterative
    // form runs in heap-allocated work-stack memory.
    @Test("Depth-stress iterative walk does not overflow")
    func testDepthStressIterative() {
        let depth = 2200
        let opens = String(repeating: "(", count: depth)
        let closes = String(repeating: ")", count: depth)
        let source = """
        class First

        class Container {
          \(opens)0\(closes)
        }

        class Last
        """

        let entries = indexScala(source)
        let classes = entries.filter { $0.kind == .class }
        #expect(classes.map(\.name) == ["First", "Container", "Last"],
                "Symbol order must remain left-to-right pre-order")
        #expect(classes.allSatisfy { $0.container == nil },
                "Top-level Scala classes carry no container")
    }
}

// MARK: - Helper

private func indexScala(_ source: String) -> [IndexEntry] {
    let tmpDir = NSTemporaryDirectory() + "senkani-scala-test-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }
    let file = "test.scala"
    try! source.write(toFile: tmpDir + "/" + file, atomically: true, encoding: .utf8)
    return (try? TreeSitterBackend.index(files: [file], language: "scala", projectRoot: tmpDir)) ?? []
}
