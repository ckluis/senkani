import Testing
import Foundation
@testable import Core

/// Coverage for `t6-notification-production-hookup-missing-2026-05-17`.
///
/// Exercises:
///   - `NotificationDelivery` — process-global router holder. Default
///     state is `nil` (CLI / test processes that never `install(_:)`
///     see no banners). `install(_:)` swaps; `deliver(_:)` fans out;
///     `resetForTesting()` clears.
///   - `OnboardingMilestoneStore.record` — when an installed router
///     is present, the first-time record of `firstNonzeroSavings`
///     fires a `NotifyEvent.notifyDone` through it; the second
///     record is a no-op (already-completed milestone).
///   - `MacOSLocalSink` × `SpyLocalNotifierBridge` — round-trips the
///     payload bytes a real UN-backed bridge would receive.
///   - `NotificationRouter.Config` honours the `ConfirmationGate`-
///     adjacent "this sink does NOT receive this event class"
///     contract via per-sink `events` subscriptions.
///
/// Threading note: `NotificationDelivery` is a process-global holder.
/// Tests serialize their own use via `.serialized` on the @Suite so
/// install/deliver/reset cycles can't race across parallel cases.
/// (The holder is locked at the API boundary; the @Suite serialization
/// guarantees test-write semantics — each case sees the resetted
/// state.)

private func makeTempHomeNDT() -> String {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("senkani-notif-delivery-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(
        atPath: base,
        withIntermediateDirectories: true
    )
    return base
}

@Suite("T.6 NotificationDelivery — production hookup", .serialized)
struct NotificationDeliveryTests {

    @Test("Default holder is nil — deliver is a silent no-op")
    func defaultIsNil() {
        NotificationDelivery.resetForTesting()
        #expect(NotificationDelivery.isInstalled == false)
        // No router installed; this MUST NOT throw, hang, or crash.
        NotificationDelivery.deliver(
            .notifyDone(toolName: "test", summary: "no-op")
        )
    }

    @Test("install + deliver fans out to subscribed sinks")
    func installFansOut() {
        NotificationDelivery.resetForTesting()
        let bridge = SpyLocalNotifierBridge()
        let sink = MacOSLocalSink(bridge: bridge)
        let router = NotificationRouter(entries: [
            .init(name: "macos_local", sink: sink, events: Set(NotificationRouter.EventKind.allCases))
        ])
        NotificationDelivery.install(router)
        #expect(NotificationDelivery.isInstalled == true)

        NotificationDelivery.deliver(
            .notifyDone(toolName: "onboarding", summary: "Save your first tokens")
        )

        #expect(bridge.posted.count == 1)
        let posted = bridge.posted[0]
        #expect(posted.title == "Senkani — done")
        #expect(posted.subtitle == "onboarding")
        #expect(posted.body == "Save your first tokens")
        NotificationDelivery.resetForTesting()
    }

    @Test("install replaces the prior router — second install wins")
    func installReplaces() {
        NotificationDelivery.resetForTesting()
        let bridgeA = SpyLocalNotifierBridge()
        let bridgeB = SpyLocalNotifierBridge()
        let routerA = NotificationRouter(entries: [
            .init(name: "macos_local", sink: MacOSLocalSink(bridge: bridgeA),
                  events: Set(NotificationRouter.EventKind.allCases))
        ])
        let routerB = NotificationRouter(entries: [
            .init(name: "macos_local", sink: MacOSLocalSink(bridge: bridgeB),
                  events: Set(NotificationRouter.EventKind.allCases))
        ])

        NotificationDelivery.install(routerA)
        NotificationDelivery.install(routerB)
        NotificationDelivery.deliver(.notifyDone(toolName: "x", summary: "y"))

        #expect(bridgeA.posted.isEmpty,
                "Router A was replaced before deliver; it must not see the event.")
        #expect(bridgeB.posted.count == 1)
        NotificationDelivery.resetForTesting()
    }

    @Test("ConfirmationGate-adjacent: a sink that does NOT subscribe to the event class is silent")
    func unsubscribedSinkIsSilent() {
        NotificationDelivery.resetForTesting()
        let bridge = SpyLocalNotifierBridge()
        let sink = MacOSLocalSink(bridge: bridge)
        // Sink subscribes to `notifyFailure` + `scheduleEnd` ONLY —
        // the operator opted OUT of `notifyDone` banners. The router
        // MUST NOT fan a `notifyDone` event to this sink.
        let router = NotificationRouter(entries: [
            .init(name: "macos_local", sink: sink, events: [.notifyFailure, .scheduleEnd])
        ])
        NotificationDelivery.install(router)

        NotificationDelivery.deliver(.notifyDone(toolName: "t", summary: "s"))
        #expect(bridge.posted.isEmpty,
                "ConfirmationGate-adjacent: unsubscribed sinks must not receive the event.")

        NotificationDelivery.deliver(.notifyFailure(toolName: "t", reason: "boom"))
        #expect(bridge.posted.count == 1)
        #expect(bridge.posted[0].title == "Senkani — failed")
        NotificationDelivery.resetForTesting()
    }

    @Test("OnboardingMilestoneStore.record fires NotifyEvent on first firstNonzeroSavings — idempotent on re-record")
    func onboardingProducerFiresOnce() {
        NotificationDelivery.resetForTesting()
        let bridge = SpyLocalNotifierBridge()
        let router = NotificationRouter(entries: [
            .init(name: "macos_local", sink: MacOSLocalSink(bridge: bridge),
                  events: Set(NotificationRouter.EventKind.allCases))
        ])
        NotificationDelivery.install(router)

        let home = makeTempHomeNDT()
        defer { try? FileManager.default.removeItem(atPath: home) }

        // First record — banner fires.
        let firstRecorded = OnboardingMilestoneStore.record(.firstNonzeroSavings, home: home)
        #expect(firstRecorded == true)
        #expect(bridge.posted.count == 1)
        #expect(bridge.posted[0].title == "Senkani — done")
        #expect(bridge.posted[0].subtitle == "onboarding")
        #expect(bridge.posted[0].body == "Save your first tokens")

        // Second record of the same milestone — idempotent, NO new banner.
        let secondRecorded = OnboardingMilestoneStore.record(.firstNonzeroSavings, home: home)
        #expect(secondRecorded == false)
        #expect(bridge.posted.count == 1,
                "Re-recording an already-completed milestone must not re-fire the banner.")

        NotificationDelivery.resetForTesting()
    }

    @Test("OnboardingMilestoneStore.record does NOT fire for non-celebrate milestones (projectSelected silent)")
    func onboardingProducerSilentOnProjectSelected() {
        NotificationDelivery.resetForTesting()
        let bridge = SpyLocalNotifierBridge()
        let router = NotificationRouter(entries: [
            .init(name: "macos_local", sink: MacOSLocalSink(bridge: bridge),
                  events: Set(NotificationRouter.EventKind.allCases))
        ])
        NotificationDelivery.install(router)

        let home = makeTempHomeNDT()
        defer { try? FileManager.default.removeItem(atPath: home) }

        let recorded = OnboardingMilestoneStore.record(.projectSelected, home: home)
        #expect(recorded == true)
        #expect(bridge.posted.isEmpty,
                "projectSelected is intentionally silent — operator just clicked into the app, no banner needed.")

        NotificationDelivery.resetForTesting()
    }

    @Test("Production producer is no-op when NotificationDelivery is uninstalled (CLI / test default)")
    func producerNoOpWithoutInstall() {
        NotificationDelivery.resetForTesting()
        #expect(NotificationDelivery.isInstalled == false)

        let home = makeTempHomeNDT()
        defer { try? FileManager.default.removeItem(atPath: home) }

        // No bridge installed; record MUST NOT throw, hang, or crash.
        let recorded = OnboardingMilestoneStore.record(.firstNonzeroSavings, home: home)
        #expect(recorded == true)
        // No spy bridge in scope — the assertion is that this returns
        // without exception. The contract: a CLI / MCP process that
        // never wires a router behaves identically to today (silent).
    }

    @Test("PresetPrerequisiteCheck — macos-local-notification-sink probes as ready (shipped)")
    func macosLocalSinkProbesReady() {
        // Construct a synthetic ScheduledPreset that declares the
        // sink as a prerequisite. The probe MUST return nil (no
        // warning) — the capability is shipped as of this round.
        let preset = ScheduledPreset(
            name: "synthetic-t6-test",
            cronPattern: "0 9 * * *",
            command: "true",
            engine: .shell,
            description: "Synthetic preset for the T.6 prereq probe check.",
            docUrl: "https://example.invalid/t6",
            prerequisites: ["macos-local-notification-sink"]
        )
        let result = PresetPrerequisiteCheck.check(preset)
        #expect(result.warnings.isEmpty,
                "macos-local-notification-sink must probe as ready post-T.6; got warnings: \(result.warnings)")
        #expect(result.ready.contains("macos-local-notification-sink"))
    }
}
