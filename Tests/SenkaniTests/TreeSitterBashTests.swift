import Foundation
import Testing
@testable import Indexer

// MARK: - Bash Parsing Tests

@Suite("TreeSitterBackend — Bash Parsing")
struct BashParsingTests {

    @Test("Function keyword syntax")
    func parsesFunctionKeywordSyntax() {
        let source = """
        function hello() {
            echo 'hi'
        }

        function add() {
            echo $(($1 + $2))
        }
        """
        let entries = indexBash(source)
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.kind == .function })
        #expect(entries.allSatisfy { $0.container == nil })
        let names = Set(entries.map(\.name))
        #expect(names.contains("hello"))
        #expect(names.contains("add"))
    }

    @Test("POSIX syntax")
    func parsesPosixSyntax() {
        let source = """
        hello() {
            echo 'hi'
        }

        add() {
            echo $(($1 + $2))
        }
        """
        let entries = indexBash(source)
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.kind == .function })
        #expect(entries.allSatisfy { $0.container == nil })
        let names = Set(entries.map(\.name))
        #expect(names.contains("hello"))
        #expect(names.contains("add"))
    }

    @Test("Mixed syntax")
    func parsesMixedSyntax() {
        let source = """
        #!/bin/bash
        function setup() {
            mkdir -p /tmp/test
        }

        cleanup() {
            rm -rf /tmp/test
        }

        function main() {
            setup
            cleanup
        }
        """
        let entries = indexBash(source)
        #expect(entries.count == 3)
        #expect(entries.allSatisfy { $0.kind == .function })
        #expect(entries.allSatisfy { $0.container == nil })
        let names = Set(entries.map(\.name))
        #expect(names.contains("setup"))
        #expect(names.contains("cleanup"))
        #expect(names.contains("main"))
    }

    @Test("Ignores variable assignments")
    func ignoresVariableAssignments() {
        let source = """
        FOO=bar
        export BAZ=qux
        declare -a arr=(1 2 3)
        function real() {
            echo $FOO
        }
        """
        let entries = indexBash(source)
        #expect(entries.count == 1)
        #expect(entries[0].name == "real")
        #expect(entries[0].kind == .function)
    }

    @Test("Ignores source and aliases")
    func ignoresSourceAndAliases() {
        let source = """
        source ./helpers.sh
        . ./other.sh
        alias ll='ls -la'
        function real() {
            ll
        }
        """
        let entries = indexBash(source)
        #expect(entries.count == 1)
        #expect(entries[0].name == "real")
        #expect(entries[0].kind == .function)
    }

    @Test("Comments ignored")
    func handlesCommentsCorrectly() {
        let source = """
        # function fake() { echo nope; }
        # fake_func() { echo also_nope; }
        function real() {
            echo yes
        }
        """
        let entries = indexBash(source)
        #expect(entries.count == 1)
        #expect(entries[0].name == "real")
        #expect(entries[0].kind == .function)
    }

    @Test("Shebang and comments")
    func handlesShebangAndComments() {
        let source = """
        #!/usr/bin/env bash
        set -euo pipefail

        # Setup function
        function setup() {
            echo 'setting up'
        }
        """
        let entries = indexBash(source)
        #expect(entries.count == 1)
        #expect(entries[0].name == "setup")
        #expect(entries[0].kind == .function)
    }
}

// MARK: - Bash Realistic Tests

@Suite("TreeSitterBackend — Bash Realistic")
struct BashRealisticTests {

    @Test("Realistic Bash script")
    func parsesRealisticBashScript() {
        let source = """
        #!/usr/bin/env bash
        set -euo pipefail

        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        LOG_FILE="/tmp/deploy.log"
        VERBOSE=false

        function log() {
            local msg="$1"
            echo "[$(date)] $msg" >> "$LOG_FILE"
        }

        function check_deps() {
            command -v git >/dev/null 2>&1 || { echo "git required"; exit 1; }
            command -v docker >/dev/null 2>&1 || { echo "docker required"; exit 1; }
        }

        build() {
            log "Building..."
            docker build -t myapp .
        }

        function deploy() {
            log "Deploying..."
            if [ "$VERBOSE" = true ]; then
                echo "Verbose deploy"
            fi
            docker push myapp
        }

        cleanup() {
            log "Cleaning up..."
            rm -rf /tmp/build-*
        }

        function main() {
            check_deps
            build
            deploy
            cleanup
            log "Done"
        }

        main "$@"
        """
        let entries = indexBash(source)

        // Should find: log, check_deps, build, deploy, cleanup, main = 6 functions
        #expect(entries.count == 6)
        #expect(entries.allSatisfy { $0.kind == .function })
        #expect(entries.allSatisfy { $0.container == nil })

        let names = Set(entries.map(\.name))
        #expect(names.contains("log"))
        #expect(names.contains("check_deps"))
        #expect(names.contains("build"))
        #expect(names.contains("deploy"))
        #expect(names.contains("cleanup"))
        #expect(names.contains("main"))

        // Variables, source, aliases, and the main "$@" call should NOT appear
        #expect(!names.contains("SCRIPT_DIR"))
        #expect(!names.contains("LOG_FILE"))
        #expect(!names.contains("VERBOSE"))

        // All entries from tree-sitter
        #expect(entries.allSatisfy { $0.engine == "tree-sitter" })
    }
}

// MARK: - Bash Performance Tests

@Suite("TreeSitterBackend — Bash Performance")
struct BashPerformanceTests {

    @Test("Bash file parses under 10ms")
    func bashFileParsesUnder10ms() {
        var source = "#!/bin/bash\nset -euo pipefail\n\n"
        for i in 0..<30 {
            source += "function func_\(i)() {\n"
            source += "    local result=$1\n"
            source += "    echo \"Running func_\(i) with $result\"\n"
            source += "    return 0\n"
            source += "}\n\n"
        }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let entries = indexBash(source)
            #expect(entries.count > 0)
        }
        #expect(elapsed < .milliseconds(10))
    }
}

// MARK: - Helper

private func indexBash(_ source: String) -> [IndexEntry] {
    let tmpDir = NSTemporaryDirectory() + "senkani-bash-test-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }
    let file = "test.sh"
    try! source.write(toFile: tmpDir + "/" + file, atomically: true, encoding: .utf8)
    return (try? TreeSitterBackend.index(files: [file], language: "bash", projectRoot: tmpDir)) ?? []
}
