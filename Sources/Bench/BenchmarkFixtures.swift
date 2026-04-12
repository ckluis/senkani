import Foundation

/// Static test fixtures for benchmark tasks.
/// These are representative outputs from common commands — realistic enough
/// to exercise the filter rules but small enough to embed in source.
enum Fixtures {

    /// A `git clone` output with progress lines that the filter strips.
    /// Rule: stripANSI + stripMatching("Receiving objects") + stripMatching("Resolving deltas")
    ///       + stripMatching("remote: Counting") + stripMatching("remote: Compressing") + groupSimilar(3)
    static let gitClone: String = {
        var lines: [String] = []
        lines.append("Cloning into 'my-project'...")
        lines.append("\u{1B}[33mremote: Counting objects: 2450, done.\u{1B}[0m")
        lines.append("\u{1B}[33mremote: Compressing objects: 100% (1200/1200), done.\u{1B}[0m")
        for i in 0..<80 {
            lines.append("\u{1B}[32mReceiving objects: \(i)% (\(i * 25)/2450)\u{1B}[0m")
        }
        for i in 0..<40 {
            lines.append("\u{1B}[32mResolving deltas: \(i)% (\(i * 10)/400)\u{1B}[0m")
        }
        lines.append("Checking connectivity... done.")
        return lines.joined(separator: "\n")
    }()

    /// A `npm install` output with WARN and "added" lines the filter strips.
    /// Rule: stripANSI + stripMatching("added ") + stripMatching("WARN") + groupSimilar(5) + tail(30)
    static let npmInstall: String = {
        var lines: [String] = []
        lines.append("\u{1B}[33mnpm\u{1B}[0m \u{1B}[33mWARN\u{1B}[0m deprecated inflight@1.0.6: This module is not supported")
        lines.append("\u{1B}[33mnpm\u{1B}[0m \u{1B}[33mWARN\u{1B}[0m deprecated rimraf@3.0.2: Rimraf versions prior to v4 are no longer supported")
        lines.append("\u{1B}[33mnpm\u{1B}[0m \u{1B}[33mWARN\u{1B}[0m deprecated glob@7.2.0: Glob versions prior to v9 are no longer supported")
        for i in 0..<120 {
            lines.append("\u{1B}[33mnpm\u{1B}[0m \u{1B}[33mWARN\u{1B}[0m optional dependency skipped: fsevents@\(i).0.0")
        }
        lines.append("")
        lines.append("added 847 packages, and audited 848 packages in 32s")
        lines.append("")
        lines.append("120 packages are looking for funding")
        lines.append("  run `npm fund` for details")
        lines.append("")
        lines.append("found 0 vulnerabilities")
        return lines.joined(separator: "\n")
    }()

    /// A `cargo build` output with many "Compiling" and "Downloading" lines.
    /// Rule: stripANSI + stripMatching("Compiling") + stripMatching("Downloading") + groupSimilar(3) + tail(40)
    static let cargoBuild: String = {
        var lines: [String] = []
        for i in 0..<60 {
            lines.append("   \u{1B}[32mDownloading\u{1B}[0m crate_\(i) v0.\(i).0")
        }
        for i in 0..<120 {
            lines.append("   \u{1B}[32mCompiling\u{1B}[0m module_\(i) v0.\(i).0")
        }
        lines.append("    \u{1B}[32mFinished\u{1B}[0m dev [unoptimized + debuginfo] target(s) in 45.23s")
        return lines.joined(separator: "\n")
    }()

    /// A typical npm test output — 500 lines of test names, most passing.
    static let npmTest: String = {
        var lines: [String] = []
        lines.append("> senkani@0.1.0 test")
        lines.append("> jest --verbose")
        lines.append("")
        for i in 0..<150 {
            lines.append("  \u{2713} Component\(i) renders correctly (12ms)")
        }
        for i in 0..<2 {
            lines.append("  \u{2717} Component\(i + 150) handles edge case")
            lines.append("    Error: expected 42, got 41")
            lines.append("      at Object.<anonymous> (src/component\(i).test.ts:23:45)")
        }
        lines.append("")
        lines.append("Test Suites: 1 passed, 1 total")
        lines.append("Tests:       148 passed, 2 failed, 150 total")
        lines.append("Snapshots:   0 total")
        lines.append("Time:        45.2 s")
        return lines.joined(separator: "\n")
    }()

    /// Output containing fake API keys and tokens that should be redacted.
    static let secretsOutput = """
        Loaded config from ~/.env:
          ANTHROPIC_API_KEY=sk-ant-api03-FAKE0123456789abcdefFAKE0123456789abcdef
          AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
          GITHUB_TOKEN=ghp_FAKE0123456789abcdefFAKE0123456789abcde
          Authorization: Bearer eyJFAKE0123456789abcdef.payload.FAKEsignature0123
        Connecting to api.anthropic.com with sk-ant-api03-SECOND0123456789abcdef
        """

    /// A realistic 500-line command output for sandbox tests.
    static let largeExecOutput: String = {
        var lines: [String] = ["$ find /usr/local/lib -name '*.dylib' | head -500"]
        for i in 0..<499 {
            lines.append("/usr/local/lib/library_\(i).dylib")
        }
        return lines.joined(separator: "\n")
    }()

    /// Verbose MCP instructions (~200 tokens).
    static let verboseInstructions = """
        You are operating inside the Senkani MCP environment. Please prefer to use \
        senkani_read instead of the built-in Read tool for file access, because it \
        provides automatic caching, compression, and secret detection. Subsequent \
        re-reads of the same file cost 0 tokens due to caching. For shell command \
        execution, please prefer senkani_exec over the built-in Bash tool because \
        it applies command-specific filter rules that reduce output size by 60-90 \
        percent on average. For code search, prefer senkani_search which returns \
        compact symbol-level results rather than entire file contents. For symbol \
        fetching, prefer senkani_fetch which returns only the relevant symbol lines \
        rather than the whole file.
        """

    /// Terse equivalent (~45 tokens).
    static let terseInstructions = "Use senkani_* tools. Cache, compress, index. Re-reads free."

    /// A representative Swift source file (~1KB) used for cache/indexer baseline tasks.
    static let sampleSwiftFile = """
        import Foundation

        public struct User: Codable, Sendable {
            public let id: UUID
            public let name: String
            public let email: String
            public let createdAt: Date

            public init(id: UUID = UUID(), name: String, email: String, createdAt: Date = Date()) {
                self.id = id
                self.name = name
                self.email = email
                self.createdAt = createdAt
            }

            public func greeting() -> String {
                return "Hello, \\(name)!"
            }

            public func displayEmail() -> String {
                return "\\(name) <\\(email)>"
            }
        }

        public protocol UserRepository {
            func find(id: UUID) async throws -> User?
            func save(_ user: User) async throws
            func delete(id: UUID) async throws
            func list(limit: Int) async throws -> [User]
        }

        public final class InMemoryUserRepository: UserRepository {
            private var users: [UUID: User] = [:]
            private let lock = NSLock()

            public init() {}

            public func find(id: UUID) async throws -> User? {
                lock.lock()
                defer { lock.unlock() }
                return users[id]
            }

            public func save(_ user: User) async throws {
                lock.lock()
                users[user.id] = user
                lock.unlock()
            }

            public func delete(id: UUID) async throws {
                lock.lock()
                users.removeValue(forKey: id)
                lock.unlock()
            }

            public func list(limit: Int) async throws -> [User] {
                lock.lock()
                defer { lock.unlock() }
                return Array(users.values.prefix(limit))
            }
        }
        """

    /// Simulated baseline bytes for the symbol search task: what an agent would
    /// pay to grep through all files of a typical codebase. 80 files * 2KB avg = 160KB.
    static let indexerBaselineBytes = 160_000
}
