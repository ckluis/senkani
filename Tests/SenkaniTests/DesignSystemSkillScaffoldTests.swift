import Foundation
import Testing
@testable import Core

// MARK: - Fixture helpers

private func makeFixtureRoot() throws -> String {
    let root = "/tmp/senkani-design-system-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    return root
}

private func writeFile(_ path: String, _ content: String) throws {
    let dir = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try content.write(toFile: path, atomically: true, encoding: .utf8)
}

private func validHandManifestJSON(name: String, description: String) -> String {
    """
    {
      "schema_version": 1,
      "name": "\(name)",
      "description": "\(description)",
      "version": "0.1.0",
      "tools": [],
      "settings": {},
      "metrics": [],
      "system_prompt": {
        "phases": [{"name": "preamble", "body": "You apply design-system patterns."}]
      },
      "skill_md": "Body.",
      "guardrails": {"requires_confirm": [], "egress_allow": [], "secret_scope": "none"},
      "cadence": {"triggers": []},
      "sandbox": "none",
      "capabilities": []
    }
    """
}

/// Path to the project root. Tests for the in-tree
/// `spec/design-system/manifest.json` + `spec/design_system_patterns.md`
/// run against the working repo so a regression in either artifact
/// is caught immediately.
private func repoRoot() -> String {
    let here = #filePath
    var dir = (here as NSString).deletingLastPathComponent
    while !dir.isEmpty, !FileManager.default.fileExists(atPath: dir + "/Package.swift") {
        let parent = (dir as NSString).deletingLastPathComponent
        if parent == dir { break }
        dir = parent
    }
    return dir
}

// MARK: - V.10a — DesignSystemSkill scaffold

@Suite("V.10a — DesignSystemSkill scaffold")
struct DesignSystemSkillScaffoldTests {

    // 1. spec/design-system/manifest.json decodes into HandManifest v1.
    @Test("in-repo manifest.json decodes as HandManifest v1")
    func manifestDecodes() throws {
        let path = repoRoot() + "/spec/design-system/manifest.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let manifest = try JSONDecoder().decode(HandManifest.self, from: data)
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.name == "design-system")
        #expect(!manifest.description.isEmpty)
    }

    // 2. The in-repo manifest passes lint.
    @Test("in-repo manifest.json lints clean")
    func manifestLintsClean() throws {
        let path = repoRoot() + "/spec/design-system/manifest.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let issues = HandManifestLinter.lintJSON(data)
        let messages = issues.map(\.message).joined(separator: "; ")
        #expect(!HandManifestLinter.hasErrors(issues),
                "expected zero errors, got: \(messages)")
    }

    // 3. spec/design-system/patterns/ exists (with a .gitkeep so the
    // empty directory is preserved in version control).
    @Test("spec/design-system/patterns/ directory exists")
    func patternsDirExists() {
        let dir = repoRoot() + "/spec/design-system/patterns"
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dir, isDirectory: &isDir)
        #expect(exists)
        #expect(isDir.boolValue)
    }

    // 4. Starter spec stub exists at spec/design_system_patterns.md.
    @Test("spec/design_system_patterns.md stub exists")
    func patternSpecStubExists() {
        let path = repoRoot() + "/spec/design_system_patterns.md"
        #expect(FileManager.default.fileExists(atPath: path))
    }

    // 5. Stub contains the four canonical section headings.
    @Test("pattern spec stub contains four section headings")
    func patternSpecHasFourSections() throws {
        let path = repoRoot() + "/spec/design_system_patterns.md"
        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content.contains("## Spacing"))
        #expect(content.contains("## Contrast"))
        #expect(content.contains("## Hierarchy"))
        #expect(content.contains("## Type scale"))
    }

    // 6. SkillScanner picks up project-local HandManifest manifests
    // under spec/<dir>/manifest.json and tags them source=project,
    // type=skill.
    @Test("SkillScanner discovers project-local HandManifest skill")
    func scannerDiscoversProjectManifest() throws {
        let cwd = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(atPath: cwd) }
        let home = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let manifestPath = cwd + "/spec/design-system/manifest.json"
        try writeFile(manifestPath,
                      validHandManifestJSON(name: "design-system",
                                            description: "Project design system."))

        let skills = SkillScanner.scan(homeDir: home, cwd: cwd)
        let found = skills.first { $0.name == "design-system" && $0.type == .skill }
        #expect(found != nil)
        #expect(found?.source == "project")
        #expect(found?.filePath == manifestPath)
    }

    // 7. Env isolation: only `manifest.json` files under spec/<dir>/
    // are scanned. Random JSON files under spec/ are ignored.
    @Test("scanner ignores non-manifest JSON files under spec/")
    func scannerIgnoresNonManifestJSON() throws {
        let cwd = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(atPath: cwd) }
        let home = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try writeFile(cwd + "/spec/random/data.json", "{\"hello\": \"world\"}")
        try writeFile(cwd + "/spec/random/notes.md", "# Notes\n")

        let skills = SkillScanner.scan(homeDir: home, cwd: cwd)
        let projectSkills = skills.filter { $0.source == "project" && $0.type == .skill }
        #expect(projectSkills.isEmpty)
    }

    // 8. Env isolation: a file under spec/<dir>/manifest.json that
    // is NOT a HandManifest v1 (missing schema_version, wrong
    // shape) is silently skipped — `senkani skill lint` is the
    // surface that flags malformed files; the scanner stays quiet.
    @Test("scanner skips malformed manifest.json silently")
    func scannerSkipsMalformedManifest() throws {
        let cwd = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(atPath: cwd) }
        let home = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try writeFile(cwd + "/spec/garbage/manifest.json",
                      "{\"unrelated\": true}")

        let skills = SkillScanner.scan(homeDir: home, cwd: cwd)
        let projectSkills = skills.filter { $0.source == "project" && $0.type == .skill }
        #expect(projectSkills.isEmpty)
    }
}

// MARK: - V.10a — A/B render-mode resolver

@Suite("V.10a — HTMLPreviewMode A/B resolver")
struct HTMLPreviewModeResolverTests {

    // 9. V.10a: both modes resolve to the same input path
    // (byte-equality across the toggle, surface-only proof).
    @Test("resolve(for:mode:) is identity in V.10a")
    func resolveIsIdentityForBothModes() {
        let path = "/tmp/example.html"
        #expect(HTMLPreviewModeResolver.resolve(for: path, mode: .original) == path)
        #expect(HTMLPreviewModeResolver.resolve(for: path, mode: .designSystem) == path)
    }

    // 10. Toggle persistence + render-once probe: switching modes
    // increments the per-mode counter exactly once, and the input
    // path is unchanged after the resolution.
    @Test("toggle bumps per-mode counter once per call without mutating input")
    func toggleBumpsPerModeCounterOnce() {
        HTMLPreviewModeResolver.invocationCounter.reset()
        let path = "/tmp/persistent.html"
        let beforeOriginal = HTMLPreviewModeResolver.invocationCounter.count(for: .original)
        let beforeDesign = HTMLPreviewModeResolver.invocationCounter.count(for: .designSystem)

        let r1 = HTMLPreviewModeResolver.resolve(for: path, mode: .original)
        let r2 = HTMLPreviewModeResolver.resolve(for: path, mode: .designSystem)

        #expect(r1 == path)
        #expect(r2 == path)
        #expect(HTMLPreviewModeResolver.invocationCounter.count(for: .original)
                == beforeOriginal + 1)
        #expect(HTMLPreviewModeResolver.invocationCounter.count(for: .designSystem)
                == beforeDesign + 1)

        // Mode default is `.original` — verifying the case ordering
        // exposed by `allCases` (drives the segmented control's tag
        // order in `HTMLPreviewView`).
        #expect(HTMLPreviewMode.allCases.first == .original)
    }
}
