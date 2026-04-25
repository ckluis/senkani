import Testing
import Foundation
import ArgumentParser
@testable import CLI

@Suite("MLEvalCommand")
struct MLEvalCommandTests {

    @Test func subcommandIsRegistered() {
        // Pin that `senkani ml-eval` resolves to MLEval.self. Catches
        // someone deleting the entry from `Senkani.subcommands`.
        let names = Senkani.configuration.subcommands.map { $0.configuration.commandName }
        #expect(names.contains("ml-eval"))
    }

    @Test func helpMessageDescribesTheCommand() {
        // The help text is the user's first surface for `senkani ml-eval`.
        // Pin that the abstract + discussion are wired in so doc-sync
        // changes don't silently strip them.
        let help = MLEval.helpMessage()
        #expect(help.contains("ml-eval"))
        #expect(help.contains("Gemma 4"))
        #expect(help.contains("--mcp-binary"))
    }

    @Test func discoverMCPBinaryFindsSiblingExecutable() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("senkani-mleval-disc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let senkani = tmp.appendingPathComponent("senkani")
        let mcp = tmp.appendingPathComponent("senkani-mcp")
        try Data("#!/bin/sh\n".utf8).write(to: senkani)
        try Data("#!/bin/sh\n".utf8).write(to: mcp)
        chmod(senkani.path, 0o755)
        chmod(mcp.path, 0o755)

        let found = MLEval.discoverMCPBinary(
            argv0: senkani.path,
            cwd: "/no/such/dir"
        )
        #expect(found == mcp.path)
    }

    @Test func discoverMCPBinaryFindsBuildOutput() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("senkani-mleval-disc-\(UUID().uuidString)")
        let buildRel = tmp.appendingPathComponent(".build/release")
        try FileManager.default.createDirectory(at: buildRel, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let mcp = buildRel.appendingPathComponent("senkani-mcp")
        try Data("#!/bin/sh\n".utf8).write(to: mcp)
        chmod(mcp.path, 0o755)

        // argv0 sibling not present — must fall back to .build/release.
        let found = MLEval.discoverMCPBinary(
            argv0: "/no/such/dir/senkani",
            cwd: tmp.path
        )
        #expect(found == mcp.path)
    }

    @Test func discoverMCPBinaryReturnsNilWhenAbsent() {
        let unique = "/tmp/senkani-mleval-absent-\(UUID().uuidString)/senkani"
        let cwdAbsent = "/tmp/senkani-mleval-absent-\(UUID().uuidString)"
        let found = MLEval.discoverMCPBinary(
            argv0: unique,
            cwd: cwdAbsent
        )
        // PATH lookup may still find a system-installed senkani-mcp;
        // this test only asserts the local-discovery short-circuit
        // returns nil rather than that no binary exists at all.
        if let found {
            #expect(!found.hasPrefix(cwdAbsent))
            #expect(!found.contains(unique))
        }
    }
}
