import Foundation

/// W.4 — ContextSaturationGate.
///
/// Reads token usage from `agent_trace_event` (V.2 canonical row),
/// divides by a configured context budget, and returns a structured
/// `Decision` the caller can act on:
///
///   * `.ok(percent:)`     — under the warn threshold; nothing to do.
///   * `.warn(percent:)`   — past `warnAt` but below `blockAt`; the UI
///                            should surface a saturation chip and the
///                            caller should consider writing a handoff
///                            card preemptively.
///   * `.block(percent:reason:)` — past `blockAt`; the caller MUST stop
///                            and write a handoff card before any new
///                            tool calls run, otherwise the next compact
///                            will lose state.
///
/// Pure decision function. The DB-derived convenience overload is a
/// thin wrapper around `agentTraceTokenUsage(...)`. No I/O happens
/// inside `evaluate(currentTokens:threshold:)` itself, so it is cheap
/// to call from the hook path.
public enum ContextSaturationGate {

    public enum Decision: Equatable, Sendable {
        case ok(percent: Double)
        case warn(percent: Double)
        case block(percent: Double, reason: String)

        public var percent: Double {
            switch self {
            case .ok(let p), .warn(let p): return p
            case .block(let p, _): return p
            }
        }

        public var isBlocking: Bool {
            if case .block = self { return true }
            return false
        }
    }

    /// Threshold knobs for the gate.
    ///
    /// Defaults follow the Continuous Claude v4.7 pattern referenced by
    /// `spec/inspirations/skills-ecosystem/continuous-claude-v4-7.md`:
    /// warn at 65 %, block at 80 %, against a 200 000-token budget
    /// (Claude Sonnet 4.6 / Opus 4.7 1M-context profiles still ride this
    /// gate at the active-window slice — the budget is the *active*
    /// window the agent has, not the model's hard ceiling).
    public struct Threshold: Equatable, Sendable {
        public let warnAt: Double
        public let blockAt: Double
        public let budgetTokens: Int

        public init(warnAt: Double, blockAt: Double, budgetTokens: Int) {
            self.warnAt = warnAt
            self.blockAt = blockAt
            self.budgetTokens = budgetTokens
        }

        public static let `default` = Threshold(
            warnAt: 0.65,
            blockAt: 0.80,
            budgetTokens: 200_000
        )
    }

    /// Pure decision: percent = currentTokens / budget.
    /// Negative budgets fall back to `.ok(0)` — caller misconfiguration
    /// shouldn't escalate to a block.
    public static func evaluate(
        currentTokens: Int,
        threshold: Threshold = .default
    ) -> Decision {
        guard threshold.budgetTokens > 0 else { return .ok(percent: 0) }
        let percent = Double(max(0, currentTokens)) / Double(threshold.budgetTokens)
        if percent >= threshold.blockAt {
            let pct = Int((percent * 100).rounded())
            let reason = "context saturation \(pct)% ≥ \(Int(threshold.blockAt * 100))% — write a handoff card before continuing"
            return .block(percent: percent, reason: reason)
        }
        if percent >= threshold.warnAt {
            return .warn(percent: percent)
        }
        return .ok(percent: percent)
    }

    /// Convenience: derive `currentTokens` from `agent_trace_event` for
    /// a pane / project / time window, then evaluate. The window
    /// defaults to the whole table — typical callers will pin a
    /// `pane:` (the Claude Code surface whose context they're guarding)
    /// and a `since:` of session-start.
    public static func evaluate(
        database: SessionDatabase,
        pane: String? = nil,
        project: String? = nil,
        since: Date? = nil,
        threshold: Threshold = .default
    ) -> Decision {
        let usage = database.agentTraceTokenUsage(pane: pane, project: project, since: since)
        return evaluate(currentTokens: usage.totalTokens, threshold: threshold)
    }
}
