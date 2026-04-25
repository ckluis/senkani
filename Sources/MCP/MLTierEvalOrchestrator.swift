import Foundation
import Bench
import Core
import MLXLMCommon
import MLXVLM

// MARK: - Plan

/// One scheduling decision for a tier in `senkani ml-eval`. Pure data —
/// constructed by `MLTierEvalOrchestrator.plan(...)` so the eligibility
/// rules stay testable without MLX.
public enum MLTierEvalPlan: Sendable, Equatable {
    case evaluate(modelId: String, modelName: String, repoId: String)
    case skip(modelId: String, modelName: String, reason: String)
}

// MARK: - Orchestrator

/// Drives `senkani ml-eval`. Iterates each Gemma 4 tier in
/// `ModelManager.visionModelIds`, loads it, runs the 20-task harness from
/// `Bench.MLTierEvalTasks.all()`, and writes a `MLTierEvalReport` to
/// `~/.senkani/ml-tier-eval.json`. Tiers above this machine's RAM, or not
/// installed, are recorded as `MLTierEvalRunner.notEvaluated(...)` rather
/// than skipped silently — so `senkani doctor` still surfaces them.
public enum MLTierEvalOrchestrator {

    // MARK: - Plan (pure)

    /// Return a per-tier plan: which tiers to evaluate vs. skip and why.
    /// Pure function — no MLX, no IO. The runtime path uses live
    /// `ModelManager.shared` lookups; tests inject `infoFor` directly.
    public static func plan(
        tierIds: [String],
        availableRAMGB: Int,
        infoFor: (String) -> ModelInfo?
    ) -> [MLTierEvalPlan] {
        return tierIds.map { id in
            guard let info = infoFor(id) else {
                return .skip(modelId: id, modelName: id,
                             reason: "tier not in registry")
            }
            if info.requiredRAM > availableRAMGB {
                return .skip(
                    modelId: id, modelName: info.name,
                    reason: "insufficient RAM "
                        + "(\(availableRAMGB) GB; tier requires \(info.requiredRAM) GB)"
                )
            }
            // Allowlist installed states explicitly so a future ModelStatus
            // case doesn't silently flip evaluation eligibility.
            let installed = info.status == .verified || info.status == .downloaded
            if !installed {
                return .skip(
                    modelId: id, modelName: info.name,
                    reason: "tier not installed (status: \(info.status.rawValue)) "
                        + "— download it from the Models pane and retry"
                )
            }
            return .evaluate(modelId: id, modelName: info.name, repoId: info.repoId)
        }
    }

    // MARK: - Run (production)

    /// Run the eval against every Gemma 4 tier this machine can host,
    /// write the report, and return it. Streams progress to `output`.
    @discardableResult
    public static func run(
        reportURL: URL = MLTierEvalReportStore.defaultURL,
        output: any TextOutputStream & Sendable = StandardErrorStream(),
        clock: @Sendable () -> Date = { Date() }
    ) async throws -> MLTierEvalReport {
        let plans = plan(
            tierIds: ModelManager.visionModelIds,
            availableRAMGB: ModelManager.availableRAMGB,
            infoFor: { ModelManager.shared.model($0) }
        )
        let tasks = Bench.MLTierEvalTasks.all()
        var sink = output
        var results: [MLTierEvalResult] = []

        for p in plans {
            switch p {
            case .skip(let id, let name, let reason):
                Self.write("[ml-eval] skip \(id) — \(reason)\n", to: &sink)
                results.append(MLTierEvalRunner.notEvaluated(
                    tier: (id: id, name: name),
                    reason: reason,
                    clock: clock
                ))

            case .evaluate(let id, let name, let repoId):
                Self.write("[ml-eval] load \(id) (\(repoId))\n", to: &sink)
                let adapter = MLTierInferenceAdapter()
                do {
                    try await adapter.load(repoId: repoId)
                } catch {
                    let reason = "load failed: \(error.localizedDescription)"
                    Self.write("[ml-eval]   ✗ \(reason)\n", to: &sink)
                    results.append(MLTierEvalRunner.notEvaluated(
                        tier: (id: id, name: name), reason: reason, clock: clock
                    ))
                    continue
                }

                let result = await MLTierEvalRunner.evaluate(
                    tier: (id: id, name: name),
                    tasks: tasks,
                    clock: clock
                ) { task in
                    try await adapter.run(task: task)
                }
                Self.write(
                    "[ml-eval]   \(id): \(result.passed)/\(result.total) "
                        + "(\(Int((result.passRate * 100).rounded()))% pass, "
                        + "\(result.rating.rawValue))\n",
                    to: &sink
                )
                results.append(result)
                await adapter.unload()
            }
        }

        let report = MLTierEvalReport(
            generatedAt: clock(),
            machineRamGB: ModelManager.availableRAMGB,
            tiers: results
        )
        try MLTierEvalReportStore.save(report, to: reportURL)
        Self.write("[ml-eval] wrote \(reportURL.path)\n", to: &sink)
        return report
    }

    private static func write(_ s: String, to sink: inout (any TextOutputStream & Sendable)) {
        sink.write(s)
    }
}

// MARK: - StandardErrorStream

/// `TextOutputStream` adapter that writes to stderr. Used as the default
/// orchestrator sink so `senkani-mcp eval`'s progress output doesn't
/// pollute any stdout-captured report.
public struct StandardErrorStream: TextOutputStream, Sendable {
    public init() {}
    public func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}
