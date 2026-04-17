import Testing
import Foundation
import ArgumentParser
@testable import CLI

/// Bach G6: CLI smoke tests.
///
/// Every subcommand registered in `Senkani.configuration.subcommands`
/// must:
///   1. Declare a non-empty `commandName` and `abstract`.
///   2. Render `helpMessage()` without crashing.
///   3. Round-trip through `parseAsRoot([<name>, "--help"])` to the
///      `CleanExit.helpRequest` path — proving the ArgumentParser tree
///      is wired, not just the static config.
///
/// In-process tests, not subprocess spawns — faster, no binary-path
/// assumptions, no flakes from stdout capture. The tradeoff is we miss
/// issues that only surface when `@main` runs (launchd integration,
/// signal handlers) — those remain in `tools/soak/MANUAL_TESTS.md`.
@Suite("CLI smoke — every subcommand")
struct CLISmokeTests {

    // The list of subcommand types, pulled from the same place the
    // `senkani` binary uses. If a new command is added to
    // `Senkani.configuration.subcommands`, every test in this suite
    // picks it up automatically.
    private static let subcommandTypes: [ParsableCommand.Type] = Senkani
        .configuration
        .subcommands

    // Pre-computed roster of (name, typeName) for parameterized @Test
    // reporting. `String` is `Sendable`; `ParsableCommand.Type` isn't
    // Sendable in Swift 6, so we can't pass raw types through
    // `@Test(arguments:)` — names are sufficient for test-report
    // identification.
    private static let subcommandNames: [String] = subcommandTypes.map { type in
        type.configuration.commandName ?? "\(type)"
    }

    // MARK: - Roster sanity

    @Test func rosterIsNonEmpty() {
        #expect(!Self.subcommandTypes.isEmpty,
                "Senkani.configuration.subcommands must register at least one type")
    }

    @Test func everySubcommandHasUniqueName() {
        let names = Self.subcommandNames
        #expect(Set(names).count == names.count,
                "duplicate commandName in subcommands: \(names)")
    }

    // MARK: - Per-subcommand

    @Test func everySubcommandDeclaresName() {
        for type in Self.subcommandTypes {
            let name = type.configuration.commandName ?? ""
            #expect(!name.isEmpty,
                    "subcommand \(type) is missing commandName — ArgumentParser defaults are brittle")
        }
    }

    @Test func everySubcommandDeclaresAbstract() {
        for type in Self.subcommandTypes {
            let abstract = type.configuration.abstract
            #expect(!abstract.isEmpty,
                    "subcommand \(type.configuration.commandName ?? "\(type)") has empty abstract — users need a one-line description")
        }
    }

    @Test func everySubcommandRendersHelpMessage() {
        for type in Self.subcommandTypes {
            let help = type.helpMessage()
            let name = type.configuration.commandName ?? "\(type)"
            #expect(!help.isEmpty, "helpMessage() empty for \(name)")
            #expect(help.contains("USAGE") || help.contains("ARGUMENTS") || help.contains("OPTIONS"),
                    "helpMessage() for \(name) doesn't look like ArgumentParser help, got:\n\(help)")
        }
    }

    @Test func everySubcommandParsesHelpFlag() {
        // parseAsRoot([<name>, "--help"]) must succeed and return an
        // instance — the fact that a command comes back proves the
        // subcommand routing + argument declarations round-trip
        // through ArgumentParser without throwing on the help path.
        // (ArgumentParser handles `--help` internally; the actual
        // help text was already verified by
        // `everySubcommandRendersHelpMessage`.)
        for type in Self.subcommandTypes {
            let name = type.configuration.commandName ?? "\(type)"
            do {
                _ = try Senkani.parseAsRoot([name, "--help"])
            } catch {
                Issue.record("parseAsRoot for \(name) --help threw: \(error)")
            }
        }
    }

    @Test func bogusSubcommandIsRejected() {
        // Inverse: the parser must reject a command name that doesn't
        // exist. Catches regressions where a typo in Senkani.swift's
        // subcommands array could silently shadow a real command.
        var threw = false
        do {
            _ = try Senkani.parseAsRoot(["this-command-does-not-exist-4a7b"])
        } catch {
            threw = true
        }
        #expect(threw, "unknown subcommand must throw a parsing error")
    }
}
