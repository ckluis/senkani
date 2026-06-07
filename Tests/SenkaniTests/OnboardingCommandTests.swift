import Testing
import Foundation
@testable import CLI
@testable import Core

/// Coverage for `senkani onboarding milestones` — the read-only
/// verification surface filed against
/// `onboarding-milestones-cli-surface-or-env-var-verification-path-2026-05-11`
/// (Finding #C from the 2026-05-11 onboarding-pass walk).
///
/// Both tests drive the pure `Onboarding.Milestones.render(env:home:)`
/// renderer rather than spawning the `senkani` binary, so the four-line
/// output contract is verified in-process. The `withTestHome` redirect
/// + an explicit `env:` dictionary keep the user's real
/// `~/.senkani/onboarding/milestones.json` out of the test path.
@Suite("Onboarding milestones — CLI verification surface")
struct OnboardingCommandTests {

    private func makeTempHome() -> String {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("senkani-onboarding-cli-\(UUID().uuidString)")
            .path
        try? FileManager.default.createDirectory(
            atPath: base,
            withIntermediateDirectories: true
        )
        return base
    }

    @Test("Env-var-on path: prints `on`, the resolved path, pretty-printed JSON, and a true allComplete when every milestone is on disk")
    func envOnPrintsOnDiskJsonAndAllCompleteTrue() {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        // Seed every milestone so allComplete derives true. The
        // recorder honors the env gate, so this write runs under an
        // explicit empty env (the gate stays ON by default).
        OnboardingMilestoneStore.withTestHome(home) {
            for milestone in OnboardingMilestone.allCases {
                OnboardingMilestoneStore.record(milestone, home: home, env: [:])
            }
        }

        // Env unset → `isEnabled` returns true → first line says `on`.
        let output = OnboardingMilestoneStore.withTestHome(home) {
            Onboarding.Milestones.render(env: [:], home: home)
        }

        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "SENKANI_ONBOARDING_MILESTONES: on",
                "First line must report env-var status; got `\(lines.first ?? "")`")

        let expectedPathLine = "path: \(OnboardingMilestoneStore.filePath(home: home))"
        #expect(lines.dropFirst().first.map(String.init) == expectedPathLine,
                "Second line must be `path: <absolute>`; got `\(lines.dropFirst().first ?? "")`")

        // Contents block: parse what the command printed and assert
        // every milestone rawValue is present as a key. The block lives
        // between the path line and the trailing summary line; concat
        // the middle slice and re-decode it.
        #expect(lines.last == "summary.allComplete: true",
                "Last line must be `summary.allComplete: <bool>`; got `\(lines.last ?? "")`")

        let middle = lines.dropFirst(2).dropLast().joined(separator: "\n")
        let data = Data(middle.utf8)
        let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(decoded != nil,
                "Middle block must be valid JSON; got `\(middle)`")
        let keys: Set<String> = Set(decoded?.keys ?? Dictionary<String, String>().keys)
        let expectedKeys = Set(OnboardingMilestone.allCases.map(\.rawValue))
        #expect(keys == expectedKeys,
                "Every milestone rawValue must appear as a JSON key; got \(keys)")

        // The subcommand must not mutate state — re-read should match.
        let before = try? Data(contentsOf: URL(fileURLWithPath: OnboardingMilestoneStore.filePath(home: home)))
        _ = OnboardingMilestoneStore.withTestHome(home) {
            Onboarding.Milestones.render(env: [:], home: home)
        }
        let after = try? Data(contentsOf: URL(fileURLWithPath: OnboardingMilestoneStore.filePath(home: home)))
        #expect(before == after, "Renderer must not mutate the milestone file")
    }

    @Test("Env-var-off path: prints `off` on line one but still surfaces on-disk JSON and the derived allComplete, even when the gate would normally silence reads")
    func envOffStillPrintsOnDiskTruth() {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        // Seed a partial state — three milestones present, four
        // missing → allComplete should derive false.
        let seeded: [OnboardingMilestone] = [
            .projectSelected, .agentLaunched, .firstTrackedEvent,
        ]
        OnboardingMilestoneStore.withTestHome(home) {
            for m in seeded {
                OnboardingMilestoneStore.record(m, home: home, env: [:])
            }
        }

        // Drive the renderer with the env gate explicitly OFF. Per the
        // privacy contract, the env var is opt-out-of-recording; the
        // verification surface deliberately bypasses it on reads so a
        // walk operator who set `=off` can still confirm prior state.
        let output = OnboardingMilestoneStore.withTestHome(home) {
            Onboarding.Milestones.render(
                env: ["SENKANI_ONBOARDING_MILESTONES": "off"],
                home: home
            )
        }

        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "SENKANI_ONBOARDING_MILESTONES: off",
                "First line must report env-var as `off`; got `\(lines.first ?? "")`")

        let expectedPathLine = "path: \(OnboardingMilestoneStore.filePath(home: home))"
        #expect(lines.dropFirst().first.map(String.init) == expectedPathLine,
                "Second line must still report the absolute path; got `\(lines.dropFirst().first ?? "")`")

        #expect(lines.last == "summary.allComplete: false",
                "allComplete must derive from on-disk truth (3 of 7 → false), independent of env gate; got `\(lines.last ?? "")`")

        let middle = lines.dropFirst(2).dropLast().joined(separator: "\n")
        let data = Data(middle.utf8)
        let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(decoded != nil,
                "Even with `=off`, the JSON contents block must surface on-disk truth; got `\(middle)`")
        let keys: Set<String> = Set(decoded?.keys ?? Dictionary<String, String>().keys)
        let expectedKeys = Set(seeded.map(\.rawValue))
        #expect(keys == expectedKeys,
                "Only the seeded milestones should appear; got \(keys)")
    }

    @Test("Missing-file path: env-var-on, `(file does not exist yet)` middle block, allComplete false, exit-clean")
    func absentFileSentinelAndAllCompleteFalse() {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        // No seeding — the file does not exist under `home`.
        let output = OnboardingMilestoneStore.withTestHome(home) {
            Onboarding.Milestones.render(env: [:], home: home)
        }

        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "SENKANI_ONBOARDING_MILESTONES: on")
        #expect(lines.contains("(file does not exist yet)"),
                "Absent-file sentinel must appear in the middle block; got `\(output)`")
        #expect(lines.last == "summary.allComplete: false")
    }
}
