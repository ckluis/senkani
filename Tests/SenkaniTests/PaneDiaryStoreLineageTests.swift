import Testing
import Foundation
@testable import Core

/// V.9a follow-up sub-1 — PaneDiaryStore file versioning + retention
/// chain tests.
///
/// Six tests:
///   1. Rotation: 5 writes → 4 versioned siblings + 1 unversioned.
///   2. Retention: write older than window → pruned on next write.
///   3. Retention env override: `SENKANI_PANE_DIARY_RETENTION_DAYS=7`
///      → 8-day-old version pruned.
///   4. Read back-compat: `read()` after N re-emits returns newest.
///   5. Provider chain: `versions(of:)` returns ordered records with
///      `previousVersion` populated for v2..vN.
///   6. Audit row: `ArtifactStore.versions(of:)` fires the chained
///      `artifact.versions` token_events row on a non-empty chain.
@Suite("PaneDiaryStoreLineage") struct PaneDiaryStoreLineageTests {

    // MARK: - Fixtures

    private func withTempHome<T>(_ body: (String) throws -> T) throws -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("senkani-pane-diary-lineage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try body(dir.path)
    }

    private func tempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-diary-lineage-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    private func diaryDir(home: String, workspaceSlug: String) -> URL {
        URL(fileURLWithPath: "\(home)/.senkani/diaries/\(workspaceSlug)")
    }

    // MARK: - 1. Rotation

    @Test("write rotates `<pane>.md` → `<pane>.v<N>.md` on each re-emit")
    func rotationProducesVersionedSiblings() throws {
        try withTempHome { home in
            let ws = "proj-rotate"
            let pane = "chat-main"
            for i in 1...5 {
                try PaneDiaryStore.write(
                    "body-\(i)\n",
                    workspaceSlug: ws,
                    paneSlug: pane,
                    home: home,
                    env: [:])
            }

            let dir = diaryDir(home: home, workspaceSlug: ws)
            let fm = FileManager.default
            let entries = (try fm.contentsOfDirectory(atPath: dir.path))
                .filter { $0.hasSuffix(".md") }
                .sorted()
            #expect(entries.count == 5, "expected 5 .md files (4 versioned + 1 unversioned), got \(entries)")
            #expect(entries.contains("\(pane).md"))
            #expect(entries.contains("\(pane).v1.md"))
            #expect(entries.contains("\(pane).v2.md"))
            #expect(entries.contains("\(pane).v3.md"))
            #expect(entries.contains("\(pane).v4.md"))

            let primary = try String(contentsOfFile: "\(dir.path)/\(pane).md", encoding: .utf8)
            #expect(primary == "body-5\n", "unversioned file must be the newest write")

            // v1 must be the first write's content.
            let v1 = try String(contentsOfFile: "\(dir.path)/\(pane).v1.md", encoding: .utf8)
            #expect(v1 == "body-1\n", "v1 must carry the oldest content")
        }
    }

    // MARK: - 2. Retention prune (default 30 days)

    @Test("retention prunes versioned siblings older than retentionDays")
    func retentionDefaultPrunesOldSiblings() throws {
        try withTempHome { home in
            let ws = "proj-retention"
            let pane = "pane-a"

            // Write twice at t=T (rotates body-1 → v1, body-2 becomes
            // primary). Backdate v1 to 31 days ago, then write again at
            // t=T+31d to trigger prune.
            let t = Date(timeIntervalSince1970: 1_700_000_000)
            try PaneDiaryStore.write("body-1\n", workspaceSlug: ws, paneSlug: pane,
                                     home: home, env: [:], now: t)
            try PaneDiaryStore.write("body-2\n", workspaceSlug: ws, paneSlug: pane,
                                     home: home, env: [:], now: t)

            let dir = diaryDir(home: home, workspaceSlug: ws)
            let v1Path = "\(dir.path)/\(pane).v1.md"
            #expect(FileManager.default.fileExists(atPath: v1Path))

            // Backdate v1.
            let oldDate = t.addingTimeInterval(-86_400 * 31)
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: v1Path)

            // New write at t — prune fires using now=t and 30-day window.
            try PaneDiaryStore.write("body-3\n", workspaceSlug: ws, paneSlug: pane,
                                     home: home, env: [:], now: t)

            #expect(!FileManager.default.fileExists(atPath: v1Path),
                    "v1 older than 30 days must be pruned")
            // v2 was the just-rotated body-2; it was freshly mtime'd by
            // rotation so it survives the prune.
            #expect(FileManager.default.fileExists(atPath: "\(dir.path)/\(pane).v2.md"))
            #expect(FileManager.default.fileExists(atPath: "\(dir.path)/\(pane).md"))
        }
    }

    // MARK: - 3. Retention env override

    @Test("SENKANI_PANE_DIARY_RETENTION_DAYS env override shrinks window")
    func retentionEnvOverridePrunes() throws {
        try withTempHome { home in
            let ws = "proj-env-retention"
            let pane = "pane-b"
            let env = ["SENKANI_PANE_DIARY_RETENTION_DAYS": "7"]
            let t = Date(timeIntervalSince1970: 1_700_000_000)

            try PaneDiaryStore.write("body-1\n", workspaceSlug: ws, paneSlug: pane,
                                     home: home, env: env, now: t)
            try PaneDiaryStore.write("body-2\n", workspaceSlug: ws, paneSlug: pane,
                                     home: home, env: env, now: t)

            let dir = diaryDir(home: home, workspaceSlug: ws)
            let v1Path = "\(dir.path)/\(pane).v1.md"
            #expect(FileManager.default.fileExists(atPath: v1Path))

            // Backdate v1 by 8 days — under default 30 it'd survive,
            // under env=7 it's pruned.
            let eightDaysAgo = t.addingTimeInterval(-86_400 * 8)
            try FileManager.default.setAttributes([.modificationDate: eightDaysAgo], ofItemAtPath: v1Path)

            try PaneDiaryStore.write("body-3\n", workspaceSlug: ws, paneSlug: pane,
                                     home: home, env: env, now: t)

            #expect(!FileManager.default.fileExists(atPath: v1Path),
                    "v1 older than env override (7d) must be pruned")
        }
    }

    // MARK: - 4. Read back-compat

    @Test("read() returns newest content after N re-emits")
    func readReturnsNewestAfterRotation() throws {
        try withTempHome { home in
            let ws = "proj-read"
            let pane = "pane-c"
            for i in 1...4 {
                try PaneDiaryStore.write(
                    "body-\(i)\n",
                    workspaceSlug: ws,
                    paneSlug: pane,
                    home: home,
                    env: [:])
            }
            let got = try PaneDiaryStore.read(
                workspaceSlug: ws,
                paneSlug: pane,
                home: home,
                env: [:])
            #expect(got == "body-4\n", "read() must return newest unversioned content")
        }
    }

    // MARK: - 5. Provider chain

    @Test("PaneDiaryArtifactProvider.versions returns ordered chain")
    func providerVersionsReturnsChain() throws {
        try withTempHome { home in
            let ws = "proj-chain"
            let pane = "pane-d"
            for i in 1...4 {
                try PaneDiaryStore.write(
                    "body-\(i)\n",
                    workspaceSlug: ws,
                    paneSlug: pane,
                    home: home,
                    env: [:])
            }

            let provider = PaneDiaryArtifactProvider(home: home)
            let id = ArtifactID(sourcePane: .paneDiary, surfaceKey: ws, rowOrPath: pane)
            let chain = provider.versions(of: id)
            #expect(chain.count == 4, "expected 4 records (v1..v3 + unversioned)")
            #expect(chain.map { $0.version } == [1, 2, 3, 4],
                    "chain must be version-ascending")
            // v1 has no previous; v2..v4 reference v(N-1).
            #expect(chain[0].previousVersion == nil)
            for i in 1..<chain.count {
                #expect(chain[i].previousVersion == chain[i - 1].id,
                        "version \(chain[i].version) must reference v\(chain[i].version - 1)")
            }
        }
    }

    // MARK: - 6. Audit row via ArtifactStore.versions(of:)

    @Test("ArtifactStore.versions fires artifact.versions row on non-empty chain")
    func versionsFiresChainedAuditRow() throws {
        try withTempHome { home in
            let ws = "proj-audit"
            let pane = "pane-e"
            for i in 1...3 {
                try PaneDiaryStore.write(
                    "body-\(i)\n",
                    workspaceSlug: ws,
                    paneSlug: pane,
                    home: home,
                    env: [:])
            }

            let (db, dbPath) = tempDB()
            defer { TempSessionDatabase.close(db, path: dbPath) }
            let provider = PaneDiaryArtifactProvider(home: home)
            let store = ArtifactStore(
                providers: [provider],
                recorder: DatabaseArtifactAuditRecorder(database: db))

            let id = ArtifactID(sourcePane: .paneDiary, surfaceKey: ws, rowOrPath: pane)
            let chain = store.versions(
                of: id,
                toolId: "lineage-test",
                sessionId: "test-session",
                projectRoot: "/tmp/v9a-lineage-audit")
            #expect(chain.count == 3)

            let rows = db.recentTokenEvents(
                projectRoot: "/tmp/v9a-lineage-audit", limit: 50)
            let versionsRows = rows.filter { $0.feature == "artifact.versions" }
            #expect(versionsRows.count == 1,
                    "exactly one artifact.versions row on a versions(of:) call")
            let payload = versionsRows.first?.command ?? ""
            #expect(payload.contains("\"count\":3"),
                    "audit payload must record chain count, got: \(payload)")
        }
    }
}
