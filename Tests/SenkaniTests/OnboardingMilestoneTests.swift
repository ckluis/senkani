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

    @Test("Canonical raw-value spelling is pinned per case (locks casing — `firstNonzeroSavings` lowercase `z`)")
    func canonicalRawValueSpellingIsPinned() {
        // Lock the literal `String` rawValue for every case so the
        // on-disk JSON key cannot silently drift across a rename.
        // Filed as `onboarding-milestones-key-casing-mismatch-2026-05-14`
        // after a walk-time discrepancy between operator-written AC
        // text (capital `Z` typo) and the actual recorder output
        // (lowercase `z`). The recorder has always been canonical;
        // this test makes the canonical spelling load-bearing test
        // state, so a future case rename must come through here.
        let expected: [OnboardingMilestone: String] = [
            .projectSelected:             "projectSelected",
            .agentLaunched:               "agentLaunched",
            .firstTrackedEvent:           "firstTrackedEvent",
            .firstNonzeroSavings:         "firstNonzeroSavings",
            .firstBudgetSet:              "firstBudgetSet",
            .firstWorkstreamCreated:      "firstWorkstreamCreated",
            .firstStagedProposalReviewed: "firstStagedProposalReviewed",
        ]
        for milestone in OnboardingMilestone.allCases {
            guard let want = expected[milestone] else {
                Issue.record("New milestone case \(milestone) added without a canonical-spelling pin in this test.")
                continue
            }
            #expect(milestone.rawValue == want,
                    "Canonical spelling drift for \(milestone): expected '\(want)', got '\(milestone.rawValue)'.")
        }
        #expect(expected.count == OnboardingMilestone.allCases.count,
                "Pin table must cover every case; got \(expected.count) pins for \(OnboardingMilestone.allCases.count) cases.")
    }

    @Test("Store silently drops unknown on-disk keys — legacy/non-canonical entries cannot crash a read")
    func storeIgnoresUnknownOnDiskKeys() throws {
        // Durable evidence for AC #4 of
        // `onboarding-milestones-key-casing-mismatch-2026-05-14`:
        // no migration shipped because no existing install holds a
        // non-canonical key (the recorder is Codable-driven on the
        // canonical rawValue), AND the store tolerates unknown keys
        // on read (see Sources/Core/OnboardingMilestoneStore.swift
        // around the `OnboardingMilestone(rawValue: key)` guard).
        // This test pins both halves of that contract so a future
        // refactor cannot weaken either.
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let dir = (home as NSString).appendingPathComponent(".senkani/onboarding")
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        let path = OnboardingMilestoneStore.filePath(home: home)
        // Hand-written JSON mixing one canonical key, one hypothetical
        // legacy capital-Z key (the typo from Finding #D), and one
        // junk key. Only the canonical key must surface on read.
        let json = """
        {
          "firstNonzeroSavings": "2026-05-13T19:40:08.572Z",
          "firstNonZeroSavings": "2026-05-13T19:40:08.572Z",
          "totallyUnknownLegacyKey": "2026-05-13T19:40:08.572Z"
        }
        """
        try json.write(toFile: path, atomically: true, encoding: .utf8)

        let completed = OnboardingMilestoneStore.completed(home: home)
        #expect(completed[.firstNonzeroSavings] != nil,
                "Canonical key must round-trip from a hand-written file.")
        #expect(completed.count == 1,
                "Only the canonical key may surface; got \(completed.count) entries from a 3-key file.")
        let landedKeys = completed.keys.map(\.rawValue).sorted()
        #expect(landedKeys == ["firstNonzeroSavings"],
                "Unknown keys must be silently dropped; got \(landedKeys).")
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

    @Test("Concurrent records on distinct milestones all land — no lost-update race",
          .timeLimit(.minutes(1)))
    func recordIsSerializedAcrossConcurrentMilestones() async {
        // Fix verification for
        // `onboarding-milestone-recorder-gap-projectSelected-agentLaunched-2026-05-14`:
        // before this round, `record()` had a TOCTOU between the
        // `completed(...)` read and the `write(...)` call. Two
        // concurrent records on different milestones could each read
        // the same baseline, mutate their own snapshot, and write
        // back — last write wins, the other's update vanishes.
        // The recordLock now serializes the critical section.
        //
        // We exercise the race by firing N records per milestone
        // concurrently via `withTaskGroup`. After the storm, every
        // one of the seven milestone keys must be on disk.
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        let storms = 16  // per-milestone concurrent record fan-out
        let baseDate = Date(timeIntervalSince1970: 1_750_000_000)

        await withTaskGroup(of: Void.self) { group in
            for (index, milestone) in OnboardingMilestone.allCases.enumerated() {
                for storm in 0..<storms {
                    let when = baseDate.addingTimeInterval(
                        Double(index * storms + storm)
                    )
                    group.addTask {
                        _ = OnboardingMilestoneStore.record(
                            milestone, at: when, home: home
                        )
                    }
                }
            }
        }

        let completed = OnboardingMilestoneStore.completed(home: home)
        let landedKeys = completed.keys.map(\.rawValue).sorted()
        for milestone in OnboardingMilestone.allCases {
            #expect(completed[milestone] != nil,
                    "Concurrent record storm dropped \(milestone). Got keys: \(landedKeys).")
        }
        #expect(completed.count == OnboardingMilestone.allCases.count,
                "Exactly 7 keys must land; got \(completed.count).")
    }

    @Test("record(home: nil) does not deadlock against concurrent withTestHome (AB-BA fix verification)",
          .timeLimit(.minutes(1)))
    func recordWithNilHomeDoesNotDeadlockAgainstWithTestHome() {
        // Fix verification for
        // `swift-test-serial-full-suite-stall-investigation-2026-05-18`:
        // before the 2026-05-21 lock-order fix, two threads could
        // deadlock as follows:
        //   - Thread A: `withTestHome(temp) { ... }` holds
        //     `testHomeOverrideLock` across its body. Inside the body
        //     it calls `record(home: nil)`, which (pre-fix) takes
        //     `recordLock`, then re-enters `testHomeOverrideLock` via
        //     `resolveDefaultHome` (recursive — fine on the same
        //     thread).
        //   - Thread B: calls `record(home: nil)` directly. Pre-fix:
        //     takes `recordLock` first, then blocks at
        //     `resolveDefaultHome` → `testHomeOverrideLock` (held by
        //     A).
        //   - Now A's inner record can't take `recordLock` (B holds
        //     it). AB-BA deadlock. The serial-mode full-suite hang
        //     observed 2026-05-18 (30+ min wall, 19s CPU, S-state)
        //     traced to exactly this inversion via a `sample` taken
        //     2026-05-21.
        //
        // Post-fix: `record` resolves `home` BEFORE taking
        // `recordLock`. Thread B briefly waits on
        // `testHomeOverrideLock` while A is inside `withTestHome`,
        // then proceeds. No cross-lock dependency cycle.
        //
        // The race window is narrow but deterministic given an
        // explicit signal. We coordinate via `DispatchSemaphore`:
        // Thread A signals it has entered `withTestHome` and slept
        // briefly; Thread B then enters `record(home: nil)` while A
        // is still in the body and about to call its own inner
        // `record`. Pre-fix this deadlocks → `.timeLimit(.minutes(1))`
        // fires the time limit and the test fails. Post-fix both
        // tasks complete in well under a second.
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        // Use a fresh enough home so the test doesn't read leftover
        // state. The two milestones (`projectSelected` and
        // `firstNonzeroSavings`) are chosen so the "first observation
        // wins" idempotency doesn't shadow either record.

        let enteredWithTestHome = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        // Use raw GCD threads — this test must run two threads that
        // exercise the lock-order inversion, and
        // `DispatchSemaphore.wait()` is unavailable from Swift
        // concurrency async contexts.

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            OnboardingMilestoneStore.withTestHome(home) {
                // Signal B that we hold testHomeOverrideLock.
                enteredWithTestHome.signal()
                // Give B time to enter `record(home: nil)` and block
                // (pre-fix: at testHomeOverrideLock after taking
                // recordLock; post-fix: at testHomeOverrideLock
                // BEFORE taking recordLock).
                Thread.sleep(forTimeInterval: 0.15)
                // Pre-fix outcome: blocks on recordLock (held by B).
                // Post-fix outcome: resolveDefaultHome recursively
                // re-enters testHomeOverrideLock on our own thread
                // (NSRecursiveLock; succeeds), then takes recordLock
                // cleanly because B never reached recordLock.
                _ = OnboardingMilestoneStore.record(
                    .projectSelected, home: nil)
            }
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            // Wait for A to enter withTestHome (testHomeOverrideLock
            // held).
            enteredWithTestHome.wait()
            // Pre-fix: takes recordLock first, then blocks on
            // testHomeOverrideLock (held by A in withTestHome). A
            // then tries recordLock → AB-BA deadlock.
            // Post-fix: blocks on testHomeOverrideLock at the very
            // first step (resolveDefaultHome), recordLock untouched
            // during the wait. When A exits withTestHome,
            // testHomeOverrideLock releases and we proceed.
            _ = OnboardingMilestoneStore.record(
                .firstNonzeroSavings, home: nil)
        }

        // Bound at 30s — pre-fix the deadlock is permanent so any
        // finite bound surfaces the regression; post-fix this returns
        // in well under a second.
        let timeout = group.wait(timeout: .now() + .seconds(30))
        #expect(timeout == .success,
                "Cross-thread record(home: nil) + withTestHome must NOT deadlock; both tasks failed to finish within 30s.")

        // Primary assertion: neither task deadlocked (we reached this
        // line within the .timeLimit). The temp home should now hold
        // `projectSelected` (recorded by A, which was inside
        // withTestHome so `home: nil` resolved to `home`). B's record
        // may have written to either `home` (if B's call happened
        // while A still held testHomeOverrideLock) or to NSHomeDirectory()
        // (if B's record happened after A released). We don't assert
        // B's destination — only that the deadlock is broken.
        let completed = OnboardingMilestoneStore.completed(home: home)
        #expect(completed[.projectSelected] != nil,
                "Task A's record inside withTestHome must have landed in temp home.")
    }

    @Test("record does not enforce predecessor chain — Progression owns ordering")
    func recordDoesNotEnforcePredecessorChain() {
        // The "Atomicity contract" doc on OnboardingMilestoneStore
        // pins this as intentional: the Store is a passive observer,
        // the chain logic lives in OnboardingMilestoneProgression.
        // Recording `firstTrackedEvent` without `projectSelected`
        // must succeed and write only the recorded key — no
        // backfill, no refusal. The UI surface reads the
        // Progression's "next" ordering, which surfaces
        // `projectSelected` for the user to cross on its own merits.
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let when = Date(timeIntervalSince1970: 1_750_000_000)

        let wrote = OnboardingMilestoneStore.record(
            .firstTrackedEvent, at: when, home: home
        )
        #expect(wrote,
                "record must succeed when a predecessor is missing — the Store is observation-level, not a state machine.")

        let completed = OnboardingMilestoneStore.completed(home: home)
        #expect(completed[.firstTrackedEvent] != nil,
                "firstTrackedEvent must persist.")
        #expect(completed[.projectSelected] == nil,
                "Predecessor must NOT be backfilled — that's a Progression concern, not a Store concern.")
        #expect(completed[.agentLaunched] == nil,
                "Predecessor must NOT be backfilled — same rationale.")
        let landedKeys = completed.keys.map(\.rawValue).sorted()
        #expect(completed.count == 1,
                "Exactly one key must land; got keys \(landedKeys).")

        // The UI surface (read via Progression) sees `projectSelected`
        // as the next step the user should cross, even though
        // `firstTrackedEvent` already fired out of order. This is the
        // canonical recovery path for the recorder-fired-out-of-order
        // case (e.g. operator `rm -f` of the file mid-walk).
        let summary = OnboardingMilestoneProgression.summary(
            completed: Set(completed.keys)
        )
        #expect(summary.next == .projectSelected,
                "Progression must surface projectSelected as next even though firstTrackedEvent already fired — chain reasoning lives in Progression, not Store.")
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
