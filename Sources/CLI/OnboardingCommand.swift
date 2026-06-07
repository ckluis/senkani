import ArgumentParser
import Core
import Foundation

/// `senkani onboarding milestones` — read-only verification surface for
/// the local onboarding milestone state.
///
/// Background: `~/.senkani/onboarding/milestones.json` is the file
/// `OnboardingMilestoneStore` writes into on each once-only milestone
/// observation. Walks of the onboarding pass need a way to verify two
/// things in one shot:
///   1. Whether the `SENKANI_ONBOARDING_MILESTONES` env gate is
///      currently ON (default) or OFF (opt-out-of-recording).
///   2. What the on-disk JSON actually contains — independent of the
///      env gate, so a walk operator who set `=off` can still confirm
///      the prior state is what they expect.
///
/// The store's `completed(home:env:)` short-circuits to empty when the
/// env gate is off (the gate applies to both reads and writes inside
/// the store). The subcommand deliberately bypasses the gate on its
/// read path by reading the JSON file directly via `FileManager`, so
/// `=off` cannot hide on-disk truth from the verification surface.
/// The env-var status is printed on its own line so the operator sees
/// both signals together.
///
/// Originating finding: `release-v0-3-0-onboarding-pass` 2026-05-11 walk,
/// Finding #C (AC #4 sub-clause #7 — env-var no-op verification).
struct Onboarding: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "onboarding",
        abstract: "Inspect onboarding milestone state.",
        subcommands: [Milestones.self],
        defaultSubcommand: Milestones.self
    )

    struct Milestones: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "milestones",
            abstract: "Print env-var status and on-disk milestone JSON (read-only)."
        )

        func run() throws {
            print(Onboarding.Milestones.render(env: nil, home: nil))
        }

        /// Pure renderer. Both `env` and `home` are injectable so
        /// in-process tests can drive the four-line contract without
        /// spawning the `senkani` binary. `nil` means "use the
        /// process-global default" — the production `run()` path.
        ///
        /// Output shape (stable; operator scripts grep these prefixes):
        ///
        ///   SENKANI_ONBOARDING_MILESTONES: on|off
        ///   path: <absolute path to milestones.json>
        ///   <pretty-printed JSON, OR `(file does not exist yet)`>
        ///   summary.allComplete: true|false
        static func render(env: [String: String]?, home: String?) -> String {
            let envOn = OnboardingMilestoneStore.isEnabled(env: env)
            let envLine = "SENKANI_ONBOARDING_MILESTONES: \(envOn ? "on" : "off")"

            let path = OnboardingMilestoneStore.filePath(home: home)
            let pathLine = "path: \(path)"

            let (contentsBlock, parsedKeys) = readContents(at: path)

            let summary = OnboardingMilestoneProgression.summary(
                completed: parsedKeys
            )
            let summaryLine = "summary.allComplete: \(summary.allComplete)"

            return [envLine, pathLine, contentsBlock, summaryLine]
                .joined(separator: "\n")
        }

        private static func readContents(
            at path: String
        ) -> (block: String, keys: Set<OnboardingMilestone>) {
            guard FileManager.default.fileExists(atPath: path) else {
                return ("(file does not exist yet)", [])
            }
            guard let data = FileManager.default.contents(atPath: path) else {
                return ("(file present but unreadable)", [])
            }
            if let raw = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(
                    withJSONObject: raw,
                    options: [.prettyPrinted, .sortedKeys]
               ) {
                var keys: Set<OnboardingMilestone> = []
                if let dict = raw as? [String: Any] {
                    for key in dict.keys {
                        if let m = OnboardingMilestone(rawValue: key) {
                            keys.insert(m)
                        }
                    }
                }
                return (String(decoding: pretty, as: UTF8.self), keys)
            }
            // File exists but isn't JSON — surface raw bytes so the
            // operator sees corruption directly rather than a generic
            // "(unreadable)" message.
            if let s = String(data: data, encoding: .utf8) {
                return (s, [])
            }
            return ("(file present but unreadable)", [])
        }
    }
}
