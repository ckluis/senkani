import Testing
@testable import Filter

@Suite("FilterEngine") struct FilterEngineTests {
    let engine = FilterEngine()

    @Test func gitStatus() {
        let output = "\u{1B}[32mOn branch main\u{1B}[0m\n\n\n\nnothing to commit"
        let result = engine.filter(command: "git status", output: output)
        #expect(result.wasFiltered)
        #expect(!result.output.contains("\u{1B}"))  // ANSI stripped
        #expect(result.output.contains("On branch main"))
        #expect(result.filteredBytes < result.rawBytes)
    }

    @Test func npmInstall() {
        var lines = [String]()
        for i in 0..<50 {
            lines.append("added package-\(i) 1.0.0")
        }
        lines.append("WARN deprecated something")
        lines.append("added 50 packages in 3s")
        let output = lines.joined(separator: "\n")

        let result = engine.filter(command: "npm install", output: output)
        #expect(result.wasFiltered)
        #expect(result.filteredBytes < result.rawBytes)
    }

    @Test func unknownCommand() {
        let output = "hello world"
        let result = engine.filter(command: "myweirdtool run", output: output)
        #expect(!result.wasFiltered)
        #expect(result.output == output)
        #expect(result.rawBytes == result.filteredBytes)
    }

    @Test func emptyCommand() {
        let result = engine.filter(command: "", output: "test")
        #expect(!result.wasFiltered)
    }

    @Test func gitClone() {
        let output = """
        Cloning into 'repo'...
        remote: Counting objects: 100
        remote: Compressing objects: 100% (80/80)
        Receiving objects: 100% (200/200), 1.5 MiB
        Resolving deltas: 100% (150/150)
        """
        let result = engine.filter(command: "git clone https://github.com/test/repo", output: output)
        #expect(result.wasFiltered)
        #expect(!result.output.contains("Receiving objects"))
        #expect(!result.output.contains("Resolving deltas"))
    }

    @Test func savingsCalc() {
        let output = String(repeating: "x", count: 1000)
        let result = engine.filter(command: "git log", output: output)
        if result.wasFiltered {
            #expect(result.savingsPercent > 0)
            #expect(result.savingsPercent <= 100)
        }
    }

    @Test func commandPreserved() {
        let result = engine.filter(command: "git status", output: "test")
        #expect(result.command == "git status")
    }

    @Test func sudoWrapped() {
        let output = "\u{1B}[32mOn branch main\u{1B}[0m"
        let result = engine.filter(command: "sudo git status", output: output)
        #expect(result.wasFiltered)
        #expect(!result.output.contains("\u{1B}"))
    }
}
