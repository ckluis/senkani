import ArgumentParser
import Foundation
import Core

/// `senkani trust` — U.4b-1 operator-facing surface for the
/// `FragmentationDetector` mode flip + per-call override + threshold
/// configuration. Four subcommands; each one a single ParsableCommand
/// so ArgumentParser surfaces structured `--help` per subcommand.
struct Trust: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trust",
        abstract: "Manage FragmentationDetector trust mode (U.4b-1): softFlag (default) or blocking with operator-set FP-rate + sample-size promotion gate.",
        subcommands: [Mode.self, SetMode.self, Override.self, Threshold.self]
    )

    struct Mode: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "mode",
            abstract: "Print the current FragmentationDetector mode (softFlag | blocking)."
        )

        func run() throws {
            let settings = (try? TrustSettingsStore.load()) ?? TrustSettings()
            print(settings.mode.rawValue)
        }
    }

    struct SetMode: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-mode",
            abstract: "Request a mode flip. Demotion (.blocking → .softFlag) is always allowed; promotion (.softFlag → .blocking) is gated on fp_rate_max + min_labeled_sample."
        )

        @Argument(help: "Target mode: 'softFlag' or 'blocking'.")
        var mode: String

        @Option(name: .customLong("operator"), help: "Operator alias recorded in the chained promotion row. Default: $USER or 'cli'.")
        var operatorAlias: String?

        func run() throws {
            guard let target = TrustMode(rawValue: mode) else {
                print("Error: invalid mode '\(mode)'. Expected softFlag or blocking.")
                throw ExitCode.failure
            }
            var settings = (try? TrustSettingsStore.load()) ?? TrustSettings()
            let from = settings.mode
            if target == from {
                print("trust mode already \(target.rawValue) — no-op.")
                return
            }
            let opAlias = operatorAlias
                ?? ProcessInfo.processInfo.environment["USER"]
                ?? "cli"

            if target == .blocking {
                // Promotion gate.
                let stats = SessionDatabase.shared.trustFlagStatsLast30Days()
                let observedRate = PromotionGate.observedRate(fp: stats.confirmedFP, tp: stats.confirmedTP)
                let observedSample = stats.confirmedFP + stats.confirmedTP
                let decision = PromotionGate.evaluate(
                    fpRateMax: settings.fpRateMax,
                    minLabeledSample: settings.minLabeledSample,
                    observedRate: observedRate,
                    observedSample: observedSample
                )
                switch decision {
                case .accept:
                    SessionDatabase.shared.recordTrustPromotion(
                        from: from.rawValue, to: target.rawValue,
                        fpRateMax: settings.fpRateMax,
                        minLabeledSample: settings.minLabeledSample,
                        observedRate: observedRate,
                        observedSample: observedSample,
                        promotedBy: opAlias
                    )
                    settings.mode = .blocking
                    try TrustSettingsStore.save(settings)
                    print("trust mode flipped softFlag → blocking (observed_rate=\(observedRate.map { String(format: "%.3f", $0) } ?? "n/a") observed_sample=\(observedSample))")
                case .reject(let reason):
                    print("Rejected: \(reason)")
                    throw ExitCode.failure
                }
            } else {
                // Demotion path: always allowed; records the row.
                SessionDatabase.shared.recordTrustPromotion(
                    from: from.rawValue, to: target.rawValue,
                    fpRateMax: nil, minLabeledSample: nil,
                    observedRate: nil, observedSample: 0,
                    promotedBy: opAlias
                )
                settings.mode = .softFlag
                try TrustSettingsStore.save(settings)
                print("trust mode flipped blocking → softFlag")
            }
        }
    }

    struct Override: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "override",
            abstract: "Re-allow a single denied call by id. Writes a chained `override` audit row."
        )

        @Argument(help: "Call id (printed by HookRouter when denying).")
        var callId: String

        @Option(name: .long, help: "Optional free-text justification stored in the chain.")
        var justification: String?

        @Option(name: .customLong("operator"), help: "Operator alias. Default: $USER or 'cli'.")
        var operatorAlias: String?

        func run() throws {
            let opAlias = operatorAlias
                ?? ProcessInfo.processInfo.environment["USER"]
                ?? "cli"
            let rowid = SessionDatabase.shared.recordTrustOverride(
                callId: callId, flagId: nil,
                operator: opAlias, justification: justification
            )
            if rowid < 0 {
                print("Error: failed to write override row.")
                throw ExitCode.failure
            }
            print("override recorded for callId=\(callId) (rowid=\(rowid))")
        }
    }

    struct Threshold: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "threshold",
            abstract: "Configure the two promotion-gate knobs. Both must be set before set-mode blocking will accept."
        )

        @Option(name: .customLong("fp-rate-max"), help: "Maximum acceptable FP-rate (0.0 to 1.0).")
        var fpRateMax: Double?

        @Option(name: .customLong("min-sample"), help: "Minimum labeled-sample count over prior 30 days.")
        var minSample: Int?

        func run() throws {
            var settings = (try? TrustSettingsStore.load()) ?? TrustSettings()
            if let f = fpRateMax {
                guard f >= 0.0 && f <= 1.0 else {
                    print("Error: --fp-rate-max must be in [0.0, 1.0], got \(f).")
                    throw ExitCode.failure
                }
                settings.fpRateMax = f
            }
            if let n = minSample {
                guard n >= 0 else {
                    print("Error: --min-sample must be non-negative, got \(n).")
                    throw ExitCode.failure
                }
                settings.minLabeledSample = n
            }
            try TrustSettingsStore.save(settings)
            print("trust threshold: fp_rate_max=\(settings.fpRateMax.map { String(format: "%.3f", $0) } ?? "<unset>") min_labeled_sample=\(settings.minLabeledSample.map(String.init) ?? "<unset>")")
        }
    }

    func run() throws {
        print(Trust.helpMessage())
    }
}
