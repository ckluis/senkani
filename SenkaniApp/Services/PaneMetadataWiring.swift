import Foundation
import Core

/// V.3d — app-level wiring bridge that constructs the shipped v3a/v3c
/// pane-metadata stack and drives it from the live workspace panes.
///
/// ## Ownership chain (per `PaneMetadataRefreshCoordinator`'s header contract)
///
///   PaneMetadataProbes(runner: SystemProcessRunner())   — the real lsof/git/gh probes
///     → PaneMetadataResolver(portProbe:branchProbe:prProbe:)  — probes bound in
///       → PaneMetadataRefreshCoordinator(resolver:)     — schedules the ingest cadences
///
/// The resolver holds the probe closures; the coordinator does NOT hold
/// probes, it schedules `resolver.ingest*` calls on the 5s port poll + the
/// per-pane FSEvents branch refresh. `SidebarView` observes `resolver` for
/// the synchronous cache-hit `metadata(for:)` hover read (never blocks on a
/// probe or DB — that is what makes the parent's <100ms p95 hover budget
/// achievable by construction).
///
/// ## Live pane fields
///
/// `sync(panes:)` reconciles the coordinator's tracked set against the live
/// workspace panes, keying each on its live fields:
///   - `String(pane.shellPid ?? 0)` — the lsof port-probe PGID key.
///   - `pane.workingDirectory`      — the git working dir; the branch probe
///     resolves the branch from it, and the PR probe keys off that resolved
///     branch (the coordinator threads branch → PR internally).
///
/// ## Testability honesty
///
/// `SenkaniApp` has no `@testable` coverage in this repo, so this wiring is
/// proven by SOURCE-SHAPE tests only (the `BrowserPaneRunnerEgressWiringTests`
/// precedent — `SidebarPaneRowWiringTests`). NOTHING behavioral is proven
/// here: chip content correctness, the hover popover (content + redaction),
/// the PR-chip click, and the perceived <100ms p95 render timing are all
/// explicitly deferred to the sibling
/// `phase-v3d-sidebar-chips-popover-visual-walk` Cowork walk. This type only
/// establishes the construction + reconcile seams.
///
/// Mirrors `LaunchCoordinator`'s plain-`final class` shape: not `@MainActor`,
/// so `ContentView` can construct it in a `@State` initializer; its callers
/// (`sync` / `start` / `stop`) are driven from the main-actor view lifecycle.
final class PaneMetadataWiring {

    /// The shipped probes, constructed with the real `SystemProcessRunner`
    /// (argv seam — untrusted branch/dir strings never touch a shell).
    let probes: PaneMetadataProbes

    /// The resolver `SidebarView` observes for synchronous hover reads. Wired
    /// with the probes' port/branch/PR closures so every `ingest*` routes
    /// through the real lsof/git/gh probes.
    let resolver: PaneMetadataResolver

    /// The v3c refresh coordinator — schedules the 5s port poll + the
    /// per-pane FSEvents branch refresh across every tracked pane.
    let coordinator: PaneMetadataRefreshCoordinator

    init() {
        let probes = PaneMetadataProbes(runner: SystemProcessRunner())
        let resolver = PaneMetadataResolver(
            portProbe: probes.portProbe,
            branchProbe: probes.branchProbe,
            prProbe: probes.prProbe
        )
        self.probes = probes
        self.resolver = resolver
        self.coordinator = PaneMetadataRefreshCoordinator(resolver: resolver)
    }

    // MARK: - Lifecycle

    /// Start the port poll + all tracked panes' branch watchers. Idempotent
    /// (the coordinator no-ops a second `start()`).
    func start() {
        coordinator.start()
    }

    /// Stop the port poll and every branch watcher. Idempotent.
    func stop() {
        coordinator.stop()
    }

    // MARK: - Reconcile

    /// Reconcile the coordinator's tracked panes against the live workspace
    /// panes. Untracks panes that have gone away, then (re-)adds every current
    /// pane with its live fields. Re-adding an existing `paneId` replaces its
    /// registration (coordinator contract), so this is idempotent — safe to
    /// call on every pane-structure change.
    func sync(panes: [PaneModel]) {
        let live = Set(panes.map { $0.id.uuidString })
        for tracked in coordinator.trackedPaneIDs where !live.contains(tracked) {
            coordinator.removePane(paneId: tracked)
        }
        for pane in panes {
            coordinator.addPane(
                paneId: pane.id.uuidString,
                portProbeKey: String(pane.shellPid ?? 0),
                workingDirectory: pane.workingDirectory
            )
        }
    }
}
