import Testing
import Foundation
@testable import Core
@testable import MCPServer

// MARK: - Helpers

private func writeJSON<T: Encodable>(_ value: T, to path: String) throws {
    let data = try JSONEncoder().encode(value)
    let dir = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(
        atPath: dir,
        withIntermediateDirectories: true
    )
    try data.write(to: URL(fileURLWithPath: path))
}

private func makeTempProjectRoot() -> String {
    let root = "/tmp/senkani-manifest-test-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(
        atPath: root,
        withIntermediateDirectories: true
    )
    return root
}

private func cleanup(_ paths: String...) {
    for p in paths {
        try? FileManager.default.removeItem(atPath: p)
    }
}

// MARK: - Manifest + round-trip

@Suite("Manifest — schema + round-trip")
struct ManifestSchemaTests {

    @Test func roundTripJSONPreservesAllFields() throws {
        let original = Manifest(
            skills: ["qa", "ship"],
            mcpTools: ["read", "outline", "exec", "knowledge"],
            hooks: ["PostToolUse:auto-validate"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Manifest.self, from: data)
        #expect(decoded == original)
        #expect(decoded.skills == ["qa", "ship"])
        #expect(decoded.mcpTools.count == 4)
        #expect(decoded.hooks == ["PostToolUse:auto-validate"])
    }

    @Test func coreToolsContainsDocumentedFour() {
        #expect(Manifest.coreTools == ["read", "outline", "deps", "session"])
    }

    @Test func defaultInitIsAllEmpty() {
        let m = Manifest()
        #expect(m.skills.isEmpty)
        #expect(m.mcpTools.isEmpty)
        #expect(m.hooks.isEmpty)
    }
}

// MARK: - Resolver

@Suite("ManifestResolver — effective-set")
struct ManifestResolverTests {

    @Test func teamOnlyIsIdentity() {
        let m = Manifest(mcpTools: ["read", "search", "exec"])
        let eff = ManifestResolver.resolve(manifest: m, overrides: .empty)
        #expect(eff.mcpTools == ["read", "search", "exec"])
        #expect(eff.manifestPresent == true)
    }

    @Test func userOptOutSubtracts() {
        let m = Manifest(mcpTools: ["read", "search", "exec", "web"])
        let o = ManifestOverrides(optOutTools: ["web", "exec"])
        let eff = ManifestResolver.resolve(manifest: m, overrides: o)
        #expect(eff.mcpTools == ["read", "search"])
    }

    @Test func userAdditionsUnion() {
        let m = Manifest(mcpTools: ["read"])
        let o = ManifestOverrides(addTools: ["vision", "embed"])
        let eff = ManifestResolver.resolve(manifest: m, overrides: o)
        #expect(eff.mcpTools == ["read", "vision", "embed"])
    }

    @Test func additionsWinOverOptOuts() {
        // Precedence check: if the same tool name is in BOTH opt-outs
        // AND additions, the addition wins (user-as-tiebreaker).
        let m = Manifest(mcpTools: ["read", "search"])
        let o = ManifestOverrides(optOutTools: ["search"], addTools: ["search"])
        let eff = ManifestResolver.resolve(manifest: m, overrides: o)
        #expect(eff.mcpTools.contains("search"))
    }

    @Test func nilManifestMarksAbsent() {
        let eff = ManifestResolver.resolve(manifest: nil, overrides: .empty)
        #expect(eff.manifestPresent == false)
        #expect(eff.mcpTools.isEmpty)
    }
}

// MARK: - isToolEnabled — core-always-on + backwards-compat

@Suite("EffectiveSet.isToolEnabled")
struct EffectiveSetGatingTests {

    @Test func coreAlwaysOnEvenInEmptyManifest() {
        let m = Manifest(mcpTools: [])
        let eff = ManifestResolver.resolve(manifest: m, overrides: .empty)
        #expect(eff.isToolEnabled("read"))
        #expect(eff.isToolEnabled("outline"))
        #expect(eff.isToolEnabled("deps"))
        #expect(eff.isToolEnabled("session"))
        // Non-core, not listed → disabled
        #expect(eff.isToolEnabled("exec") == false)
    }

    @Test func backwardsCompatWithoutManifestEnablesEverything() {
        let eff = ManifestResolver.resolve(manifest: nil, overrides: .empty)
        #expect(eff.isToolEnabled("read"))       // core
        #expect(eff.isToolEnabled("exec"))       // non-core — but no manifest
        #expect(eff.isToolEnabled("knowledge"))  // non-core — but no manifest
    }

    @Test func nonCoreRequiresManifestListing() {
        let m = Manifest(mcpTools: ["exec"])
        let eff = ManifestResolver.resolve(manifest: m, overrides: .empty)
        #expect(eff.isToolEnabled("exec"))
        #expect(eff.isToolEnabled("knowledge") == false)
    }
}

// MARK: - Loader — files + missing-file fallback

@Suite("ManifestLoader — disk I/O")
struct ManifestLoaderTests {

    @Test func missingProjectManifestReturnsAbsent() {
        let root = makeTempProjectRoot()
        defer { cleanup(root) }

        let overridesURL = URL(fileURLWithPath: "/tmp/senkani-missing-\(UUID().uuidString).json")
        let eff = ManifestLoader.load(projectRoot: root, overridesURL: overridesURL)

        #expect(eff.manifestPresent == false)
        // Backwards-compat: everything enabled
        #expect(eff.isToolEnabled("read"))
        #expect(eff.isToolEnabled("exec"))
    }

    @Test func loadsManifestFromDisk() throws {
        let root = makeTempProjectRoot()
        defer { cleanup(root) }

        let manifestPath = root + "/.senkani/senkani.json"
        try writeJSON(
            Manifest(mcpTools: ["read", "knowledge"]),
            to: manifestPath
        )

        let overridesURL = URL(fileURLWithPath: "/tmp/senkani-missing-\(UUID().uuidString).json")
        let eff = ManifestLoader.load(projectRoot: root, overridesURL: overridesURL)

        #expect(eff.manifestPresent == true)
        #expect(eff.isToolEnabled("read"))
        #expect(eff.isToolEnabled("knowledge"))
        #expect(eff.isToolEnabled("exec") == false)
        #expect(eff.isToolEnabled("outline"))  // core-always-on
    }

    @Test func userOverridesLayerByProjectRoot() throws {
        let root = makeTempProjectRoot()
        defer { cleanup(root) }

        try writeJSON(
            Manifest(mcpTools: ["read", "knowledge"]),
            to: root + "/.senkani/senkani.json"
        )

        let overridesPath = "/tmp/senkani-overrides-\(UUID().uuidString).json"
        defer { cleanup(overridesPath) }
        try writeJSON(
            [root: ManifestOverrides(optOutTools: ["knowledge"], addTools: ["exec"])],
            to: overridesPath
        )

        let eff = ManifestLoader.load(
            projectRoot: root,
            overridesURL: URL(fileURLWithPath: overridesPath)
        )

        #expect(eff.isToolEnabled("knowledge") == false)
        #expect(eff.isToolEnabled("exec"))
        #expect(eff.isToolEnabled("read"))
    }

    @Test func overridesForDifferentProjectAreIgnored() throws {
        let root = makeTempProjectRoot()
        defer { cleanup(root) }

        try writeJSON(
            Manifest(mcpTools: ["read"]),
            to: root + "/.senkani/senkani.json"
        )

        let overridesPath = "/tmp/senkani-overrides-\(UUID().uuidString).json"
        defer { cleanup(overridesPath) }
        // Entry is keyed by a DIFFERENT project root
        try writeJSON(
            ["/some/other/project": ManifestOverrides(addTools: ["exec"])],
            to: overridesPath
        )

        let eff = ManifestLoader.load(
            projectRoot: root,
            overridesURL: URL(fileURLWithPath: overridesPath)
        )

        #expect(eff.isToolEnabled("read"))
        #expect(eff.isToolEnabled("exec") == false)
    }
}

// MARK: - ToolRouter advertise filter + gated dispatch

@Suite("ToolRouter — manifest gating")
struct ToolRouterManifestTests {

    @Test func advertisedToolsIncludesEverythingWhenNoManifest() {
        let eff = ManifestResolver.resolve(manifest: nil, overrides: .empty)
        let names = Set(ToolRouter.advertisedTools(for: eff).map(\.name))
        // All known tool names ship in backwards-compat mode
        #expect(names.contains("read"))
        #expect(names.contains("exec"))
        #expect(names.contains("knowledge"))
        #expect(names.contains("web"))
    }

    @Test func advertisedToolsFiltersToEffectiveSetWhenPresent() {
        let m = Manifest(mcpTools: ["knowledge"])
        let eff = ManifestResolver.resolve(manifest: m, overrides: .empty)
        let names = Set(ToolRouter.advertisedTools(for: eff).map(\.name))
        // Core tools always show
        #expect(names.contains("read"))
        #expect(names.contains("outline"))
        #expect(names.contains("deps"))
        #expect(names.contains("session"))
        // Manifest-listed tool shows
        #expect(names.contains("knowledge"))
        // Unlisted non-core tool is filtered out
        #expect(names.contains("exec") == false)
        #expect(names.contains("web") == false)
    }
}
