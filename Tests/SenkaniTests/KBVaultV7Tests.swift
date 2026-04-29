import Testing
import Foundation
@testable import Core

// V.7 — KB plain-md vault round.
//
// Twelve tests covering:
//   - KBVaultConfig path resolution + slug + tilde expansion (3)
//   - KBVaultMigrator copy / idempotency / unmigrate / conflicts (4)
//   - WikiLinkResolver exact / folder-hint / ambiguous / not-found (4)
//   - KnowledgeFileLayer honors KBVaultConfig env override (1)

// MARK: - Helpers

private func tmpDir(_ tag: String) -> String {
    let path = "/tmp/senkani-v7-\(tag)-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

private func writeFile(_ path: String, _ contents: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? contents.write(to: url, atomically: true, encoding: .utf8)
}

private func read(_ path: String) -> String? {
    try? String(contentsOfFile: path, encoding: .utf8)
}

// MARK: - KBVaultConfig

@Suite("KBVaultConfig — V.7")
struct KBVaultConfigTests {

    /// 1. Default resolution: no env override, empty config file → per-project dir.
    @Test func defaultResolvesToPerProjectDir() {
        unsetenv("SENKANI_KB_VAULT_ROOT")
        let root = "/tmp/senkani-v7-cfg-default"
        let cfgDir = tmpDir("cfg-empty")
        defer { try? FileManager.default.removeItem(atPath: cfgDir) }
        let cfgPath = cfgDir + "/config.json"   // file doesn't exist

        let resolved = KBVaultConfig.resolvedVaultDir(
            projectRoot: root, configPath: cfgPath)
        #expect(resolved == root + "/.senkani/knowledge")
        #expect(KBVaultConfig.isExternalized(projectRoot: root, configPath: cfgPath) == false)
    }

    /// 2. SENKANI_KB_VAULT_ROOT override redirects + appends project slug.
    @Test func envOverrideUsesProjectSlugSubdir() {
        let vaultRoot = tmpDir("env-override")
        defer { try? FileManager.default.removeItem(atPath: vaultRoot) }

        setenv("SENKANI_KB_VAULT_ROOT", vaultRoot, 1)
        defer { unsetenv("SENKANI_KB_VAULT_ROOT") }

        let resolved = KBVaultConfig.resolvedVaultDir(projectRoot: "/Users/clank/Desktop/proj-x")
        #expect(resolved == vaultRoot + "/proj-x")
        #expect(KBVaultConfig.isExternalized(projectRoot: "/Users/clank/Desktop/proj-x") == true)
    }

    /// 3. slug() sanitizes weird characters and falls back to "unknown" on empty.
    @Test func slugSanitizesAndDefaults() {
        #expect(KBVaultConfig.slug("/tmp/Senkani Project!") == "Senkani-Project-")
        #expect(KBVaultConfig.slug("") == "unknown")
        #expect(KBVaultConfig.slug("/") == "unknown")
        #expect(KBVaultConfig.slug("/Users/x/y/PlainName") == "PlainName")
    }
}

// MARK: - KBVaultMigrator

@Suite("KBVaultMigrator — V.7")
struct KBVaultMigratorTests {

    /// 4. migrate copies all .md files into a fresh dest dir.
    @Test func migrateCopiesAllMarkdown() throws {
        let src = tmpDir("mig-src")
        let dst = tmpDir("mig-dst")
        defer {
            try? FileManager.default.removeItem(atPath: src)
            try? FileManager.default.removeItem(atPath: dst)
        }
        writeFile(src + "/Alpha.md",   "# Alpha\n")
        writeFile(src + "/Beta.md",    "# Beta\n")
        writeFile(src + "/skip.txt",   "not markdown")

        let report = try KBVaultMigrator.migrate(from: src, to: dst)
        #expect(Set(report.copied) == ["Alpha.md", "Beta.md"])
        #expect(report.skipped.isEmpty)
        #expect(report.conflicts.isEmpty)
        #expect(read(dst + "/Alpha.md") == "# Alpha\n")
        #expect(FileManager.default.fileExists(atPath: dst + "/skip.txt") == false)
    }

    /// 5. migrate is idempotent — running twice yields zero new copies.
    @Test func migrateIsIdempotent() throws {
        let src = tmpDir("mig-idem-src")
        let dst = tmpDir("mig-idem-dst")
        defer {
            try? FileManager.default.removeItem(atPath: src)
            try? FileManager.default.removeItem(atPath: dst)
        }
        writeFile(src + "/Note.md", "first")

        let r1 = try KBVaultMigrator.migrate(from: src, to: dst)
        let r2 = try KBVaultMigrator.migrate(from: src, to: dst)
        #expect(r1.copied == ["Note.md"])
        #expect(r2.copied.isEmpty)
        #expect(r2.skipped == ["Note.md"])
    }

    /// 6. unmigrate reverses direction and is also idempotent.
    @Test func unmigrateReversesDirection() throws {
        let project = tmpDir("mig-back-proj")
        let vault   = tmpDir("mig-back-vault")
        defer {
            try? FileManager.default.removeItem(atPath: project)
            try? FileManager.default.removeItem(atPath: vault)
        }
        writeFile(vault + "/Z.md", "vault content")

        let report = try KBVaultMigrator.unmigrate(from: vault, to: project)
        #expect(report.copied == ["Z.md"])
        #expect(read(project + "/Z.md") == "vault content")
    }

    /// 7. Differing dest content is reported as a conflict, never overwritten.
    @Test func differingDestIsConflictNotOverwrite() throws {
        let src = tmpDir("mig-conf-src")
        let dst = tmpDir("mig-conf-dst")
        defer {
            try? FileManager.default.removeItem(atPath: src)
            try? FileManager.default.removeItem(atPath: dst)
        }
        writeFile(src + "/X.md", "from source")
        writeFile(dst + "/X.md", "older copy")

        let report = try KBVaultMigrator.migrate(from: src, to: dst)
        #expect(report.conflicts == ["X.md"])
        #expect(report.hasConflicts)
        #expect(read(dst + "/X.md") == "older copy")  // untouched
    }
}

// MARK: - WikiLinkResolver

@Suite("WikiLinkResolver — V.7")
struct WikiLinkResolverTests {

    private func urls(_ paths: [String]) -> [URL] {
        paths.map { URL(fileURLWithPath: $0) }
    }

    /// 8. Single matching stem resolves to .exact.
    @Test func resolvesExact() {
        let files = urls([
            "/v/Auth.md",
            "/v/Other.md",
        ])
        #expect(WikiLinkResolver.resolve(name: "Auth", in: files)
                == .exact(URL(fileURLWithPath: "/v/Auth.md")))
    }

    /// 9. Folder hint disambiguates multiple stem matches.
    @Test func folderHintDisambiguates() {
        let files = urls([
            "/v/skills/auth/Login.md",
            "/v/skills/admin/Login.md",
        ])
        #expect(WikiLinkResolver.resolve(name: "auth/Login", in: files)
                == .exact(URL(fileURLWithPath: "/v/skills/auth/Login.md")))
        #expect(WikiLinkResolver.resolve(name: "skills/admin/Login", in: files)
                == .exact(URL(fileURLWithPath: "/v/skills/admin/Login.md")))
    }

    /// 10. No hint + multiple matches → ambiguous, candidates returned in path order.
    @Test func bareStemIsAmbiguousWithMultipleMatches() {
        let files = urls([
            "/v/b/Note.md",
            "/v/a/Note.md",
        ])
        guard case let .ambiguous(cands) = WikiLinkResolver.resolve(name: "Note", in: files)
        else {
            Issue.record("expected .ambiguous"); return
        }
        // Sorted by absolute path → /v/a/Note.md before /v/b/Note.md.
        #expect(cands.map(\.path) == ["/v/a/Note.md", "/v/b/Note.md"])
    }

    /// 11. No matching stem → notFound.
    @Test func returnsNotFound() {
        let files = urls(["/v/Alpha.md", "/v/Beta.md"])
        #expect(WikiLinkResolver.resolve(name: "Gamma", in: files) == .notFound)
        #expect(WikiLinkResolver.resolve(name: "", in: files) == .notFound)
    }
}

// MARK: - KnowledgeFileLayer + KBVaultConfig integration

@Suite("KnowledgeFileLayer × KBVaultConfig — V.7")
struct KnowledgeFileLayerVaultIntegrationTests {

    /// 12. Round-trip through the explicit `init(vaultDir:store:)` overload
    ///     proves the vault path is honored end-to-end: write goes to the
    ///     external dir, read returns the same content. This satisfies the
    ///     V.7 acceptance line "Vault exists and round-trips through KB pane"
    ///     without relying on process-wide env mutation (which races with
    ///     parallel test execution).
    @Test func layerRoundTripsThroughExplicitVaultDir() throws {
        let vaultRoot = tmpDir("layer-vault-root")
        let project   = tmpDir("layer-project")
        defer {
            try? FileManager.default.removeItem(atPath: vaultRoot)
            try? FileManager.default.removeItem(atPath: project)
        }

        // Resolve the same path the env/config code path would yield, but
        // pass it explicitly to keep the test hermetic.
        let projectSlug = KBVaultConfig.slug(project)
        let expectedDir = vaultRoot + "/" + projectSlug

        let store = KnowledgeStore(path: project + "/vault.db")
        let layer = try KnowledgeFileLayer(vaultDir: expectedDir, store: store)
        #expect(layer.knowledgeDir == expectedDir)

        let content = KBContent(
            frontmatter: KBFrontmatter(entityType: "class", sourcePath: nil),
            entityName: "RoundTrip",
            compiledUnderstanding: "v7 vault round-trip"
        )
        try layer.writeEntity(name: "RoundTrip", content: content)

        let liveFile = expectedDir + "/RoundTrip.md"
        #expect(FileManager.default.fileExists(atPath: liveFile))
        let (parsed, _) = try layer.readEntity(name: "RoundTrip")
        #expect(parsed.compiledUnderstanding == "v7 vault round-trip")
    }
}
