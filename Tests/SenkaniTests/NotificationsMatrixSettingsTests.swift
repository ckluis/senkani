import Testing
import Foundation
@testable import Core

// Coverage for `t6-settings-notifications-matrix-ui-2026-05-21` —
// Settings → Notifications matrix pane (code slice; the visual render
// walk is the operator Cowork remainder).
//
// Covers:
//  (a) Behavioral: `NotificationMatrix` (Core) — the headless cell
//      read/flip semantics every pane checkbox funnels through.
//      Default-on for absent sinks, single-cell flips, canonical
//      event ordering, unknown-event forward-compat, byte-stable
//      writes through the T.6 writer.
//  (b) Behavioral: the pane's live-reload contract, headless — a
//      toggled config saved to disk, reloaded, routed via
//      `NotificationRouter.make`, installed over the prior router
//      (install replaces), and proven against `SpyLocalNotifierBridge`
//      that subsequent NotifyEvent fires honor / suppress per the
//      matrix state. This mirrors line-for-line what
//      `NotificationBootstrap.bootstrap(configPath:)` runs when the
//      pane flips a cell.
//  (c) Source-level guards: `NotificationsSettingsView` exists with
//      the matrix + writer + live-reload + test-fire shape; ToolView /
//      ContentView / SidebarView wiring is present; the bootstrap
//      exposes the sink registry the pane renders.
//
// SenkaniApp targets aren't linkable from SenkaniTests (see
// ProjectWorkstreamRemoveUITests for the precedent), so (c) reads
// source text and asserts marker strings, and (b) re-runs the
// bootstrap's loadConfig → make → install lines against Core directly.

private let repoRootNMS: String = {
    var url = URL(fileURLWithPath: #filePath)
    while url.pathComponents.count > 1 {
        url.deleteLastPathComponent()
        let pkg = url.appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: pkg.path) {
            return url.path
        }
    }
    return FileManager.default.currentDirectoryPath
}()

private func readSourceNMS(_ rel: String) -> String {
    let path = (repoRootNMS as NSString).appendingPathComponent(rel)
    return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

private func makeTempPathNMS() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("senkani-notif-matrix-\(UUID().uuidString).json")
        .path
}

// MARK: - Suite 1: NotificationMatrix headless semantics

@Suite("T.6 matrix — NotificationMatrix cell semantics")
struct NotificationMatrixSemanticsTests {

    @Test("Absent sink is default-on for every event class")
    func absentSinkDefaultOn() {
        let empty = NotificationRouter.Config(sinks: [:])
        for kind in NotificationRouter.EventKind.allCases {
            #expect(NotificationMatrix.isEnabled(empty, sink: "stdout", event: kind),
                    "A sink with no config entry must read enabled for \(kind.rawValue) — the router's opt-OUT contract.")
        }
    }

    @Test("Explicit subscription reads exactly its listed events")
    func explicitSubscriptionReads() {
        let config = NotificationRouter.Config(sinks: [
            "macos_local": .init(events: ["notify_failure", "schedule_end"])
        ])
        #expect(!NotificationMatrix.isEnabled(config, sink: "macos_local", event: .notifyDone))
        #expect(NotificationMatrix.isEnabled(config, sink: "macos_local", event: .notifyFailure))
        #expect(NotificationMatrix.isEnabled(config, sink: "macos_local", event: .scheduleEnd))
        // Sibling sink stays default-on.
        #expect(NotificationMatrix.isEnabled(config, sink: "stdout", event: .notifyDone))
    }

    @Test("First flip on an absent sink materializes default-on minus exactly one cell")
    func firstFlipMaterializesSingleCell() {
        let empty = NotificationRouter.Config(sinks: [:])
        let toggled = NotificationMatrix.toggled(empty, sink: "macos_local", event: .notifyDone)

        #expect(toggled.sinks["macos_local"]?.events == ["notify_failure", "schedule_end"],
                "Materialized subscription must be the full default minus ONLY the flipped cell, in canonical order.")
        #expect(toggled.sinks["stdout"] == nil,
                "Other sinks must be untouched (still implicit default-on).")
        // Cell reads flip; every other cell unchanged.
        #expect(!NotificationMatrix.isEnabled(toggled, sink: "macos_local", event: .notifyDone))
        #expect(NotificationMatrix.isEnabled(toggled, sink: "macos_local", event: .notifyFailure))
        #expect(NotificationMatrix.isEnabled(toggled, sink: "stdout", event: .notifyDone))
    }

    @Test("Flip off then on round-trips to the full subscription in canonical order")
    func flipRoundTrip() {
        let empty = NotificationRouter.Config(sinks: [:])
        let off = NotificationMatrix.toggled(empty, sink: "stdout", event: .scheduleEnd)
        let on = NotificationMatrix.toggled(off, sink: "stdout", event: .scheduleEnd)
        #expect(on.sinks["stdout"]?.events == ["notify_done", "notify_failure", "schedule_end"],
                "Re-enabling must restore the full set in EventKind.allCases order.")
    }

    @Test("Canonical order is restored regardless of on-disk event order")
    func canonicalOrderRestored() {
        let scrambled = NotificationRouter.Config(sinks: [
            "stdout": .init(events: ["schedule_end", "notify_done"])
        ])
        let toggled = NotificationMatrix.toggled(scrambled, sink: "stdout", event: .notifyFailure)
        #expect(toggled.sinks["stdout"]?.events == ["notify_done", "notify_failure", "schedule_end"],
                "Known events must be written in EventKind.allCases order for deterministic bytes.")
    }

    @Test("Forward-compat: unknown event names survive a flip, after the known ones")
    func unknownEventsPreserved() {
        let config = NotificationRouter.Config(sinks: [
            "stdout": .init(events: ["notify_done", "future_event"])
        ])
        let off = NotificationMatrix.toggled(config, sink: "stdout", event: .notifyDone)
        #expect(off.sinks["stdout"]?.events == ["future_event"],
                "Disabling the only known event must not drop the unknown one.")
        let on = NotificationMatrix.toggled(off, sink: "stdout", event: .notifyFailure)
        #expect(on.sinks["stdout"]?.events == ["notify_failure", "future_event"],
                "Known events lead in canonical order; unknown names follow in original order.")
    }

    @Test("A toggled config is byte-stable through the T.6 writer")
    func toggledConfigByteStable() throws {
        let toggled = NotificationMatrix.toggled(
            NotificationMatrix.toggled(
                NotificationRouter.Config(sinks: [:]),
                sink: "macos_local", event: .notifyDone),
            sink: "stdout", event: .scheduleEnd)

        let path = makeTempPathNMS()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try toggled.save(to: path)

        let reloaded = try #require(NotificationRouter.loadConfig(from: path))
        #expect(reloaded == toggled)
        #expect(try reloaded.encoded() == toggled.encoded(),
                "encode(decode(save(x))) must be byte-identical — the pane re-saves must stay diff-quiet.")
    }

    @Test("displaySinks: known sinks lead in registration order; config extras follow alphabetically")
    func displaySinkOrdering() {
        let config = NotificationRouter.Config(sinks: [
            "zeta_sink": .init(events: ["notify_done"]),
            "macos_local": .init(events: ["notify_failure"]),
            "audit_log": .init(events: ["notify_done"]),
        ])
        let rows = NotificationMatrix.displaySinks(
            config: config, knownSinks: ["stdout", "macos_local"])
        #expect(rows == ["stdout", "macos_local", "audit_log", "zeta_sink"],
                "Hand-added config sinks must be shown (sorted), never silently hidden.")
    }
}

// MARK: - Suite 2: live-reload contract over the spy bridge

@Suite("T.6 matrix — live-reload honors the toggled matrix (spy bridge)")
struct NotificationsMatrixLiveReloadTests {

    /// Mirror of `NotificationBootstrap.bootstrap(configPath:)`'s
    /// loadConfig → make lines, with the spy bridge standing in for
    /// the UN-backed one and a mock sink standing in for stdout.
    /// SenkaniApp isn't linkable from this target; the source-guard
    /// suite pins that the pane calls the real bootstrap.
    ///
    /// Deliberately does NOT install into the process-global
    /// `NotificationDelivery` holder: sibling suites
    /// (`NotificationDeliveryTests`, `ScheduleEndNotifierTests`,
    /// `ConfirmationGateTests`) exercise that global in parallel
    /// (per-suite `.serialized` does not order ACROSS suites), so a
    /// reset/install here races their install/deliver windows. The
    /// install-replaces semantics the pane relies on are already
    /// pinned by `NotificationDeliveryTests.installReplaces`; this
    /// suite proves the reloaded ROUTER honors the toggled matrix.
    private func reloadRouter(
        configPath: String,
        bridge: SpyLocalNotifierBridge,
        stdout: MockNotificationSink
    ) -> NotificationRouter {
        let config = NotificationRouter.loadConfig(from: configPath)
            ?? NotificationRouter.Config(sinks: [:])
        return NotificationRouter.make(
            sinks: [
                (name: "stdout", sink: stdout),
                (name: "macos_local", sink: MacOSLocalSink(bridge: bridge))
            ],
            config: config
        )
    }

    @Test("Toggle a cell off → save → reload: the spy bridge stops seeing that class; toggle back on → reload: it sees it again")
    func toggleOffThenOnHonoredAcrossReloads() throws {
        let path = makeTempPathNMS()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let bridge = SpyLocalNotifierBridge()
        let stdout = MockNotificationSink()

        // 1. No config file — default-on. The banner sink sees notifyDone.
        var router = reloadRouter(configPath: path, bridge: bridge, stdout: stdout)
        router.deliver(.notifyDone(toolName: "t", summary: "before"))
        #expect(bridge.posted.count == 1)
        #expect(stdout.delivered.count == 1)

        // 2. Operator unticks (macos_local, notify_done) in the matrix:
        //    toggled → save → live reload (the pane re-bootstraps).
        let off = NotificationMatrix.toggled(
            NotificationRouter.Config(sinks: [:]),
            sink: "macos_local", event: .notifyDone)
        try off.save(to: path)
        router = reloadRouter(configPath: path, bridge: bridge, stdout: stdout)

        router.deliver(.notifyDone(toolName: "t", summary: "suppressed"))
        #expect(bridge.posted.count == 1,
                "After the off-flip reload, macos_local must NOT see notify_done — no app restart required.")
        #expect(stdout.delivered.count == 2,
                "The untouched stdout row must keep receiving notify_done.")

        // Other classes for the toggled sink still flow (single-cell flip).
        router.deliver(.notifyFailure(toolName: "t", reason: "still on"))
        #expect(bridge.posted.count == 2)
        #expect(bridge.posted.last?.title == "Senkani — failed")

        // 3. Operator re-ticks the cell: toggled → save → reload.
        let on = NotificationMatrix.toggled(off, sink: "macos_local", event: .notifyDone)
        try on.save(to: path)
        router = reloadRouter(configPath: path, bridge: bridge, stdout: stdout)

        router.deliver(.notifyDone(toolName: "t", summary: "after"))
        #expect(bridge.posted.count == 3,
                "After the on-flip reload, macos_local must see notify_done again.")
        #expect(bridge.posted.last?.body == "after")
    }

    @Test("Test-fire affordance shape: a delivered event reaches ONLY the subscribed sinks under the saved matrix")
    func testFireRespectsMatrix() throws {
        let path = makeTempPathNMS()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let bridge = SpyLocalNotifierBridge()
        let stdout = MockNotificationSink()

        // Matrix state: stdout opted out of schedule_end; banners full-on.
        let config = NotificationMatrix.toggled(
            NotificationRouter.Config(sinks: [:]),
            sink: "stdout", event: .scheduleEnd)
        try config.save(to: path)
        let router = reloadRouter(configPath: path, bridge: bridge, stdout: stdout)

        // The pane's "Fire schedule end" button delivers this exact
        // event through the installed router.
        router.deliver(.scheduleEnd(scheduleId: "matrix-test", summary: "s"))

        #expect(stdout.delivered.isEmpty,
                "stdout opted out of schedule_end — the test fire must not reach it.")
        #expect(bridge.posted.count == 1)
        #expect(bridge.posted[0].title == "Senkani — schedule")
        #expect(bridge.posted[0].subtitle == "matrix-test")
    }
}

// MARK: - Suite 3: settings pane source guards

@Suite("T.6 matrix — settings pane source guards")
struct NotificationsMatrixSourceGuardTests {

    @Test("NotificationsSettingsView exists and renders the matrix over NotificationMatrix")
    func paneShape() {
        let src = readSourceNMS("SenkaniApp/Views/NotificationsSettingsView.swift")
        #expect(!src.isEmpty, "NotificationsSettingsView.swift must exist")
        #expect(src.contains("struct NotificationsSettingsView: View"),
                "Pane must be a SwiftUI View.")
        #expect(src.contains("NotificationMatrix.isEnabled(config, sink: sink, event: event)"),
                "Every checkbox read must funnel through NotificationMatrix.isEnabled.")
        #expect(src.contains("NotificationMatrix.toggled(config, sink: sink, event: event)"),
                "Every checkbox flip must funnel through NotificationMatrix.toggled.")
        #expect(src.contains("NotificationMatrix.displaySinks("),
                "Row list must come from NotificationMatrix.displaySinks.")
        #expect(src.contains("NotificationRouter.EventKind.allCases"),
                "Columns must enumerate every EventKind — a new variant grows the matrix at compile time.")
    }

    @Test("Pane reads + writes the bootstrap's config path and live-reloads on save")
    func paneDiskAndLiveReloadWiring() {
        let src = readSourceNMS("SenkaniApp/Views/NotificationsSettingsView.swift")
        #expect(src.contains("NotificationBootstrap.defaultConfigPath()"),
                "Default config path must be the bootstrap's (~/.senkani/notifications.json).")
        #expect(src.contains("NotificationRouter.loadConfig(from: configPath)"),
                "Pane must read the config through the router's lenient loader.")
        #expect(src.contains("try updated.save(to: configPath)"),
                "Pane must persist flips through the throwing T.6 writer.")
        #expect(src.contains("NotificationBootstrap.bootstrap(configPath: configPath)"),
                "A successful save must re-bootstrap — the second install replaces the live router.")
        #expect(src.contains("saveError = \"Couldn't write"),
                "A failed write must surface inline, not silently drop the operator's edit.")
        #expect(src.contains("NotificationBootstrap.registeredSinkNames"),
                "Known rows must come from the bootstrap's registry — the production source of truth.")
    }

    @Test("Pane carries the test-fire debug affordance through the live delivery holder")
    func paneTestFireAffordance() {
        let src = readSourceNMS("SenkaniApp/Views/NotificationsSettingsView.swift")
        #expect(src.contains("NotificationDelivery.deliver(event)"),
                "Test fire must go through the process-global holder — the live router path.")
        #expect(src.contains(".notifyDone(") && src.contains(".notifyFailure(")
                    && src.contains(".scheduleEnd("),
                "All three event classes must be fireable for the matrix walk.")
    }

    @Test("ToolView + ContentView route .notifications to the pane")
    func contentViewWiring() {
        let src = readSourceNMS("SenkaniApp/Views/ContentView.swift")
        #expect(src.contains("case models, analytics, skills, schedules, themes, knowledge, trustFlags, notifications"),
                "ToolView must carry the notifications case.")
        #expect(src.contains("case .notifications: NotificationsSettingsView()"),
                "ContentView's tool switch must render the pane.")
    }

    @Test("Sidebar exposes the Notifications tool row")
    func sidebarWiring() {
        let src = readSourceNMS("SenkaniApp/Views/SidebarView.swift")
        #expect(src.contains("label: \"Notifications\""),
                "Sidebar TOOLS section must list Notifications.")
        #expect(src.contains("activateTool(.notifications)"),
                "Row must activate the notifications tool view.")
    }

    @Test("Bootstrap exposes the production sink registry the pane renders")
    func bootstrapRegistry() {
        let src = readSourceNMS("SenkaniApp/Services/NotificationBootstrap.swift")
        #expect(src.contains("static func productionSinks("),
                "Bootstrap must own the single-source-of-truth sink registry.")
        #expect(src.contains("static var registeredSinkNames: [String]"),
                "Registry names must be exposed for the matrix rows.")
        #expect(src.contains("(name: \"stdout\", sink: StdoutSink())")
                    && src.contains("(name: \"macos_local\", sink: MacOSLocalSink(bridge: bridge))"),
                "Production registry must still register stdout + macos_local.")
        #expect(src.contains("sinks: productionSinks(bridge: resolvedBridge)"),
                "bootstrap(...) must build the router from the SAME registry the pane renders.")
    }
}
