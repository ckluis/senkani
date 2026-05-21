import Testing
import Foundation
@testable import Core

// V.9a — ArtifactStore tests.
//
// 14 parameterized rows covering:
//   1. Codable round-trip (ArtifactRecord, 3 fixtures)
//   2. list filter by tag (OR-within / AND-across)
//   3. list filter by sourcePane (across all 3 panes)
//   4. list filter by versionRange
//   5. list filter by since
//   6. list combined AND composition
//   7. read returns body when no SecretDetector hit
//   8. read throws secretsBlocked when hit + allowSecrets=false
//   9. read with allowSecrets=true returns body + writes artifact.secret.allow
//  10. read writes chained artifact.read row on every successful call
//  11. FilesystemArtifactProvider 5-link version chain (chronological order)
//  12. FilesystemArtifactProvider mkdir 0700 + sidecar tags + missing-dir empty list
//  13. PaneDiaryArtifactProvider exposes existing PaneDiaryStore entries
//  14. Chain integrity across 100 chained artifact.secret.allow rows
//      (ChainVerifier.verifyTokenEvents == .ok)

// MARK: - Fixtures + helpers

private let fixedDate = Date(timeIntervalSince1970: 1_716_000_000)

private let secretMarker = "sk-ant-AAAAAAAAAAAAAAAAAAAAAAAA"

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-v9a-test-\(UUID().uuidString).sqlite"
    return (SessionDatabase(path: path), path)
}

private func cleanupDB(_ path: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: path)
    try? fm.removeItem(atPath: path + "-shm")
    try? fm.removeItem(atPath: path + "-wal")
}

private func makeTempHome() -> String {
    let path = "/tmp/senkani-v9a-home-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

private func cleanupHome(_ path: String) {
    try? FileManager.default.removeItem(atPath: path)
}

private struct StubProvider: ArtifactSourceProvider {
    let sourcePane: ArtifactSourcePane
    let records: [ArtifactRecord]
    let bodies: [String: String]

    init(sourcePane: ArtifactSourcePane, records: [ArtifactRecord], bodies: [String: String] = [:]) {
        self.sourcePane = sourcePane
        self.records = records
        self.bodies = bodies
    }

    func list() -> [ArtifactRecord] { records }

    func read(_ id: ArtifactID) throws -> ArtifactBody {
        if let text = bodies[id.raw] { return ArtifactBody(text) }
        throw ArtifactReadError.notFound(id: id)
    }

    func versions(of id: ArtifactID) -> [ArtifactRecord] { [] }
}

private func makeMixedRecords() -> [ArtifactRecord] {
    [
        ArtifactRecord(
            id: ArtifactID(sourcePane: .paneDiary, surfaceKey: "ws-a", rowOrPath: "pane-1"),
            sourcePane: .paneDiary,
            tags: ["ws-a", "pane-1", "urgent"],
            version: 1,
            createdAt: fixedDate,
            previousVersion: nil,
            redactionMarker: nil
        ),
        ArtifactRecord(
            id: ArtifactID(sourcePane: .sprintReview, surfaceKey: "filterRule", rowOrPath: "rule-7"),
            sourcePane: .sprintReview,
            tags: ["filterRule", "rule-7"],
            version: 2,
            createdAt: fixedDate.addingTimeInterval(3600),
            previousVersion: ArtifactID("sprintReview:filterRule:rule-7-prev"),
            redactionMarker: nil
        ),
        ArtifactRecord(
            id: ArtifactID(sourcePane: .filesystem, surfaceKey: "notes", rowOrPath: "notes.v3.md"),
            sourcePane: .filesystem,
            tags: ["notes", "draft"],
            version: 3,
            createdAt: fixedDate.addingTimeInterval(7200),
            previousVersion: ArtifactID("filesystem:notes:notes.v2.md"),
            redactionMarker: nil
        ),
    ]
}

// MARK: - 1. ArtifactRecord Codable round-trip

@Suite("V.9a ArtifactRecord round-trip")
struct ArtifactRecordRoundTripTests {

    static var fixtures: [(String, ArtifactRecord)] {
        makeMixedRecords().map { ("\($0.sourcePane.rawValue):\($0.version)", $0) }
    }

    @Test("Codable round-trip is byte-stable across 3 fixtures",
          arguments: ArtifactRecordRoundTripTests.fixtures)
    func roundTripStable(name: String, record: ArtifactRecord) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data1 = try enc.encode(record)
        let decoded = try JSONDecoder().decode(ArtifactRecord.self, from: data1)
        let data2 = try enc.encode(decoded)
        #expect(data1 == data2, "round-trip must produce byte-identical JSON for \(name)")
        #expect(decoded == record)
    }
}

// MARK: - 2-6. list filter rows

@Suite("V.9a ArtifactStore.list filter composition")
struct ArtifactStoreListFilterTests {

    private var store: ArtifactStore {
        let recs = makeMixedRecords()
        let p1 = StubProvider(sourcePane: .paneDiary, records: recs.filter { $0.sourcePane == .paneDiary })
        let p2 = StubProvider(sourcePane: .sprintReview, records: recs.filter { $0.sourcePane == .sprintReview })
        let p3 = StubProvider(sourcePane: .filesystem, records: recs.filter { $0.sourcePane == .filesystem })
        return ArtifactStore(providers: [p1, p2, p3], recorder: nil)
    }

    @Test("filter by tag — OR within set")
    func filterByTag() {
        let s = store
        // "urgent" only on paneDiary record; "notes" only on filesystem record.
        let outA = s.list(filter: ArtifactFilter(tags: ["urgent"]))
        #expect(outA.count == 1)
        #expect(outA.first?.sourcePane == .paneDiary)

        // OR-within-set: {urgent, notes} matches paneDiary OR filesystem.
        let outB = s.list(filter: ArtifactFilter(tags: ["urgent", "notes"]))
        #expect(outB.count == 2)
    }

    @Test("filter by sourcePane")
    func filterBySourcePane() {
        let s = store
        let out = s.list(filter: ArtifactFilter(sourcePane: [.paneDiary, .filesystem]))
        #expect(out.count == 2)
        #expect(Set(out.map(\.sourcePane)) == [.paneDiary, .filesystem])
    }

    @Test("filter by versionRange")
    func filterByVersionRange() {
        let s = store
        let out = s.list(filter: ArtifactFilter(versionRange: 2...3))
        #expect(out.count == 2)
        #expect(out.allSatisfy { $0.version >= 2 && $0.version <= 3 })
    }

    @Test("filter by since")
    func filterBySince() {
        let s = store
        let out = s.list(filter: ArtifactFilter(since: fixedDate.addingTimeInterval(1800)))
        // Excludes the first record (createdAt == fixedDate).
        #expect(out.count == 2)
        #expect(out.allSatisfy { $0.createdAt >= fixedDate.addingTimeInterval(1800) })
    }

    @Test("combined AND composition narrows further than either dimension alone")
    func combinedANDComposition() {
        let s = store
        // tag "filterRule" alone matches the sprintReview record.
        let single = s.list(filter: ArtifactFilter(tags: ["filterRule"]))
        #expect(single.count == 1)
        // tag "filterRule" AND sourcePane = {filesystem} → no match (AND-across).
        let crossed = s.list(filter: ArtifactFilter(
            tags: ["filterRule"], sourcePane: [.filesystem]))
        #expect(crossed.isEmpty,
                "AND-across-dimensions must reject mismatched composition")
    }
}

// MARK: - 7-10. read + secret gate + audit chain

@Suite("V.9a ArtifactStore.read + secret gate")
struct ArtifactStoreReadTests {

    @Test("read returns body when SecretDetector finds no hit")
    func readSucceedsWhenClean() throws {
        let id = ArtifactID(sourcePane: .filesystem, surfaceKey: "notes", rowOrPath: "notes.md")
        let provider = StubProvider(
            sourcePane: .filesystem,
            records: [ArtifactRecord(
                id: id, sourcePane: .filesystem, tags: [], version: 1,
                createdAt: fixedDate)],
            bodies: [id.raw: "# Notes\n\nNothing secret here.\n"]
        )
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }
        let store = ArtifactStore(providers: [provider],
                                  recorder: DatabaseArtifactAuditRecorder(database: db))
        let body = try store.read(id, projectRoot: "/tmp/v9a-clean")
        #expect(body.utf8?.contains("Nothing secret") == true)
    }

    @Test("read throws secretsBlocked when hit + allowSecrets=false")
    func readBlocksOnHit() throws {
        let id = ArtifactID(sourcePane: .paneDiary, surfaceKey: "ws", rowOrPath: "p")
        let provider = StubProvider(
            sourcePane: .paneDiary,
            records: [ArtifactRecord(
                id: id, sourcePane: .paneDiary, tags: [], version: 1,
                createdAt: fixedDate)],
            bodies: [id.raw: "Leak: \(secretMarker)\n"]
        )
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }
        let store = ArtifactStore(providers: [provider],
                                  recorder: DatabaseArtifactAuditRecorder(database: db))
        do {
            _ = try store.read(id, allowSecrets: false, projectRoot: "/tmp/v9a-block")
            Issue.record("expected secretsBlocked, got success")
        } catch let e as ArtifactReadError {
            switch e {
            case .secretsBlocked(let lane, let hitCount):
                #expect(lane == .paneDiary)
                #expect(hitCount >= 1)
            default:
                Issue.record("wrong error case: \(e)")
            }
        }
        // No audit row on refusal — the row is the "what was read"
        // trail and nothing was read.
        let rows = db.recentTokenEvents(projectRoot: "/tmp/v9a-block", limit: 50)
        #expect(rows.filter { $0.feature == "artifact.read" }.isEmpty,
                "refusal must not fire artifact.read")
        #expect(rows.filter { $0.feature == "artifact.secret.allow" }.isEmpty,
                "refusal must not fire artifact.secret.allow")
    }

    @Test("read with allowSecrets=true returns body AND writes artifact.secret.allow")
    func readOverrideFiresChainedRow() throws {
        let id = ArtifactID(sourcePane: .filesystem, surfaceKey: "creds", rowOrPath: "creds.md")
        let provider = StubProvider(
            sourcePane: .filesystem,
            records: [ArtifactRecord(
                id: id, sourcePane: .filesystem, tags: [], version: 1,
                createdAt: fixedDate)],
            bodies: [id.raw: "key: \(secretMarker)\n"]
        )
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }
        let store = ArtifactStore(providers: [provider],
                                  recorder: DatabaseArtifactAuditRecorder(database: db))
        let body = try store.read(id, allowSecrets: true,
                                  toolId: "v9a-tests",
                                  projectRoot: "/tmp/v9a-allow")
        #expect(body.utf8?.contains(secretMarker) == true)

        let rows = db.recentTokenEvents(projectRoot: "/tmp/v9a-allow", limit: 50)
        let allow = rows.first { $0.feature == "artifact.secret.allow" }
        #expect(allow != nil, "override must fire artifact.secret.allow row")
        // Payload must NOT contain the offending content — Schneier P0.
        let payload = allow?.command ?? ""
        #expect(!payload.contains(secretMarker),
                "audit row must not leak the secret content")
        #expect(payload.contains("ANTHROPIC_API_KEY"),
                "payload must record SecretDetector pattern name")
    }

    @Test("read writes chained artifact.read row on every successful call")
    func readWritesArtifactReadRow() throws {
        let id = ArtifactID(sourcePane: .filesystem, surfaceKey: "notes", rowOrPath: "notes.md")
        let provider = StubProvider(
            sourcePane: .filesystem,
            records: [ArtifactRecord(
                id: id, sourcePane: .filesystem, tags: [], version: 1,
                createdAt: fixedDate)],
            bodies: [id.raw: "clean content\n"]
        )
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }
        let store = ArtifactStore(providers: [provider],
                                  recorder: DatabaseArtifactAuditRecorder(database: db))
        _ = try store.read(id, projectRoot: "/tmp/v9a-row")
        _ = try store.read(id, projectRoot: "/tmp/v9a-row")
        let rows = db.recentTokenEvents(projectRoot: "/tmp/v9a-row", limit: 50)
        let reads = rows.filter { $0.feature == "artifact.read" }
        #expect(reads.count == 2, "each call must fire one artifact.read row")
    }
}

// MARK: - 11. FilesystemArtifactProvider version chain

@Suite("V.9a FilesystemArtifactProvider version chain")
struct FilesystemArtifactProviderChainTests {

    @Test("versions(of:) returns the 5-link chain in chronological order")
    func fiveLinkChain() throws {
        let home = makeTempHome()
        defer { cleanupHome(home) }
        let provider = FilesystemArtifactProvider(home: home)
        provider.ensureDirectory()
        let dir = provider.artifactsDirectory

        for n in 1...5 {
            let filename = "report.v\(n).md"
            try "# Report v\(n)\n".write(toFile: "\(dir)/\(filename)",
                                        atomically: true, encoding: .utf8)
        }

        let head = ArtifactID(sourcePane: .filesystem,
                              surfaceKey: "report", rowOrPath: "report.v5.md")
        let chain = provider.versions(of: head)
        #expect(chain.count == 5)
        #expect(chain.map(\.version) == [1, 2, 3, 4, 5])

        // Lineage links: each record's previousVersion == prior record's id (v >= 2).
        for i in 1..<chain.count {
            #expect(chain[i].previousVersion == chain[i - 1].id,
                    "v\(i+1) must link back to v\(i)")
        }
        #expect(chain[0].previousVersion == nil,
                "v1 must have no predecessor")
    }
}

// MARK: - 12. FilesystemArtifactProvider mkdir + sidecar + missing-dir

@Suite("V.9a FilesystemArtifactProvider directory + sidecar handling")
struct FilesystemArtifactProviderDirectoryTests {

    @Test("ensureDirectory creates ~/.senkani/artifacts with mode 0700")
    func ensureDirectoryMode0700() {
        let home = makeTempHome()
        defer { cleanupHome(home) }
        let provider = FilesystemArtifactProvider(home: home)
        #expect(FileManager.default.fileExists(atPath: provider.artifactsDirectory) == false)
        provider.ensureDirectory()
        #expect(FileManager.default.fileExists(atPath: provider.artifactsDirectory) == true)
        let attrs = try? FileManager.default.attributesOfItem(atPath: provider.artifactsDirectory)
        let perms = (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? -1
        #expect(perms == 0o700, "directory must be 0700, got \(String(perms, radix: 8))")
    }

    @Test("sidecar .tags file is read; missing sidecar yields empty tag set")
    func sidecarTags() throws {
        let home = makeTempHome()
        defer { cleanupHome(home) }
        let provider = FilesystemArtifactProvider(home: home)
        provider.ensureDirectory()
        let dir = provider.artifactsDirectory

        try "body A\n".write(toFile: "\(dir)/withTags.v1.md", atomically: true, encoding: .utf8)
        try "alpha\nbeta\n\n".write(toFile: "\(dir)/withTags.v1.tags", atomically: true, encoding: .utf8)
        try "body B\n".write(toFile: "\(dir)/withoutTags.v1.md", atomically: true, encoding: .utf8)

        let records = provider.list()
        let withTags = records.first { $0.id.raw.contains("withTags") }
        let without = records.first { $0.id.raw.contains("withoutTags") }
        #expect(withTags?.tags == ["alpha", "beta"])
        #expect(without?.tags == [])
    }

    @Test("missing artifacts directory yields empty list after ensureDirectory creates it (no error)")
    func missingDirIsEmptyList() {
        let home = makeTempHome()
        defer { cleanupHome(home) }
        let provider = FilesystemArtifactProvider(home: home)
        let out = provider.list()
        #expect(out.isEmpty,
                "empty artifacts dir produces empty list, not error")
        #expect(FileManager.default.fileExists(atPath: provider.artifactsDirectory))
    }
}

// MARK: - 13. PaneDiaryArtifactProvider exposes existing diaries

@Suite("V.9a PaneDiaryArtifactProvider")
struct PaneDiaryArtifactProviderTests {

    @Test("lists diaries written by PaneDiaryStore with ws+pane tag set")
    func listsExistingDiaries() throws {
        let home = makeTempHome()
        defer { cleanupHome(home) }

        try PaneDiaryStore.write("# diary alpha\ncontent\n",
                                 workspaceSlug: "ws-A",
                                 paneSlug: "pane-1",
                                 home: home,
                                 env: ["SENKANI_PANE_DIARY": "on"])
        try PaneDiaryStore.write("# diary beta\ncontent\n",
                                 workspaceSlug: "ws-B",
                                 paneSlug: "pane-2",
                                 home: home,
                                 env: ["SENKANI_PANE_DIARY": "on"])

        let provider = PaneDiaryArtifactProvider(home: home)
        let records = provider.list()
        #expect(records.count == 2)

        let tagSets = records.map(\.tags)
        #expect(tagSets.contains(["ws-A", "pane-1"]))
        #expect(tagSets.contains(["ws-B", "pane-2"]))

        // Read round-trip via provider returns the same bytes.
        let first = records.first { $0.tags.contains("ws-A") }
        if let r = first {
            let body = try provider.read(r.id)
            #expect(body.utf8?.contains("diary alpha") == true)
        } else {
            Issue.record("expected ws-A record present")
        }

        // versions() returns empty per V.9a lineage gap (follow-up filed).
        if let r = first {
            #expect(provider.versions(of: r.id).isEmpty)
        }
    }
}

// MARK: - 14. Chain integrity across 100 chained artifact.secret.allow rows

@Suite("V.9a chain integrity")
struct ArtifactChainIntegrityTests {

    @Test("100 chained artifact.secret.allow rows verify clean via ChainVerifier")
    func hundredRowChainIntegrity() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }
        let recorder = DatabaseArtifactAuditRecorder(database: db)
        for i in 0..<100 {
            recorder.recordSecretAllow(
                artifactId: "filesystem:bench:row-\(i)",
                sourcePane: "filesystem",
                hitCount: 1,
                hitPatternNames: ["GENERIC_API_KEY"],
                toolId: "v9a-chain-bench",
                sessionId: "v9a-chain",
                projectRoot: "/tmp/v9a-chain"
            )
        }
        let result = ChainVerifier.verifyTokenEvents(db)
        switch result {
        case .ok:
            break
        default:
            Issue.record("expected .ok after 100 chained rows, got \(result)")
        }
        // Sanity: the rows are actually there.
        let rows = db.recentTokenEvents(projectRoot: "/tmp/v9a-chain", limit: 200)
        #expect(rows.filter { $0.feature == "artifact.secret.allow" }.count == 100)
    }
}
