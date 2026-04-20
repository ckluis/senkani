import Testing
import Foundation
@testable import Core

/// Pane diary store — I/O half (round 1 of 3).
///
/// Covers the acceptance matrix: round-trip, env-off short-circuit,
/// redaction at write, redaction at read, pane-slug keying, atomic-
/// write crash simulation, slug rejection. Tests use real temp HOME
/// fixtures (no mocks) — the atomic-write path wants a real filesystem.
@Suite("PaneDiaryStore") struct PaneDiaryStoreTests {

    // MARK: - Fixtures

    /// Spin up a disposable HOME, run the body, best-effort clean up.
    /// Every test keeps its FS effects inside its own tempdir.
    private func withTempHome<T>(_ body: (String) throws -> T) throws -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("senkani-pane-diary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try body(dir.path)
    }

    // MARK: - Round-trip

    @Test func roundTripReadMatchesWrite() throws {
        try withTempHome { home in
            let body = "## Diary\n- opened src/Main.swift\n- ran tests\n"
            try PaneDiaryStore.write(
                body,
                workspaceSlug: "proj-senkani",
                paneSlug: "chat-main",
                home: home,
                env: [:])
            let got = try PaneDiaryStore.read(
                workspaceSlug: "proj-senkani",
                paneSlug: "chat-main",
                home: home,
                env: [:])
            #expect(got == body)

            let path = PaneDiaryStore.diaryPath(
                workspaceSlug: "proj-senkani",
                paneSlug: "chat-main",
                home: home)
            #expect(FileManager.default.fileExists(atPath: path))
        }
    }

    // MARK: - Env gate

    @Test func envOffShortCircuits() throws {
        try withTempHome { home in
            // Write under env=off → no file, no throw.
            try PaneDiaryStore.write(
                "should not persist",
                workspaceSlug: "w",
                paneSlug: "p",
                home: home,
                env: ["SENKANI_PANE_DIARY": "off"])
            let path = PaneDiaryStore.diaryPath(
                workspaceSlug: "w", paneSlug: "p", home: home)
            #expect(!FileManager.default.fileExists(atPath: path))

            // Now write with env on so a file IS on disk.
            try PaneDiaryStore.write(
                "real content",
                workspaceSlug: "w",
                paneSlug: "p",
                home: home,
                env: [:])
            #expect(FileManager.default.fileExists(atPath: path))

            // Read under env=off → returns nil even though the file exists.
            let readOff = try PaneDiaryStore.read(
                workspaceSlug: "w",
                paneSlug: "p",
                home: home,
                env: ["SENKANI_PANE_DIARY": "OFF"])
            #expect(readOff == nil)

            // Delete under env=off → file stays put.
            try PaneDiaryStore.delete(
                workspaceSlug: "w",
                paneSlug: "p",
                home: home,
                env: ["SENKANI_PANE_DIARY": "off"])
            #expect(FileManager.default.fileExists(atPath: path))

            // Unset / unknown-value env keys leave the feature enabled.
            #expect(PaneDiaryStore.isEnabled(env: [:]))
            #expect(PaneDiaryStore.isEnabled(env: ["SENKANI_PANE_DIARY": "whatever"]))
            #expect(!PaneDiaryStore.isEnabled(env: ["SENKANI_PANE_DIARY": "off"]))
        }
    }

    // MARK: - Redaction at write

    @Test func writeRedactsSecrets() throws {
        try withTempHome { home in
            let secret = "sk-ant-abcdefghijklmnopqrstuvwxyz0123456789"
            let body = "ran query with key=\(secret)\nmore text\n"
            try PaneDiaryStore.write(
                body,
                workspaceSlug: "w",
                paneSlug: "p",
                home: home,
                env: [:])

            let path = PaneDiaryStore.diaryPath(
                workspaceSlug: "w", paneSlug: "p", home: home)
            let onDisk = try String(
                contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            #expect(!onDisk.contains(secret))
            #expect(onDisk.contains("[REDACTED:ANTHROPIC_API_KEY]"))
        }
    }

    // MARK: - Redaction at read (defense-in-depth)

    @Test func readRedactsPreSeededSecret() throws {
        try withTempHome { home in
            // Write a raw file directly (simulates a hand-edited diary
            // or a file from an older senkani whose regex set missed
            // the pattern the current version catches).
            let secret = "sk-proj-ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
            let raw = "line1\nkey=\(secret)\nline3\n"
            let path = PaneDiaryStore.diaryPath(
                workspaceSlug: "w", paneSlug: "p", home: home)
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            try Data(raw.utf8).write(
                to: URL(fileURLWithPath: path), options: .atomic)

            let got = try PaneDiaryStore.read(
                workspaceSlug: "w",
                paneSlug: "p",
                home: home,
                env: [:])
            #expect(got != nil)
            #expect(got?.contains(secret) == false)
            #expect(got?.contains("[REDACTED:OPENAI_PROJECT_KEY]") == true)
        }
    }

    // MARK: - Pane-slug keying

    @Test func slugsKeepDiariesIsolated() throws {
        try withTempHome { home in
            try PaneDiaryStore.write(
                "alpha content",
                workspaceSlug: "proj",
                paneSlug: "alpha",
                home: home,
                env: [:])
            try PaneDiaryStore.write(
                "beta content",
                workspaceSlug: "proj",
                paneSlug: "beta",
                home: home,
                env: [:])
            try PaneDiaryStore.write(
                "other-proj content",
                workspaceSlug: "other",
                paneSlug: "alpha",
                home: home,
                env: [:])

            #expect(try PaneDiaryStore.read(
                workspaceSlug: "proj", paneSlug: "alpha",
                home: home, env: [:]) == "alpha content")
            #expect(try PaneDiaryStore.read(
                workspaceSlug: "proj", paneSlug: "beta",
                home: home, env: [:]) == "beta content")
            #expect(try PaneDiaryStore.read(
                workspaceSlug: "other", paneSlug: "alpha",
                home: home, env: [:]) == "other-proj content")

            // Delete one, the others stay.
            try PaneDiaryStore.delete(
                workspaceSlug: "proj", paneSlug: "beta",
                home: home, env: [:])
            #expect(try PaneDiaryStore.read(
                workspaceSlug: "proj", paneSlug: "beta",
                home: home, env: [:]) == nil)
            #expect(try PaneDiaryStore.read(
                workspaceSlug: "proj", paneSlug: "alpha",
                home: home, env: [:]) == "alpha content")
        }
    }

    // MARK: - Atomic-write crash simulation

    @Test func failedWriteLeavesExistingContentIntact() throws {
        try withTempHome { home in
            // First write succeeds.
            try PaneDiaryStore.write(
                "baseline good content",
                workspaceSlug: "w",
                paneSlug: "p",
                home: home,
                env: [:])
            let path = PaneDiaryStore.diaryPath(
                workspaceSlug: "w", paneSlug: "p", home: home)
            #expect(FileManager.default.fileExists(atPath: path))

            // Simulate a crashed write: lock the parent dir read-only
            // so the temp-file write fails. Must restore the mode in
            // defer or the defer cleanup in withTempHome can't rm.
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
            _ = chmod(dir.path, 0o500)
            defer { _ = chmod(dir.path, 0o755) }

            // Write should throw `writeFailed`.
            var threw = false
            do {
                try PaneDiaryStore.write(
                    "replacement content that should NOT land",
                    workspaceSlug: "w",
                    paneSlug: "p",
                    home: home,
                    env: [:])
            } catch PaneDiaryStore.StoreError.writeFailed {
                threw = true
            }
            #expect(threw)

            // Crucially, the existing file is unchanged.
            let onDisk = try String(
                contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            #expect(onDisk == "baseline good content")
        }
    }

    // MARK: - Slug rejection

    @Test func badSlugsRejectedBeforeDisk() throws {
        try withTempHome { home in
            func expectInvalid(
                _ ws: String, _ pane: String, _ fail: String
            ) {
                var caught: PaneDiaryStore.StoreError? = nil
                do {
                    try PaneDiaryStore.write(
                        "x", workspaceSlug: ws, paneSlug: pane,
                        home: home, env: [:])
                } catch let e as PaneDiaryStore.StoreError {
                    caught = e
                } catch {}
                switch caught {
                case .invalidSlug(let field, _):
                    #expect(field == fail)
                default:
                    #expect(Bool(false), "expected invalidSlug on \(ws)/\(pane)")
                }
            }

            expectInvalid("..", "p", "workspaceSlug")
            expectInvalid("ok", "..", "paneSlug")
            expectInvalid("a/b", "p", "workspaceSlug")
            expectInvalid("ok", "a\\b", "paneSlug")
            expectInvalid("", "p", "workspaceSlug")
            expectInvalid("ok", "   ", "paneSlug")

            // Sanity: no file landed on disk under a bogus path.
            let diaryDir = URL(fileURLWithPath: home)
                .appendingPathComponent(".senkani/diaries")
            let contents = try? FileManager.default.contentsOfDirectory(
                atPath: diaryDir.path)
            #expect(contents == nil || contents?.isEmpty == true)
        }
    }

    // MARK: - Mode 0600 on write

    @Test func writtenFileIsMode0600() throws {
        try withTempHome { home in
            try PaneDiaryStore.write(
                "secret-diary",
                workspaceSlug: "w", paneSlug: "p",
                home: home, env: [:])
            let path = PaneDiaryStore.diaryPath(
                workspaceSlug: "w", paneSlug: "p", home: home)
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let perms = attrs[.posixPermissions] as? NSNumber
            #expect(perms?.int16Value == 0o600)
        }
    }
}
