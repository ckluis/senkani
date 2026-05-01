import ArgumentParser
import Core
import Foundation

/// `senkani skill` — manage HandManifest skill packages.
///
/// Two subcommands:
///   - `lint <path>` — validate a HandManifest JSON file.
///   - `export --target <harness> <path>` — emit per-harness output
///     to stdout.
public struct Skill: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "skill",
        abstract: "Manage HandManifest skill packages.",
        subcommands: [Lint.self, Export.self])

    public init() {}

    public struct Lint: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "lint",
            abstract: "Validate a HandManifest JSON file.")

        @Argument(help: "Path to the HandManifest JSON file.")
        public var path: String

        @Flag(name: .long, help: "Print issues as JSON.")
        public var json: Bool = false

        public init() {}

        public func run() throws {
            let url = URL(fileURLWithPath: path)
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                FileHandle.standardError.write(
                    Data("error: could not read \(path): \(error)\n".utf8))
                throw ExitCode(2)
            }

            let issues = HandManifestLinter.lintJSON(data)
            if json {
                let out = SkillCLIIssue.encode(issues)
                print(out)
            } else {
                if issues.isEmpty {
                    print("OK \(path)")
                } else {
                    for issue in issues {
                        let prefix = issue.severity == .error ? "error" : "warn"
                        print("\(prefix) \(issue.path): \(issue.message)")
                    }
                }
            }
            if HandManifestLinter.hasErrors(issues) {
                throw ExitCode(1)
            }
        }
    }

    public struct Export: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "Emit per-harness output for a HandManifest.")

        @Option(name: .long, help: "Target harness: claude-code, cursor, codex, opencode, senkani.")
        public var target: String

        @Argument(help: "Path to the HandManifest JSON file.")
        public var path: String

        public init() {}

        public func run() throws {
            guard let harness = HandHarness(name: target) else {
                FileHandle.standardError.write(Data(
                    "error: unknown target '\(target)'. valid: \(HandHarness.allCases.map(\.rawValue).joined(separator: ", "))\n".utf8))
                throw ExitCode(2)
            }
            let url = URL(fileURLWithPath: path)
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                FileHandle.standardError.write(
                    Data("error: could not read \(path): \(error)\n".utf8))
                throw ExitCode(2)
            }
            let manifest: HandManifest
            do {
                manifest = try JSONDecoder().decode(HandManifest.self, from: data)
            } catch {
                FileHandle.standardError.write(
                    Data("error: could not decode HandManifest: \(error)\n".utf8))
                throw ExitCode(1)
            }
            let issues = HandManifestLinter.lint(manifest)
            if HandManifestLinter.hasErrors(issues) {
                FileHandle.standardError.write(Data(
                    "error: lint failed; refusing to export. run `senkani skill lint` for details.\n".utf8))
                throw ExitCode(1)
            }
            let out = try HandManifestExporter.export(manifest, target: harness)
            print(out, terminator: "")
        }
    }
}

/// JSON shape for `senkani skill lint --json`. Kept as a plain
/// struct so the field names round-trip cleanly without exposing
/// the internal `HandManifestIssue` Codable surface.
struct SkillCLIIssue: Encodable {
    var severity: String
    var path: String
    var message: String

    static func encode(_ issues: [HandManifestIssue]) -> String {
        let payload = issues.map {
            SkillCLIIssue(
                severity: $0.severity.rawValue,
                path: $0.path,
                message: $0.message)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload),
              let s = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return s
    }
}
