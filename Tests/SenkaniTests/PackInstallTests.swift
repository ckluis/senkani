import Testing
import Foundation
@testable import Core

@Suite("Phase V.11a — SkillPack install / uninstall / collisions / chain")
struct PackInstallTests {

    // MARK: - Helpers

    private static func tempBase() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("senkani-pack-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func writePackSkeleton(
        at base: URL,
        packName: String,
        skillName: String,
        scopeKey: String,
        contextFilename: String,
        version: String = "0.1.0"
    ) throws -> URL {
        let packDir = base.appendingPathComponent(packName, isDirectory: true)
        let skillDir = packDir.appendingPathComponent("skills/\(skillName)", isDirectory: true)
        let policyDir = packDir.appendingPathComponent("policy", isDirectory: true)
        let contextDir = packDir.appendingPathComponent("context", isDirectory: true)
        for d in [packDir, skillDir, policyDir, contextDir] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        let packJSON = """
            {
              "schema_version": 1,
              "name": "\(packName)",
              "description": "test pack",
              "version": "\(version)",
              "author": "test",
              "senkani_min_version": "0.3.0",
              "skills": ["\(skillName)"],
              "policy": "policy/hook_router.json",
              "context": "context/\(contextFilename)",
              "provenance": {"source_url": null, "sha256": null, "signed_by": null}
            }
            """
        try Data(packJSON.utf8).write(to: packDir.appendingPathComponent("pack.json"))

        let skillJSON = """
            {
              "schema_version": 1,
              "name": "\(skillName)",
              "description": "test skill",
              "version": "0.1.0",
              "tools": [],
              "settings": {},
              "metrics": [],
              "system_prompt": {"phases": [{"name": "preamble", "body": "test body"}]},
              "skill_md": "test",
              "guardrails": {"requires_confirm": [], "egress_allow": [], "secret_scope": "none"},
              "cadence": {"triggers": []},
              "sandbox": "none",
              "capabilities": []
            }
            """
        try Data(skillJSON.utf8).write(
            to: skillDir.appendingPathComponent("manifest.json"))

        let policyJSON = """
            {
              "schema_version": 1,
              "scope_key": "\(scopeKey)",
              "rules": [{"kind": "deny", "match": "rm -rf /", "reason": "no-op"}]
            }
            """
        try Data(policyJSON.utf8).write(
            to: policyDir.appendingPathComponent("hook_router.json"))

        try Data("# context\n".utf8).write(
            to: contextDir.appendingPathComponent(contextFilename))
        return packDir
    }

    private static func makeDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-pack-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        return (db, path)
    }

    // MARK: - PackManifestParser

    @Test("PackManifestParser parses a valid pack.json")
    func parserHappyPath() throws {
        let json = """
            {"schema_version": 1, "name": "demo", "description": "d",
             "version": "1.0.0", "author": "a", "senkani_min_version": "0.3.0",
             "skills": ["x"], "policy": null, "context": null,
             "provenance": {"source_url": null, "sha256": null, "signed_by": null}}
            """
        let m = try PackManifestParser.parse(data: Data(json.utf8))
        #expect(m.name == "demo")
        #expect(m.skills == ["x"])
    }

    @Test("PackManifestParser rejects schema_version != 1")
    func parserRejectsSchemaVersion() {
        let json = """
            {"schema_version": 2, "name": "demo", "description": "d",
             "version": "1.0.0", "author": "a", "senkani_min_version": "0.3.0",
             "skills": ["x"], "policy": null, "context": null,
             "provenance": {"source_url": null, "sha256": null, "signed_by": null}}
            """
        #expect(throws: PackManifestParser.ParseError.self) {
            try PackManifestParser.parse(data: Data(json.utf8))
        }
    }

    @Test("PackManifestParser rejects empty skills list")
    func parserRejectsEmptySkills() {
        let json = """
            {"schema_version": 1, "name": "demo", "description": "d",
             "version": "1.0.0", "author": "a", "senkani_min_version": "0.3.0",
             "skills": [], "policy": null, "context": null,
             "provenance": {"source_url": null, "sha256": null, "signed_by": null}}
            """
        #expect(throws: PackManifestParser.ParseError.skillsEmpty) {
            try PackManifestParser.parse(data: Data(json.utf8))
        }
    }

    @Test("PackManifestParser rejects non-kebab-case name")
    func parserRejectsBadName() {
        let json = """
            {"schema_version": 1, "name": "BadName", "description": "d",
             "version": "1.0.0", "author": "a", "senkani_min_version": "0.3.0",
             "skills": ["x"], "policy": null, "context": null,
             "provenance": {"source_url": null, "sha256": null, "signed_by": null}}
            """
        #expect(throws: PackManifestParser.ParseError.self) {
            try PackManifestParser.parse(data: Data(json.utf8))
        }
    }

    // MARK: - Install

    @Test("install copies pack tree verbatim and writes a chained install row")
    func installHappyPath() throws {
        let base = Self.tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = try Self.writePackSkeleton(
            at: base, packName: "demo-a", skillName: "demo-a",
            scopeKey: "demo-a", contextFilename: "demo-a.md")
        let installRoot = base.appendingPathComponent("installed", isDirectory: true)

        let (db, dbPath) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: dbPath) }
        let installer = PackInstaller(installRoot: installRoot, auditStore: db.packAuditStore)

        let installed = try installer.install(sourceDir: source)
        #expect(installed.manifest.name == "demo-a")
        #expect(FileManager.default.fileExists(atPath:
            installed.installDir.appendingPathComponent("pack.json").path))
        #expect(FileManager.default.fileExists(atPath:
            installed.installDir.appendingPathComponent("skills/demo-a/manifest.json").path))
        #expect(FileManager.default.fileExists(atPath:
            installed.installDir.appendingPathComponent("policy/hook_router.json").path))
        #expect(FileManager.default.fileExists(atPath:
            installed.installDir.appendingPathComponent("context/demo-a.md").path))

        let rows = db.packAuditStore.recent()
        #expect(rows.count == 1)
        #expect(rows[0].event == "install")
        #expect(rows[0].packName == "demo-a")
        #expect(rows[0].appliedSkills == ["demo-a"])
    }

    @Test("install is idempotent — re-install replaces existing target")
    func installIdempotent() throws {
        let base = Self.tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = try Self.writePackSkeleton(
            at: base, packName: "demo-b", skillName: "demo-b",
            scopeKey: "demo-b", contextFilename: "demo-b.md")
        let installRoot = base.appendingPathComponent("installed", isDirectory: true)
        let (db, dbPath) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: dbPath) }
        let installer = PackInstaller(installRoot: installRoot, auditStore: db.packAuditStore)

        _ = try installer.install(sourceDir: source)

        // Mutate the source pack-version, re-install — the target should
        // reflect the new version.
        let packJsonPath = source.appendingPathComponent("pack.json")
        var s = try String(contentsOf: packJsonPath, encoding: .utf8)
        s = s.replacingOccurrences(of: "\"version\": \"0.1.0\"",
                                    with: "\"version\": \"0.2.0\"")
        try s.write(to: packJsonPath, atomically: true, encoding: .utf8)
        let second = try installer.install(sourceDir: source)
        #expect(second.manifest.version == "0.2.0")
        let rows = db.packAuditStore.recent()
        #expect(rows.count == 2)
    }

    // MARK: - Uninstall round-trip

    @Test("uninstall removes the install dir and writes a chained uninstall row")
    func uninstallRemovesAndAudits() throws {
        let base = Self.tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = try Self.writePackSkeleton(
            at: base, packName: "demo-c", skillName: "demo-c",
            scopeKey: "demo-c", contextFilename: "demo-c.md")
        let installRoot = base.appendingPathComponent("installed", isDirectory: true)
        let (db, dbPath) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: dbPath) }
        let installer = PackInstaller(installRoot: installRoot, auditStore: db.packAuditStore)

        _ = try installer.install(sourceDir: source)
        _ = try installer.uninstall(name: "demo-c")
        let target = installRoot.appendingPathComponent("demo-c").path
        #expect(!FileManager.default.fileExists(atPath: target))

        let rows = db.packAuditStore.recent()
        #expect(rows.count == 2)
        #expect(rows[0].event == "uninstall")
        #expect(rows[1].event == "install")
    }

    @Test("uninstall throws packNotInstalled for unknown name")
    func uninstallMissingThrows() throws {
        let base = Self.tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let installRoot = base.appendingPathComponent("installed", isDirectory: true)
        let (db, dbPath) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: dbPath) }
        let installer = PackInstaller(installRoot: installRoot, auditStore: db.packAuditStore)

        #expect(throws: PackInstaller.InstallError.self) {
            _ = try installer.uninstall(name: "ghost")
        }
    }

    @Test("install→uninstall round-trip leaves zero residue under the install root")
    func roundTripLeavesNoResidue() throws {
        let base = Self.tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = try Self.writePackSkeleton(
            at: base, packName: "demo-d", skillName: "demo-d",
            scopeKey: "demo-d", contextFilename: "demo-d.md")
        let installRoot = base.appendingPathComponent("installed", isDirectory: true)
        let (db, dbPath) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: dbPath) }
        let installer = PackInstaller(installRoot: installRoot, auditStore: db.packAuditStore)

        _ = try installer.install(sourceDir: source)
        _ = try installer.uninstall(name: "demo-d")

        let entries = try FileManager.default.contentsOfDirectory(
            at: installRoot, includingPropertiesForKeys: nil)
        #expect(entries.isEmpty)
    }

    // MARK: - List

    @Test("list returns installed packs sorted by name")
    func listSorted() throws {
        let base = Self.tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let aSrc = try Self.writePackSkeleton(
            at: base, packName: "alpha", skillName: "a-skill",
            scopeKey: "alpha", contextFilename: "alpha.md")
        let bSrc = try Self.writePackSkeleton(
            at: base, packName: "bravo", skillName: "b-skill",
            scopeKey: "bravo", contextFilename: "bravo.md")
        let installRoot = base.appendingPathComponent("installed", isDirectory: true)
        let (db, dbPath) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: dbPath) }
        let installer = PackInstaller(installRoot: installRoot, auditStore: db.packAuditStore)

        _ = try installer.install(sourceDir: bSrc)
        _ = try installer.install(sourceDir: aSrc)
        let listed = installer.list()
        #expect(listed.map(\.manifest.name) == ["alpha", "bravo"])
    }

    // MARK: - Collisions

    @Test("plan detects skill-name collision against installed pack")
    func collisionSkillName() throws {
        let base = Self.tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let firstSrc = try Self.writePackSkeleton(
            at: base, packName: "alpha", skillName: "shared-skill",
            scopeKey: "alpha", contextFilename: "alpha.md")
        let secondSrc = try Self.writePackSkeleton(
            at: base, packName: "bravo", skillName: "shared-skill",
            scopeKey: "bravo", contextFilename: "bravo.md")
        let installRoot = base.appendingPathComponent("installed", isDirectory: true)
        let (db, dbPath) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: dbPath) }
        let installer = PackInstaller(installRoot: installRoot, auditStore: db.packAuditStore)

        _ = try installer.install(sourceDir: firstSrc)
        let plan = try installer.plan(sourceDir: secondSrc)
        #expect(plan.collisions.contains(.skillName("shared-skill", conflictingPack: "alpha")))
    }

    @Test("plan detects policy scope-key collision")
    func collisionPolicyScopeKey() throws {
        let base = Self.tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let firstSrc = try Self.writePackSkeleton(
            at: base, packName: "alpha", skillName: "a-skill",
            scopeKey: "shared-scope", contextFilename: "alpha.md")
        let secondSrc = try Self.writePackSkeleton(
            at: base, packName: "bravo", skillName: "b-skill",
            scopeKey: "shared-scope", contextFilename: "bravo.md")
        let installRoot = base.appendingPathComponent("installed", isDirectory: true)
        let (db, dbPath) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: dbPath) }
        let installer = PackInstaller(installRoot: installRoot, auditStore: db.packAuditStore)

        _ = try installer.install(sourceDir: firstSrc)
        let plan = try installer.plan(sourceDir: secondSrc)
        #expect(plan.collisions.contains(
            .policyScopeKey("shared-scope", conflictingPack: "alpha")))
    }

    @Test("apply with collisions and force=false throws collisionsRefuseInstall")
    func collisionsRefuseInstall() throws {
        let base = Self.tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let firstSrc = try Self.writePackSkeleton(
            at: base, packName: "alpha", skillName: "shared-skill",
            scopeKey: "alpha", contextFilename: "alpha.md")
        let secondSrc = try Self.writePackSkeleton(
            at: base, packName: "bravo", skillName: "shared-skill",
            scopeKey: "bravo", contextFilename: "bravo.md")
        let installRoot = base.appendingPathComponent("installed", isDirectory: true)
        let (db, dbPath) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: dbPath) }
        let installer = PackInstaller(installRoot: installRoot, auditStore: db.packAuditStore)

        _ = try installer.install(sourceDir: firstSrc)
        let plan = try installer.plan(sourceDir: secondSrc)
        #expect(throws: PackInstaller.InstallError.self) {
            _ = try installer.apply(plan: plan, force: false)
        }
    }

    @Test("apply with collisions and force=true succeeds + writes force_override row")
    func collisionsForceWritesOverrideRow() throws {
        let base = Self.tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let firstSrc = try Self.writePackSkeleton(
            at: base, packName: "alpha", skillName: "shared-skill",
            scopeKey: "alpha", contextFilename: "alpha.md")
        let secondSrc = try Self.writePackSkeleton(
            at: base, packName: "bravo", skillName: "shared-skill",
            scopeKey: "bravo", contextFilename: "bravo.md")
        let installRoot = base.appendingPathComponent("installed", isDirectory: true)
        let (db, dbPath) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: dbPath) }
        let installer = PackInstaller(installRoot: installRoot, auditStore: db.packAuditStore)

        _ = try installer.install(sourceDir: firstSrc)
        let plan = try installer.plan(sourceDir: secondSrc)
        _ = try installer.apply(plan: plan, force: true)
        let rows = db.packAuditStore.recent()
        let events = rows.map(\.event)
        #expect(events.contains("force_override"))
        #expect(events.contains("install"))
    }

    // MARK: - Rendering

    @Test("PackCollisionDiff.render returns '(no collisions)' for empty input")
    func collisionDiffEmpty() {
        let s = PackCollisionDiff.render(incomingPack: "x", collisions: [])
        #expect(s == "(no collisions)")
    }

    @Test("PackCollisionDiff.render groups rows by collision kind")
    func collisionDiffGroups() {
        let s = PackCollisionDiff.render(
            incomingPack: "bravo",
            collisions: [
                .skillName("shared", conflictingPack: "alpha"),
                .policyScopeKey("scope", conflictingPack: "alpha"),
                .contextFilename("ctx.md", conflictingPack: "alpha"),
            ])
        #expect(s.contains("Skill name clashes"))
        #expect(s.contains("Policy scope-key clashes"))
        #expect(s.contains("Context filename clashes"))
    }

    // MARK: - ChainVerifier

    @Test("ChainVerifier.verifyPackAudits reports OK after install + uninstall")
    func chainVerifies() throws {
        let base = Self.tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = try Self.writePackSkeleton(
            at: base, packName: "demo-e", skillName: "demo-e",
            scopeKey: "demo-e", contextFilename: "demo-e.md")
        let installRoot = base.appendingPathComponent("installed", isDirectory: true)
        let (db, dbPath) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: dbPath) }
        let installer = PackInstaller(installRoot: installRoot, auditStore: db.packAuditStore)
        _ = try installer.install(sourceDir: source)
        _ = try installer.uninstall(name: "demo-e")

        let result = ChainVerifier.verifyPackAudits(db)
        guard case .ok = result else {
            Issue.record("expected .ok, got \(result)")
            return
        }
    }

    // MARK: - SkillScanner integration

    @Test("SkillScanner discovers a skill from an installed pack under the home root")
    func scannerFindsPackSkills() throws {
        let base = Self.tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        // Layout: <base>/.senkani/packs/<name>/...
        let fakeHome = base
        let installRoot = fakeHome.appendingPathComponent(".senkani/packs", isDirectory: true)
        let source = try Self.writePackSkeleton(
            at: base.appendingPathComponent("source"),
            packName: "scanner-pack", skillName: "scanner-skill",
            scopeKey: "scanner-pack", contextFilename: "scanner-pack.md")
        let (db, dbPath) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: dbPath) }
        let installer = PackInstaller(installRoot: installRoot, auditStore: db.packAuditStore)
        _ = try installer.install(sourceDir: source)

        let scanned = SkillScanner.scan(homeDir: fakeHome.path, cwd: fakeHome.path)
        let names = scanned.map(\.name)
        #expect(names.contains("scanner-skill"))
    }
}
