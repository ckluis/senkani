import Testing
import Foundation
@testable import Core

/// Pane diary injection glue — round 3 of 3.
///
/// Tests the env-read + disk-read seam that MCPSession calls into on
/// pane-open (read) and session-shutdown (write). Every test uses a
/// disposable temp HOME so no real `~/.senkani/diaries/` is touched.
@Suite("PaneDiaryInjection") struct PaneDiaryInjectionTests {

    // MARK: - Fixtures

    private func withTempHome<T>(_ body: (String) throws -> T) throws -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("senkani-pane-injection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try body(dir.path)
    }

    private func row(
        id: Int64 = 1,
        offset: TimeInterval = 0,
        tool: String? = "read",
        command: String? = nil,
        input: Int = 20,
        output: Int = 10
    ) -> SessionDatabase.TimelineEvent {
        SessionDatabase.TimelineEvent(
            id: id,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            source: "mcp_tool",
            toolName: tool,
            feature: nil,
            command: command,
            inputTokens: input,
            outputTokens: output,
            savedTokens: 0,
            costCents: 0
        )
    }

    // MARK: - Read side

    @Test func injectsBriefWhenPriorDiaryExists() throws {
        try withTempHome { home in
            // Seed a diary on disk for (ws=senkani, pane=terminal).
            try PaneDiaryStore.write(
                "Last time in 'terminal':\nLast: swift build\nFiles: Foo.swift",
                workspaceSlug: "senkani",
                paneSlug: "terminal",
                home: home,
                env: [:]
            )

            let env: [String: String] = [
                "SENKANI_WORKSPACE_SLUG": "senkani",
                "SENKANI_PANE_SLUG": "terminal",
            ]
            let section = PaneDiaryInjection.instructionsSection(
                env: env, home: home
            )
            #expect(section.hasPrefix("\n\nPane context:\n"))
            #expect(section.contains("Last: swift build"))
            #expect(section.contains("Files: Foo.swift"))
        }
    }

    @Test func envOffProducesEmptySection() throws {
        try withTempHome { home in
            // Diary exists on disk — but env gate is OFF.
            try PaneDiaryStore.write(
                "hidden pane memory",
                workspaceSlug: "senkani",
                paneSlug: "terminal",
                home: home,
                env: [:]
            )

            let env: [String: String] = [
                "SENKANI_WORKSPACE_SLUG": "senkani",
                "SENKANI_PANE_SLUG": "terminal",
                "SENKANI_PANE_DIARY": "off",
            ]
            let section = PaneDiaryInjection.instructionsSection(
                env: env, home: home
            )
            #expect(section == "")
        }
    }

    @Test func missingSlugEnvVarsProduceEmptySection() throws {
        try withTempHome { home in
            // No slug env — injection must not touch disk at all.
            let section = PaneDiaryInjection.instructionsSection(
                env: [:], home: home
            )
            #expect(section == "")

            // Only one of the two present is also empty.
            let partial: [String: String] = [
                "SENKANI_WORKSPACE_SLUG": "senkani",
            ]
            #expect(PaneDiaryInjection.instructionsSection(
                env: partial, home: home) == "")
        }
    }

    @Test func noDiaryOnDiskProducesEmptySection() throws {
        try withTempHome { home in
            // Slug env present, env-on, but no diary file exists.
            let env: [String: String] = [
                "SENKANI_WORKSPACE_SLUG": "senkani",
                "SENKANI_PANE_SLUG": "terminal",
            ]
            let section = PaneDiaryInjection.instructionsSection(
                env: env, home: home
            )
            #expect(section == "")
        }
    }

    @Test func malformedSlugDegradesToEmpty() throws {
        try withTempHome { home in
            // Slug contains `..` — PaneDiaryStore.read throws. Injection
            // swallows the error and returns "" (pane-open must not
            // hang on a bad diary).
            let env: [String: String] = [
                "SENKANI_WORKSPACE_SLUG": "..",
                "SENKANI_PANE_SLUG": "terminal",
            ]
            let section = PaneDiaryInjection.instructionsSection(
                env: env, home: home
            )
            #expect(section == "")
        }
    }

    // MARK: - Write side

    @Test func persistWritesDiaryFromRows() throws {
        try withTempHome { home in
            let rows = [
                row(id: 1, offset: 20, tool: "read",
                    command: "/proj/Main.swift", input: 80, output: 20),
                row(id: 2, offset: 10, tool: "edit",
                    command: "/proj/Pane.swift", input: 40, output: 30),
            ]
            let env: [String: String] = [
                "SENKANI_WORKSPACE_SLUG": "senkani",
                "SENKANI_PANE_SLUG": "terminal",
            ]
            let wrote = PaneDiaryInjection.persist(
                rows: rows, env: env, home: home
            )
            #expect(wrote == true)

            // Read it back through the store to verify it landed.
            let got = try PaneDiaryStore.read(
                workspaceSlug: "senkani",
                paneSlug: "terminal",
                home: home,
                env: [:]
            )
            #expect(got != nil)
            #expect(got?.contains("Last time in 'terminal':") == true)
            #expect(got?.contains("Last: /proj/Main.swift") == true)
            #expect(got?.contains("Files: Main.swift, Pane.swift") == true)
        }
    }

    @Test func persistIsNoOpWhenEnvOff() throws {
        try withTempHome { home in
            let rows = [
                row(id: 1, offset: 10, tool: "read",
                    command: "/proj/Main.swift"),
            ]
            let env: [String: String] = [
                "SENKANI_WORKSPACE_SLUG": "senkani",
                "SENKANI_PANE_SLUG": "terminal",
                "SENKANI_PANE_DIARY": "off",
            ]
            let wrote = PaneDiaryInjection.persist(
                rows: rows, env: env, home: home
            )
            #expect(wrote == false)

            // No file should exist on disk.
            let path = PaneDiaryStore.diaryPath(
                workspaceSlug: "senkani",
                paneSlug: "terminal",
                home: home
            )
            #expect(!FileManager.default.fileExists(atPath: path))
        }
    }

    @Test func persistIsNoOpWhenSlugsMissing() throws {
        try withTempHome { home in
            let rows = [
                row(id: 1, offset: 10, tool: "read",
                    command: "/proj/Main.swift"),
            ]
            let wrote = PaneDiaryInjection.persist(
                rows: rows, env: [:], home: home
            )
            #expect(wrote == false)

            // Dir should not even exist — injection never touched disk.
            let dir = (home as NSString)
                .appendingPathComponent(".senkani/diaries")
            #expect(!FileManager.default.fileExists(atPath: dir))
        }
    }

    @Test func persistIsNoOpWhenRowsEmptyAndNoError() throws {
        try withTempHome { home in
            let env: [String: String] = [
                "SENKANI_WORKSPACE_SLUG": "senkani",
                "SENKANI_PANE_SLUG": "terminal",
            ]
            let wrote = PaneDiaryInjection.persist(
                rows: [], env: env, home: home
            )
            #expect(wrote == false)
        }
    }

    // MARK: - Round-trip

    @Test func roundTripPersistThenInject() throws {
        try withTempHome { home in
            let env: [String: String] = [
                "SENKANI_WORKSPACE_SLUG": "roundtrip",
                "SENKANI_PANE_SLUG": "dashboard",
            ]
            let rows = [
                row(id: 1, offset: 5, tool: "read",
                    command: "/proj/A.swift", input: 50, output: 20),
                row(id: 2, offset: 1, tool: "edit",
                    command: "/proj/B.swift", input: 40, output: 30),
            ]
            #expect(PaneDiaryInjection.persist(
                rows: rows, env: env, home: home) == true)

            let section = PaneDiaryInjection.instructionsSection(
                env: env, home: home
            )
            #expect(section.hasPrefix("\n\nPane context:\n"))
            #expect(section.contains("Last time in 'dashboard':"))
            #expect(section.contains("A.swift"))
            #expect(section.contains("B.swift"))
        }
    }
}
