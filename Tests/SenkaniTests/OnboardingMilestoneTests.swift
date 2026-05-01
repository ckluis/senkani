import Testing
import Foundation
@testable import Core

// Coverage for `onboarding-p2-early-use-milestones`.
//
// Exercises three Core types + one source-level wiring guard:
//   - `OnboardingMilestone` — the seven-case enum and the canonical
//     copy table.
//   - `OnboardingMilestoneStore` — file-backed log at
//     `~/.senkani/onboarding/milestones.json` (mode 0600). Tests run
//     under a tmp `home` so the suite never touches the user's real
//     state.
//   - `OnboardingMilestoneProgression` — pure derivation: next
//     milestone, summary, time-to-first-win.
//   - `WelcomeView.swift` — source-level guard that the SwiftUI
//     surface consumes the progression and reads the store, so a
//     refactor that drops the wiring fails the suite without
//     linking SwiftUI.

private let repoRootMS: String = {
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

private func readSource(_ rel: String) -> String {
    let path = (repoRootMS as NSString).appendingPathComponent(rel)
    return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

private func makeTempHome() -> String {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("senkani-milestones-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(
        atPath: base,
        withIntermediateDirectories: true
    )
    return base
}

@Suite("Onboarding P2 — early-use milestones")
struct OnboardingMilestoneTests {

    // MARK: - Enum + copy table

    @Test("Seven milestones in canonical surfacing order")
    func enumOrderIsStable() {
        let cases = OnboardingMilestone.allCases.map(\.rawValue)
        #expect(cases == [
            "projectSelected",
            "agentLaunched",
            "firstTrackedEvent",
            "firstNonzeroSavings",
            "firstBudgetSet",
            "firstWorkstreamCreated",
            "firstStagedProposalReviewed",
        ], "Surfacing order must stay stable so the Welcome banner keeps walking the same sequence; got \(cases).")
        #expect(OnboardingMilestoneProgression.order == OnboardingMilestone.allCases,
                "Progression.order must match the enum's allCases order.")
    }

    @Test("Every milestone has title + populating event + next-action copy")
    func copyTableIsComplete() {
        for milestone in OnboardingMilestone.allCases {
            let entry = OnboardingMilestoneCopy.entry(for: milestone)
            #expect(entry.milestone == milestone)
            #expect(!entry.title.isEmpty,
                    "Title missing for \(milestone).")
            #expect(!entry.populatingEvent.isEmpty,
                    "Populating-event copy missing for \(milestone) — explains what triggers it.")
            #expect(!entry.nextAction.isEmpty,
                    "Next-action imperative missing for \(milestone) — that is what the banner renders.")
        }
    }

    // MARK: - Store: round-trip + idempotency + reset

    @Test("Empty store reports no completed milestones")
    func emptyStoreIsEmpty() {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(OnboardingMilestoneStore.completed(home: home).isEmpty)
        #expect(!OnboardingMilestoneStore.isCompleted(.projectSelected, home: home))
        #expect(OnboardingMilestoneStore.completedAt(.projectSelected, home: home) == nil)
    }

    @Test("record persists timestamp + survives a fresh read")
    func recordPersists() {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let when = Date(timeIntervalSince1970: 1_745_000_000)
        let wrote = OnboardingMilestoneStore.record(.projectSelected, at: when, home: home)
        #expect(wrote, "First record for a milestone must report it wrote.")
        let stored = OnboardingMilestoneStore.completedAt(.projectSelected, home: home)
        #expect(stored != nil, "Recorded milestone must round-trip via fresh read.")
        if let stored {
            // ISO-8601 with fractional seconds round-trips at millisecond
            // resolution — accept up to 1ms drift.
            #expect(abs(stored.timeIntervalSince(when)) < 0.01,
                    "Persisted timestamp drifted: stored=\(stored) wrote=\(when).")
        }
    }

    @Test("record is idempotent — first observation wins")
    func recordIsIdempotent() {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let later = Date(timeIntervalSince1970: 1_750_000_000)

        #expect(OnboardingMilestoneStore.record(.agentLaunched, at: first, home: home))
        #expect(!OnboardingMilestoneStore.record(.agentLaunched, at: later, home: home),
                "Re-recording must report no-op.")
        let stored = OnboardingMilestoneStore.completedAt(.agentLaunched, home: home)
        #expect(stored != nil)
        if let stored {
            #expect(abs(stored.timeIntervalSince(first)) < 0.01,
                    "First observation must win — got \(stored), expected ~\(first).")
        }
    }

    @Test("reset deletes the file outright")
    func resetClearsState() {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        OnboardingMilestoneStore.record(.projectSelected, home: home)
        OnboardingMilestoneStore.record(.agentLaunched, home: home)
        #expect(OnboardingMilestoneStore.completed(home: home).count == 2)

        OnboardingMilestoneStore.reset(home: home)
        #expect(OnboardingMilestoneStore.completed(home: home).isEmpty,
                "reset must clear every recorded milestone.")
        #expect(!FileManager.default.fileExists(
            atPath: OnboardingMilestoneStore.filePath(home: home)),
                "reset must remove the JSON file from disk, not just empty it.")
    }

    @Test("File path lives under ~/.senkani/onboarding/milestones.json")
    func filePathHonorsConvention() {
        let home = "/tmp/example-home"
        let path = OnboardingMilestoneStore.filePath(home: home)
        #expect(path == "/tmp/example-home/.senkani/onboarding/milestones.json",
                "Path layout must match the spec; got \(path).")
        #expect(OnboardingMilestoneStore.relativePath ==
                ".senkani/onboarding/milestones.json")
    }

    @Test("File on disk is mode 0600 (owner read/write only)")
    func filePermissionsAreOwnerOnly() throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        OnboardingMilestoneStore.record(.firstTrackedEvent, home: home)
        let attrs = try FileManager.default.attributesOfItem(
            atPath: OnboardingMilestoneStore.filePath(home: home))
        let posix = attrs[.posixPermissions] as? NSNumber
        #expect(posix?.intValue == 0o600,
                "Store file must be 0600 — milestone log is user-local data; got \(String(describing: posix)).")
    }

    @Test("Env gate SENKANI_ONBOARDING_MILESTONES=off no-ops every API")
    func envGateNoOps() {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let off = ["SENKANI_ONBOARDING_MILESTONES": "OFF"]
        #expect(!OnboardingMilestoneStore.isEnabled(env: off))

        let wrote = OnboardingMilestoneStore.record(
            .projectSelected, home: home, env: off
        )
        #expect(!wrote, "record must report no-op when the gate is off.")
        #expect(!FileManager.default.fileExists(
            atPath: OnboardingMilestoneStore.filePath(home: home)),
                "record must not even create the file when the gate is off.")
        #expect(OnboardingMilestoneStore.completed(home: home, env: off).isEmpty,
                "completed must return empty when the gate is off.")
    }

    // MARK: - Progression

    @Test("next() returns the first milestone when nothing is done")
    func nextWhenEmpty() {
        let next = OnboardingMilestoneProgression.next(after: [])
        #expect(next == .projectSelected,
                "Empty completed-set must yield the first milestone in order; got \(String(describing: next)).")
    }

    @Test("next() skips completed milestones and returns the first hole")
    func nextSkipsCompletedPrefix() {
        let done: Set<OnboardingMilestone> = [.projectSelected, .agentLaunched]
        #expect(OnboardingMilestoneProgression.next(after: done) == .firstTrackedEvent)

        // Out-of-order completion still surfaces the lowest-order missing item.
        let weirdOrder: Set<OnboardingMilestone> = [
            .projectSelected, .firstTrackedEvent,
        ]
        #expect(OnboardingMilestoneProgression.next(after: weirdOrder) == .agentLaunched)
    }

    @Test("next() returns nil after every milestone fires")
    func nextWhenAllDone() {
        let done = Set(OnboardingMilestone.allCases)
        #expect(OnboardingMilestoneProgression.next(after: done) == nil)
    }

    @Test("summary carries counts, next-entry, allComplete, progress label")
    func summaryShape() {
        let summaryEmpty = OnboardingMilestoneProgression.summary(completed: [])
        #expect(summaryEmpty.totalCount == 7)
        #expect(summaryEmpty.completedCount == 0)
        #expect(summaryEmpty.next == .projectSelected)
        #expect(summaryEmpty.nextEntry?.milestone == .projectSelected)
        #expect(summaryEmpty.allComplete == false)
        #expect(summaryEmpty.progressLabel == "0 of 7")

        let summaryMid = OnboardingMilestoneProgression.summary(
            completed: [.projectSelected, .agentLaunched]
        )
        #expect(summaryMid.completedCount == 2)
        #expect(summaryMid.next == .firstTrackedEvent)
        #expect(summaryMid.progressLabel == "2 of 7")

        let summaryDone = OnboardingMilestoneProgression.summary(
            completed: Set(OnboardingMilestone.allCases)
        )
        #expect(summaryDone.completedCount == 7)
        #expect(summaryDone.next == nil)
        #expect(summaryDone.nextEntry == nil)
        #expect(summaryDone.allComplete == true)
        #expect(summaryDone.progressLabel == "7 of 7")
    }

    @Test("elapsed() computes time-to-first-win between two milestones")
    func elapsedIsForwardOnly() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(60)
        let completed: [OnboardingMilestone: Date] = [
            .projectSelected: t0,
            .agentLaunched: t1,
        ]
        let forward = OnboardingMilestoneProgression.elapsed(
            from: .projectSelected, to: .agentLaunched, in: completed
        )
        #expect(forward == 60, "Forward elapsed must equal seconds between timestamps.")

        let reversed = OnboardingMilestoneProgression.elapsed(
            from: .agentLaunched, to: .projectSelected, in: completed
        )
        #expect(reversed == nil,
                "Reversed (to earlier than from) must yield nil — clamps disable bogus negatives.")

        let missing = OnboardingMilestoneProgression.elapsed(
            from: .projectSelected, to: .firstTrackedEvent, in: completed
        )
        #expect(missing == nil, "Missing endpoint must yield nil.")
    }

    // MARK: - Source-level wiring guard

    @Test("WelcomeView wires the milestone store into the next-step banner")
    func welcomeViewWiresMilestoneSurface() {
        let src = readSource("SenkaniApp/Views/WelcomeView.swift")
        #expect(!src.isEmpty,
                "SenkaniApp/Views/WelcomeView.swift must exist.")
        #expect(src.contains("OnboardingMilestoneStore.completed"),
                "WelcomeView must read the milestone store so the banner refresh sees recorded milestones.")
        #expect(src.contains("OnboardingMilestoneProgression.summary"),
                "WelcomeView must derive the next-step summary from the progression helper.")
        #expect(src.contains("OnboardingNextStepBanner"),
                "WelcomeView must render the OnboardingNextStepBanner.")
    }
}
