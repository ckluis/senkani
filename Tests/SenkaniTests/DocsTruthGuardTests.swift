import Testing
import Foundation

/// Doc-truth guard for the onboarding-p0-docs-truth-pass round.
///
/// Pins the public first-run surfaces — the install/Claude Code/first-session
/// guides, the senkani-init reference, and the README quick-start — against
/// the actual `senkani init` flag set. Procida's red flag was that docs
/// currently break trust before the app gets a chance: a flag that the binary
/// has never accepted (`init --hooks-only`, `init --dry-run`) is worse than
/// no doc at all because it costs the reader a build cycle to find out.
///
/// The check is a negative list — strings that must not appear anywhere
/// inside the surfaces declared in `targets`. Add a case for every claim
/// the next regression will be tempted to write back in.
@Suite("DocsTruthGuard — onboarding P0 first-run docs")
struct DocsTruthGuardTests {

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // .../Tests/SenkaniTests
            .deletingLastPathComponent()  // .../Tests
            .deletingLastPathComponent()  // repo root
    }

    /// Files that ship as the project's first-run trust contract. Adding a
    /// new doc page that explains `senkani init` should land in this list
    /// so the guard covers it too.
    private static let targets: [String] = [
        "README.md",
        "docs/guides/install.html",
        "docs/guides/claude-code.html",
        "docs/guides/cursor-copilot.html",
        "docs/guides/first-session.html",
        "docs/guides.html",
        "docs/reference/cli.html",
        "docs/reference/cli/senkani-init.html",
    ]

    /// Phrase + reason pairs. The reason is shown back to the operator if
    /// the guard fails so they can tell *why* the string was banned without
    /// chasing the spec.
    private static let forbiddenPhrases: [(phrase: String, reason: String)] = [
        ("init --hooks-only",
         "Flag does not exist. `senkani init` is already hooks-only by design (CLI never registers MCP)."),
        ("init --dry-run",
         "Flag does not exist. Init's only flags are --uninstall and --hook-path."),
        ("--hooks-only",
         "Same root cause as 'init --hooks-only': the flag has never shipped on Init."),
        ("--dry-run",
         "Init has no --dry-run. (If a different command grows one, narrow this rule to 'init --dry-run' only.)"),
    ]

    @Test("first-run docs do not advertise senkani init flags that don't exist")
    func noStaleInitFlags() throws {
        let root = Self.repoRoot()
        var failures: [String] = []

        for relPath in Self.targets {
            let url = root.appendingPathComponent(relPath)
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8)
            else {
                failures.append("\(relPath): unreadable / missing")
                continue
            }

            for (phrase, reason) in Self.forbiddenPhrases {
                if text.contains(phrase) {
                    failures.append("\(relPath): contains forbidden phrase \"\(phrase)\" — \(reason)")
                }
            }
        }

        let report = failures.joined(separator: "\n  ")
        #expect(
            failures.isEmpty,
            Comment(rawValue: "Stale first-run doc claims:\n  \(report)")
        )
    }

    @Test("senkani-init reference page names the flags that do exist")
    func initReferenceNamesRealFlags() throws {
        let path = Self.repoRoot()
            .appendingPathComponent("docs/reference/cli/senkani-init.html")
        let text = try String(contentsOf: path, encoding: .utf8)

        // Positive list: the actual flags on `Init` in Sources/CLI/InitCommand.swift.
        // Keep this in sync if the command grows or loses a flag.
        let required = ["--uninstall", "--hook-path"]
        for flag in required {
            #expect(
                text.contains(flag),
                "senkani-init.html must mention real flag \(flag)"
            )
        }
    }
}
