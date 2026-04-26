import Foundation
import Testing
@testable import Indexer

// MARK: - Elixir Parsing Tests

@Suite("TreeSitterBackend — Elixir Parsing")
struct ElixirParsingTests {

    @Test("Modules")
    func parsesModules() {
        let source = """
        defmodule Greeter do
        end

        defmodule Counter do
        end
        """
        let entries = indexElixir(source)
        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 2)
        let names = Set(classes.map(\.name))
        #expect(names.contains("Greeter"))
        #expect(names.contains("Counter"))
    }

    @Test("Public functions")
    func parsesPublicFunctions() {
        let source = """
        defmodule MyMod do
          def hello do
            "hi"
          end

          def greet(name) do
            "hi, " <> name
          end
        end
        """
        let entries = indexElixir(source)

        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 1)
        #expect(classes[0].name == "MyMod")

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 2)
        #expect(methods.allSatisfy { $0.container == "MyMod" })
        let names = Set(methods.map(\.name))
        #expect(names.contains("hello"))
        #expect(names.contains("greet"))
    }

    @Test("Private functions")
    func parsesPrivateFunctions() {
        let source = """
        defmodule Service do
          def public_api(x), do: helper(x)
          defp helper(x), do: x * 2
        end
        """
        let entries = indexElixir(source)

        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 1)
        #expect(classes[0].name == "Service")

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 2)
        #expect(methods.allSatisfy { $0.container == "Service" })
        let methodNames = Set(methods.map(\.name))
        #expect(methodNames.contains("public_api"))
        #expect(methodNames.contains("helper"))
    }

    @Test("Macros")
    func parsesMacros() {
        let source = """
        defmodule MyDSL do
          defmacro my_macro(do: block) do
            quote do
              unquote(block)
            end
          end

          defmacrop private_macro(x) do
            quote do: unquote(x) * 2
          end
        end
        """
        let entries = indexElixir(source)

        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 1)
        #expect(classes[0].name == "MyDSL")

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 2)
        #expect(methods.allSatisfy { $0.container == "MyDSL" })
        let names = Set(methods.map(\.name))
        #expect(names.contains("my_macro"))
        #expect(names.contains("private_macro"))
    }

    @Test("Mixed functions and macros")
    func parsesMixedFunctionsAndMacros() {
        let source = """
        defmodule Mixed do
          def regular_function, do: 1
          defp private_function, do: 2
          defmacro a_macro, do: quote(do: :ok)
          defmacrop private_macro, do: quote(do: :hidden)
        end
        """
        let entries = indexElixir(source)

        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 1)
        #expect(classes[0].name == "Mixed")

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 4)
        #expect(methods.allSatisfy { $0.container == "Mixed" })
        let names = Set(methods.map(\.name))
        #expect(names.contains("regular_function"))
        #expect(names.contains("private_function"))
        #expect(names.contains("a_macro"))
        #expect(names.contains("private_macro"))
    }

    @Test("Dotted module names")
    func parsesDottedModuleNames() {
        let source = """
        defmodule MyApp.Web.UserController do
        end

        defmodule MyApp.Repo do
        end
        """
        let entries = indexElixir(source)
        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 2)
        let names = Set(classes.map(\.name))
        #expect(names.contains("MyApp.Web.UserController"))
        #expect(names.contains("MyApp.Repo"))
    }

    @Test("Nested modules")
    func parsesNestedModules() {
        let source = """
        defmodule Outer do
          defmodule Inner do
            def hello, do: "hi"
          end
        end
        """
        let entries = indexElixir(source)

        let outer = entries.filter { $0.name == "Outer" && $0.kind == .class }
        #expect(outer.count == 1)
        #expect(outer[0].container == nil)

        let inner = entries.filter { $0.name == "Inner" && $0.kind == .class }
        #expect(inner.count == 1)
        #expect(inner[0].container == "Outer")

        let hello = entries.filter { $0.name == "hello" }
        #expect(hello.count == 1)
        #expect(hello[0].kind == .method)
        #expect(hello[0].container == "Inner")
    }

    @Test("Shorthand function syntax")
    func parsesShorthandFunctionSyntax() {
        let source = """
        defmodule Math do
          def add(a, b), do: a + b
          def square(x), do: x * x
        end
        """
        let entries = indexElixir(source)

        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 1)
        #expect(classes[0].name == "Math")

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 2)
        #expect(methods.allSatisfy { $0.container == "Math" })
        let names = Set(methods.map(\.name))
        #expect(names.contains("add"))
        #expect(names.contains("square"))
    }

    @Test("Comments ignored")
    func handlesCommentsCorrectly() {
        let source = """
        # defmodule Fake do end
        # def fake_function, do: nil
        defmodule Real do
          def real_function, do: :ok
        end
        """
        let entries = indexElixir(source)

        let classes = entries.filter { $0.kind == .class }
        #expect(classes.count == 1)
        #expect(classes[0].name == "Real")

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 1)
        #expect(methods[0].name == "real_function")
        #expect(methods[0].container == "Real")
    }
}

// MARK: - Elixir Realistic Tests

@Suite("TreeSitterBackend — Elixir Realistic")
struct ElixirRealisticTests {

    @Test("Realistic Phoenix controller")
    func parsesRealisticPhoenixController() {
        let source = """
        defmodule MyApp.UserController do
          use MyAppWeb, :controller

          import Ecto.Query
          alias MyApp.User
          alias MyApp.Repo

          def index(conn, _params) do
            users = Repo.all(User)
            render(conn, "index.html", users: users)
          end

          def show(conn, %{"id" => id}) do
            user = Repo.get!(User, id)
            render(conn, "show.html", user: user)
          end

          def create(conn, %{"user" => user_params}) do
            changeset = User.changeset(%User{}, user_params)
            case Repo.insert(changeset) do
              {:ok, user} -> redirect(conn, to: "/users/#{user.id}")
              {:error, changeset} -> render(conn, "new.html", changeset: changeset)
            end
          end

          def update(conn, %{"id" => id, "user" => user_params}) do
            user = Repo.get!(User, id)
            changeset = User.changeset(user, user_params)
            case Repo.update(changeset) do
              {:ok, _user} -> redirect(conn, to: "/users/#{id}")
              {:error, changeset} -> render(conn, "edit.html", changeset: changeset)
            end
          end

          def delete(conn, %{"id" => id}) do
            user = Repo.get!(User, id)
            Repo.delete!(user)
            redirect(conn, to: "/users")
          end

          defp render_user(conn, user) do
            render(conn, "show.html", user: user)
          end
        end
        """
        let entries = indexElixir(source)

        // Module
        let controller = entries.filter { $0.kind == .class }
        #expect(controller.count == 1)
        #expect(controller[0].name == "MyApp.UserController")

        // Actions + private helper = 6
        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 6)
        #expect(methods.allSatisfy { $0.container == "MyApp.UserController" })
        let methodNames = Set(methods.map(\.name))
        #expect(methodNames.contains("index"))
        #expect(methodNames.contains("show"))
        #expect(methodNames.contains("create"))
        #expect(methodNames.contains("update"))
        #expect(methodNames.contains("delete"))
        #expect(methodNames.contains("render_user"))

        // use, import, alias should NOT produce entries
        #expect(!entries.contains { $0.name == "MyAppWeb" })
        #expect(!entries.contains { $0.name == "Ecto.Query" })
        #expect(!entries.contains { $0.name == "User" && $0.kind != .class })

        // All entries from tree-sitter
        #expect(entries.allSatisfy { $0.engine == "tree-sitter" })
    }
}

// MARK: - Elixir Performance Tests

@Suite("TreeSitterBackend — Elixir Performance")
struct ElixirPerformanceTests {

    @Test("Elixir file parses under 50ms")
    func elixirFileParsesUnder10ms() {
        var source = "defmodule BigModule do\n"
        for i in 0..<30 {
            source += "  def func_\(i)(x), do: x + \(i)\n"
        }
        for i in 0..<5 {
            source += "  defp helper_\(i)(x) do\n"
            source += "    x * \(i + 1)\n"
            source += "  end\n"
        }
        source += "end\n"
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let entries = indexElixir(source)
            #expect(entries.count > 0)
        }
        // See TreeSitterKotlinTests for the 10ms → 50ms widen rationale.
        #expect(elapsed < .milliseconds(50))
    }

    @Test("Elixir coexists with other languages")
    func elixirCoexistsWithOtherLanguages() {
        let tmpDir = NSTemporaryDirectory() + "senkani-elixir-coexist-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        // Elixir file
        let elixirSource = "defmodule Greeter do\n  def greet(name), do: \"hi, \" <> name\nend\n"
        try! elixirSource.write(toFile: tmpDir + "/greeter.ex", atomically: true, encoding: .utf8)

        // Ruby file
        let rubySource = "class Greeter\n  def greet(name)\n    \"hi, #{name}\"\n  end\nend\n"
        try! rubySource.write(toFile: tmpDir + "/greeter.rb", atomically: true, encoding: .utf8)

        // Scala file
        let scalaSource = "class Greeter {\n  def greet(name: String): String = s\"hi, $name\"\n}\n"
        try! scalaSource.write(toFile: tmpDir + "/Greeter.scala", atomically: true, encoding: .utf8)

        let elixirEntries = (try? TreeSitterBackend.index(files: ["greeter.ex"], language: "elixir", projectRoot: tmpDir)) ?? []
        let rubyEntries = (try? TreeSitterBackend.index(files: ["greeter.rb"], language: "ruby", projectRoot: tmpDir)) ?? []
        let scalaEntries = (try? TreeSitterBackend.index(files: ["Greeter.scala"], language: "scala", projectRoot: tmpDir)) ?? []

        // Elixir: module Greeter + method greet = 2
        #expect(elixirEntries.count == 2)
        #expect(elixirEntries.contains { $0.name == "Greeter" && $0.kind == .class })
        #expect(elixirEntries.contains { $0.name == "greet" && $0.kind == .method })

        // Ruby: class Greeter + method greet = 2
        #expect(rubyEntries.count == 2)
        #expect(rubyEntries.contains { $0.name == "Greeter" && $0.kind == .class })

        // Scala: class Greeter + method greet = 2
        #expect(scalaEntries.count == 2)
        #expect(scalaEntries.contains { $0.name == "Greeter" && $0.kind == .class })
    }
}

// MARK: - Helper

private func indexElixir(_ source: String) -> [IndexEntry] {
    let tmpDir = NSTemporaryDirectory() + "senkani-elixir-test-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }
    let file = "test.ex"
    try! source.write(toFile: tmpDir + "/" + file, atomically: true, encoding: .utf8)
    return (try? TreeSitterBackend.index(files: [file], language: "elixir", projectRoot: tmpDir)) ?? []
}
