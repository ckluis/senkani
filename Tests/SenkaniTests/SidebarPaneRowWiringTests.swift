import Testing
import Foundation

/// V.3d wiring bridge — SOURCE-SHAPE + structural-presence tests for the
/// `SidebarView` per-pane row scaffold and the `SenkaniApp` probe/coordinator/
/// resolver wiring (`PaneMetadataWiring`).
///
/// These mirror the `BrowserPaneRunnerEgressWiringTests.swift` precedent:
/// `SenkaniApp` is an *executable* target with no `@testable` coverage in this
/// repo, so nothing behavioral can be linked here. The wiring + row-structure
/// contract is asserted against the SOURCE TEXT — the per-pane `ForEach`
/// sub-list, the resolver property + read seam on `SidebarView`, the
/// `PaneMetadataProbes(runner: SystemProcessRunner())` construction, the
/// resolver binding, and the coordinator construction.
///
/// What is EXPLICITLY NOT proven here (deferred to the sibling
/// `phase-v3d-sidebar-chips-popover-visual-walk` Cowork walk): chip content
/// correctness, absent-metadata-renders-nothing, the PR-chip click opening the
/// browser, the hover popover (content + redaction), the perceived <100ms p95
/// render timing, and every port/branch/PR staleness-window threshold. A green
/// suite here proves the wiring call-shape is in the source, NOT that any
/// chip renders.
@Suite("V.3d sidebar per-pane row + probe/coordinator/resolver wiring — source-shape")
struct SidebarPaneRowWiringTests {

    /// Walk up from the current directory to locate the `SenkaniApp` target
    /// dir (CWD is the package root under `swift test`). Returns nil when run
    /// from outside a checkout so the tests skip gracefully rather than
    /// false-fail (the egress-wiring precedent's resolution strategy).
    private static func appDir() -> URL? {
        var cur = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = cur.appendingPathComponent("SenkaniApp", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = cur.deletingLastPathComponent()
            if parent.path == cur.path { break }
            cur = parent
        }
        return nil
    }

    private static func source(_ relativePath: String) throws -> String? {
        guard let dir = appDir() else { return nil }
        let url = dir.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Acceptance bullet 1 — per-pane row sub-list in SidebarView

    @Test("SidebarView gains a per-pane row sub-list inside the project row (a `ForEach(project.panes)` + a `paneRow` builder) — structurally absent before this bridge")
    func sidebarHasPerPaneRowSubList() throws {
        guard let source = try Self.source("Views/SidebarView.swift") else { return }

        #expect(source.contains("ForEach(project.panes)"),
                "SidebarView must render a per-pane row sub-list inside the project row via `ForEach(project.panes)` — before this bridge the only `ForEach` was `ForEach(workspace.projects)`, so there was no per-pane sub-list at all")
        #expect(source.contains("func paneRow("),
                "SidebarView must declare a `paneRow(_:)` row builder — the per-pane row scaffold this wiring bridge adds")
        // The prior sole `ForEach` stays — the sub-list nests inside it.
        #expect(source.contains("ForEach(workspace.projects)"),
                "The project `ForEach(workspace.projects)` must remain — the per-pane sub-list nests inside each project row, it does not replace the project list")
    }

    // MARK: - Acceptance bullet 2/3 — resolver observed by the sidebar

    @Test("SidebarView declares the observed `PaneMetadataResolver` and reads the per-pane snapshot via the synchronous cache-hit `metadata(for:)` seam")
    func sidebarObservesResolver() throws {
        guard let source = try Self.source("Views/SidebarView.swift") else { return }

        #expect(source.contains("let paneMetadataResolver: PaneMetadataResolver"),
                "SidebarView must declare `let paneMetadataResolver: PaneMetadataResolver` — the resolver ContentView binds in (wired to the real probes + coordinator) that the sidebar observes")
        #expect(source.contains("paneMetadataResolver.metadata(for:"),
                "The per-pane row must read its cached snapshot via `paneMetadataResolver.metadata(for:)` — the synchronous cache-hit hover read path that makes the <100ms p95 budget achievable by construction")
    }

    // MARK: - Acceptance bullet 2 — probes constructed with SystemProcessRunner

    @Test("PaneMetadataWiring constructs `PaneMetadataProbes(runner: SystemProcessRunner())` — the real lsof/git/gh probes")
    func wiringConstructsProbesWithSystemProcessRunner() throws {
        guard let source = try Self.source("Services/PaneMetadataWiring.swift") else { return }

        #expect(source.contains("PaneMetadataProbes(runner: SystemProcessRunner())"),
                "PaneMetadataWiring must construct `PaneMetadataProbes(runner: SystemProcessRunner())` — the real argv-seam probes (untrusted branch/dir strings never touch a shell), not a mock")
    }

    // MARK: - Acceptance bullet 2/3 — resolver binding + coordinator + live pane fields

    @Test("PaneMetadataWiring binds the probe closures into a PaneMetadataResolver, constructs the v3c PaneMetadataRefreshCoordinator, and tracks panes with live fields")
    func wiringBindsResolverAndConstructsCoordinator() throws {
        guard let source = try Self.source("Services/PaneMetadataWiring.swift") else { return }

        // Resolver constructed and bound to the probes' three closures.
        #expect(source.contains("PaneMetadataResolver("),
                "PaneMetadataWiring must construct a `PaneMetadataResolver`")
        #expect(source.contains("portProbe: probes.portProbe"),
                "The resolver must be wired with `probes.portProbe` so `ingestPort` routes through the real lsof probe")
        #expect(source.contains("branchProbe: probes.branchProbe"),
                "The resolver must be wired with `probes.branchProbe` so `ingestBranch` routes through the real git probe")
        #expect(source.contains("prProbe: probes.prProbe"),
                "The resolver must be wired with `probes.prProbe` so `ingestPR` routes through the real gh probe")

        // v3c coordinator constructed against the resolver.
        #expect(source.contains("PaneMetadataRefreshCoordinator(resolver: resolver)"),
                "PaneMetadataWiring must construct the phase-v3c `PaneMetadataRefreshCoordinator(resolver:)` — the resolver holds the probes, the coordinator schedules ingest")

        // Panes tracked with live fields: shellPid → port-probe key,
        // workingDirectory → git working dir (branch resolves from it).
        #expect(source.contains(".addPane("),
                "PaneMetadataWiring must track each pane via `coordinator.addPane(...)`")
        #expect(source.contains("paneId: pane.id.uuidString"),
                "Each pane must be tracked under its `pane.id.uuidString` (the resolver/coordinator pane key)")
        #expect(source.contains("String(pane.shellPid"),
                "The port-probe key must be the live `String(pane.shellPid ...)` — the lsof PGID key")
        #expect(source.contains("pane.workingDirectory"),
                "The tracked working directory must be the live `pane.workingDirectory` — the git branch/PR probes key off it")
    }

    // MARK: - Acceptance bullet 3 — ContentView binds the resolver into the sidebar

    @Test("ContentView constructs PaneMetadataWiring and passes its resolver into SidebarView (the resolver is observed by the sidebar)")
    func contentViewBindsResolverIntoSidebar() throws {
        guard let source = try Self.source("Views/ContentView.swift") else { return }

        #expect(source.contains("PaneMetadataWiring()"),
                "ContentView must construct the app-level `PaneMetadataWiring()` bridge")
        #expect(source.contains("paneMetadataResolver: paneMetadata.resolver"),
                "ContentView must pass `paneMetadata.resolver` into `SidebarView` — binding the resolver so the sidebar observes it")
        #expect(source.contains("paneMetadata.sync(panes:") || source.contains("syncPaneMetadata("),
                "ContentView must reconcile the coordinator against live panes (via `paneMetadata.sync(panes:)` / `syncPaneMetadata()`) so tracked panes follow the workspace")
    }
}
