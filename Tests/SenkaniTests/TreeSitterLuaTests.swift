import Foundation
import Testing
@testable import Indexer

// MARK: - Lua Parsing Tests

@Suite("TreeSitterBackend — Lua Parsing")
struct LuaParsingTests {

    @Test("Plain functions")
    func parsesPlainFunctions() {
        let source = """
        function hello()
            return 'hi'
        end

        function add(a, b)
            return a + b
        end
        """
        let entries = indexLua(source)
        let funcs = entries.filter { $0.kind == .function }
        #expect(funcs.count == 2)
        #expect(funcs.allSatisfy { $0.container == nil })
        let names = Set(funcs.map(\.name))
        #expect(names.contains("hello"))
        #expect(names.contains("add"))
    }

    @Test("Local functions")
    func parsesLocalFunctions() {
        let source = """
        local function helper()
            return 42
        end

        local function compute(x)
            return x * 2
        end
        """
        let entries = indexLua(source)
        let funcs = entries.filter { $0.kind == .function }
        #expect(funcs.count == 2)
        #expect(funcs.allSatisfy { $0.container == nil })
        let names = Set(funcs.map(\.name))
        #expect(names.contains("helper"))
        #expect(names.contains("compute"))
    }

    @Test("Table methods with dot")
    func parsesTableMethodsWithDot() {
        let source = """
        local M = {}

        function M.greet(name)
            return 'hello ' .. name
        end

        function M.farewell()
            return 'bye'
        end
        """
        let entries = indexLua(source)
        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 2)
        #expect(methods.allSatisfy { $0.container == "M" })
        let names = Set(methods.map(\.name))
        #expect(names.contains("greet"))
        #expect(names.contains("farewell"))
    }

    @Test("Table methods with colon")
    func parsesTableMethodsWithColon() {
        let source = """
        local Obj = {}

        function Obj:init(x)
            self.x = x
        end

        function Obj:toString()
            return tostring(self.x)
        end
        """
        let entries = indexLua(source)
        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 2)
        #expect(methods.allSatisfy { $0.container == "Obj" })
        let names = Set(methods.map(\.name))
        #expect(names.contains("init"))
        #expect(names.contains("toString"))
    }

    @Test("Mixed dot and colon methods")
    func parsesMixedDotAndColonMethods() {
        let source = """
        local T = {}

        function T.new(val)
            return setmetatable({val = val}, {__index = T})
        end

        function T:getValue()
            return self.val
        end

        function T:setValue(v)
            self.val = v
        end
        """
        let entries = indexLua(source)
        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 3)
        #expect(methods.allSatisfy { $0.container == "T" })
        let names = Set(methods.map(\.name))
        #expect(names.contains("new"))
        #expect(names.contains("getValue"))
        #expect(names.contains("setValue"))
    }

    @Test("Mixed top-level and methods")
    func parsesMixedTopLevelAndMethods() {
        let source = """
        function globalHelper()
            return true
        end

        local M = {}

        function M.run()
            globalHelper()
        end

        local function localHelper()
            return false
        end
        """
        let entries = indexLua(source)

        let funcs = entries.filter { $0.kind == .function }
        #expect(funcs.count == 2)
        #expect(funcs.allSatisfy { $0.container == nil })
        let funcNames = Set(funcs.map(\.name))
        #expect(funcNames.contains("globalHelper"))
        #expect(funcNames.contains("localHelper"))

        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 1)
        #expect(methods[0].name == "run")
        #expect(methods[0].container == "M")
    }

    @Test("Comments ignored")
    func handlesCommentsCorrectly() {
        let source = """
        -- function fake() end
        --[[ function alsoFake() end ]]
        function real()
            return true
        end
        """
        let entries = indexLua(source)
        #expect(entries.count == 1)
        #expect(entries[0].name == "real")
        #expect(entries[0].kind == .function)
    }
}

// MARK: - Lua Realistic Tests

@Suite("TreeSitterBackend — Lua Realistic")
struct LuaRealisticTests {

    @Test("Realistic Lua module")
    func parsesRealisticLuaModule() {
        let source = """
        --- A simple logger module.
        local Logger = {}
        Logger.__index = Logger

        function Logger.new(level)
            local self = setmetatable({}, Logger)
            self.level = level or "info"
            self.entries = {}
            return self
        end

        function Logger:log(msg)
            table.insert(self.entries, {level = self.level, message = msg})
        end

        function Logger:warn(msg)
            local old = self.level
            self.level = "warn"
            self:log(msg)
            self.level = old
        end

        function Logger:getEntries()
            return self.entries
        end

        local function formatEntry(entry)
            return string.format("[%s] %s", entry.level, entry.message)
        end

        function Logger:dump()
            for _, entry in ipairs(self.entries) do
                print(formatEntry(entry))
            end
        end

        return Logger
        """
        let entries = indexLua(source)

        // Methods on Logger: new, log, warn, getEntries, dump = 5
        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 5)
        #expect(methods.allSatisfy { $0.container == "Logger" })
        let methodNames = Set(methods.map(\.name))
        #expect(methodNames.contains("new"))
        #expect(methodNames.contains("log"))
        #expect(methodNames.contains("warn"))
        #expect(methodNames.contains("getEntries"))
        #expect(methodNames.contains("dump"))

        // Local function: formatEntry
        let funcs = entries.filter { $0.kind == .function }
        #expect(funcs.count == 1)
        #expect(funcs[0].name == "formatEntry")
        #expect(funcs[0].container == nil)

        // All entries from tree-sitter
        #expect(entries.allSatisfy { $0.engine == "tree-sitter" })
    }

    @Test("Nested table namespacing")
    func parsesNestedTableNamespacing() {
        let source = """
        local utils = {}
        utils.string = {}

        function utils.string.trim(s)
            return s:match("^%s*(.-)%s*$")
        end

        function utils.string.split(s, sep)
            local parts = {}
            for part in s:gmatch("[^" .. sep .. "]+") do
                table.insert(parts, part)
            end
            return parts
        end
        """
        let entries = indexLua(source)
        let methods = entries.filter { $0.kind == .method }
        #expect(methods.count == 2)
        let names = Set(methods.map(\.name))
        #expect(names.contains("trim"))
        #expect(names.contains("split"))

        // Container is the full dotted path "utils.string"
        #expect(methods.allSatisfy { $0.container == "utils.string" })
    }
}

// MARK: - Lua Performance Tests

@Suite("TreeSitterBackend — Lua Performance")
struct LuaPerformanceTests {

    @Test("Lua file parses under 10ms")
    func luaFileParsesUnder10ms() {
        var source = "local M = {}\n\n"
        for i in 0..<30 {
            source += "function M.func_\(i)(x)\n"
            source += "    return x + \(i)\n"
            source += "end\n\n"
        }
        source += "return M\n"
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let entries = indexLua(source)
            #expect(entries.count > 0)
        }
        #expect(elapsed < .milliseconds(10))
    }

    @Test("Lua coexists with other languages")
    func luaCoexistsWithOtherLanguages() {
        let tmpDir = NSTemporaryDirectory() + "senkani-lua-coexist-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        // Lua file
        let luaSource = "local M = {}\nfunction M.greet() end\nfunction helper() end\nreturn M\n"
        try! luaSource.write(toFile: tmpDir + "/mod.lua", atomically: true, encoding: .utf8)

        // Python file
        let pySource = "class Greeter:\n    def greet(self):\n        pass\n"
        try! pySource.write(toFile: tmpDir + "/greeter.py", atomically: true, encoding: .utf8)

        // Bash file
        let bashSource = "#!/bin/bash\nfunction greet() {\n    echo hi\n}\n"
        try! bashSource.write(toFile: tmpDir + "/greet.sh", atomically: true, encoding: .utf8)

        let luaEntries = (try? TreeSitterBackend.index(files: ["mod.lua"], language: "lua", projectRoot: tmpDir)) ?? []
        let pyEntries = (try? TreeSitterBackend.index(files: ["greeter.py"], language: "python", projectRoot: tmpDir)) ?? []
        let bashEntries = (try? TreeSitterBackend.index(files: ["greet.sh"], language: "bash", projectRoot: tmpDir)) ?? []

        #expect(luaEntries.count == 2) // M.greet (method) + helper (function)
        #expect(luaEntries.contains { $0.name == "greet" && $0.kind == .method && $0.container == "M" })
        #expect(luaEntries.contains { $0.name == "helper" && $0.kind == .function })

        #expect(pyEntries.count == 2) // class + method
        #expect(pyEntries.contains { $0.name == "Greeter" && $0.kind == .class })

        #expect(bashEntries.count == 1) // function
        #expect(bashEntries.contains { $0.name == "greet" && $0.kind == .function })
    }
}

// MARK: - Helper

private func indexLua(_ source: String) -> [IndexEntry] {
    let tmpDir = NSTemporaryDirectory() + "senkani-lua-test-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }
    let file = "test.lua"
    try! source.write(toFile: tmpDir + "/" + file, atomically: true, encoding: .utf8)
    return (try? TreeSitterBackend.index(files: [file], language: "lua", projectRoot: tmpDir)) ?? []
}
