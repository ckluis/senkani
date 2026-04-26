import Testing
import Foundation
@testable import Indexer

@Suite("RegexBackend")
struct RegexBackendTests {
    @Test func swiftFunctions() {
        let code = """
        import Foundation

        public func doSomething() {
            print("hello")
        }

        private func helper(_ x: Int) -> Bool {
            return x > 0
        }
        """
        let entries = indexCode(code, language: "swift")
        #expect(entries.count == 2)
        #expect(entries[0].name == "doSomething")
        #expect(entries[0].kind == .function)
        #expect(entries[1].name == "helper")
    }

    @Test func swiftTypes() {
        let code = """
        public final class FilterEngine: Sendable {
            func filter() {}
        }

        struct FilterResult: Sendable {
            let output: String
        }

        enum SymbolKind: String {
            case function
        }

        protocol Indexable {
            func index()
        }
        """
        let entries = indexCode(code, language: "swift")
        let kinds = Set(entries.map(\.kind))
        #expect(kinds.contains(.class))
        #expect(kinds.contains(.struct))
        #expect(kinds.contains(.enum))
        #expect(kinds.contains(.protocol))
    }

    @Test func pythonDeclarations() {
        let code = """
        def hello():
            pass

        class MyClass:
            def method(self):
                pass

        async def fetch_data():
            pass
        """
        let entries = indexCode(code, language: "python")
        // Note: indented `def method(self)` matches too since regex uses anchorsMatchLines
        #expect(entries.count >= 3)
        #expect(entries.contains { $0.name == "hello" && $0.kind == .function })
        #expect(entries.contains { $0.name == "MyClass" && $0.kind == .class })
        #expect(entries.contains { $0.name == "fetch_data" && $0.kind == .function })
    }

    @Test func typescriptDeclarations() {
        let code = """
        export function handleRequest(req: Request) {}
        export class UserService {}
        export interface User { name: string }
        export type Config = { debug: boolean }
        export const processData = async (data: string) => {}
        """
        let entries = indexCode(code, language: "typescript")
        #expect(entries.count >= 4)
        #expect(entries.contains { $0.name == "handleRequest" })
        #expect(entries.contains { $0.name == "UserService" })
        #expect(entries.contains { $0.name == "User" })
    }

    @Test func goDeclarations() {
        let code = """
        func main() {}
        func (s *Server) HandleRequest(w http.ResponseWriter) {}
        type Config struct {}
        type Handler interface {}
        """
        let entries = indexCode(code, language: "go")
        #expect(entries.contains { $0.name == "main" && $0.kind == .function })
        #expect(entries.contains { $0.name == "HandleRequest" && $0.kind == .method })
        #expect(entries.contains { $0.name == "Config" && $0.kind == .struct })
    }

    @Test func emptyFile() {
        let entries = indexCode("", language: "swift")
        #expect(entries.isEmpty)
    }

    @Test func unknownLanguage() {
        let entries = indexCode("whatever", language: "brainfuck")
        #expect(entries.isEmpty)
    }

    // Helper: write code to a temp file and index it
    private func indexCode(_ code: String, language: String) -> [IndexEntry] {
        let ext: String
        switch language {
        case "swift": ext = "swift"
        case "python": ext = "py"
        case "typescript": ext = "ts"
        case "go": ext = "go"
        case "rust": ext = "rs"
        default: ext = "txt"
        }

        let tmpDir = NSTemporaryDirectory() + "senkani-test-\(UUID().uuidString)"
        let filePath = "test.\(ext)"
        let fullPath = tmpDir + "/" + filePath

        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        try? code.write(toFile: fullPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        return (try? RegexBackend.index(files: [filePath], language: language, projectRoot: tmpDir)) ?? []
    }
}
