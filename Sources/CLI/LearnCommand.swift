import ArgumentParser
import Foundation
import Core

// MARK: - Learn (root command)

struct Learn: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "learn",
        abstract: "Manage compound-learning filter rules proposed by post-session analysis.",
        subcommands: [LearnStatus.self, LearnApply.self, LearnReject.self, LearnReset.self, LearnSweep.self, LearnEnrich.self, LearnConfig.self, LearnReview.self, LearnAudit.self],
        defaultSubcommand: LearnStatus.self
    )
}

// MARK: - learn status

struct LearnStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show recurring, staged, applied, and rejected learned rules."
    )

    @Flag(name: .long, help: "Show LLM-enriched rationales when available (falls back to deterministic rationale otherwise).")
    var enriched: Bool = false

    @Option(name: .long, help: "Filter by artifact type: filter | context. Omit for all.")
    var type: String?

    func run() throws {
        // Force a fresh disk read — the CLI runs in its own process and
        // the in-memory `shared` cache only makes sense inside the app.
        LearnedRulesStore.reload()
        let file = LearnedRulesStore.shared

        let showFilter = (type == nil || type == "filter")
        let showContext = (type == nil || type == "context")

        let recurring = showFilter ? file.rules.filter { $0.status == .recurring } : []
        let staged    = showFilter ? file.rules.filter { $0.status == .staged } : []
        let applied   = showFilter ? file.rules.filter { $0.status == .applied } : []
        let rejected  = showFilter ? file.rules.filter { $0.status == .rejected } : []

        // H+2b — context doc counts alongside filter rule counts.
        let ctxRecurring = showContext ? file.contextDocs.filter { $0.status == .recurring } : []
        let ctxStaged    = showContext ? file.contextDocs.filter { $0.status == .staged } : []
        let ctxApplied   = showContext ? file.contextDocs.filter { $0.status == .applied } : []
        let ctxRejected  = showContext ? file.contextDocs.filter { $0.status == .rejected } : []

        if showFilter {
            let header = "Learned rules: \(recurring.count) recurring  ·  \(staged.count) staged  ·  \(applied.count) applied  ·  \(rejected.count) rejected"
            print(header)
        }
        if showContext {
            let ctxHeader = "Learned context: \(ctxRecurring.count) recurring  ·  \(ctxStaged.count) staged  ·  \(ctxApplied.count) applied  ·  \(ctxRejected.count) rejected"
            print(ctxHeader)
        }

        if recurring.isEmpty && staged.isEmpty && applied.isEmpty {
            print("")
            print("No learned rules yet. Run a few sessions — rules are proposed automatically after session close.")
            print("Staged rules appear after \(CompoundLearning.dailySweepRecurrenceThreshold) recurrences with confidence ≥ \(Int(CompoundLearning.dailySweepConfidenceThreshold * 100))%.")
            return
        }

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate]

        if !recurring.isEmpty {
            print("")
            print("Recurring (not yet promoted — need \(CompoundLearning.dailySweepRecurrenceThreshold)× recurrence + ≥\(Int(CompoundLearning.dailySweepConfidenceThreshold * 100))% confidence):")
            for rule in recurring.sorted(by: { $0.recurrenceCount > $1.recurrenceCount }) {
                printRule(rule, includeRationale: true, fmt: fmt)
            }
        }

        if !staged.isEmpty {
            print("")
            print("Staged (pending review):")
            for rule in staged {
                printRule(rule, includeRationale: true, fmt: fmt)
            }
            print("")
            print("Run 'senkani learn apply' to apply all staged rules.")
        }

        if !applied.isEmpty {
            print("")
            print("Applied:")
            for rule in applied {
                let sub = rule.subcommand.map { "/\($0)" } ?? ""
                let opsStr = rule.ops.joined(separator: ", ")
                print("  [\(rule.id.prefix(6))] \(rule.command)\(sub) — \(opsStr) · active")
            }
        }

        if !rejected.isEmpty {
            print("")
            print("Rejected: \(rejected.count) rule(s). Run 'senkani learn reset' to clear all.")
        }

        // H+2b — context docs, parallel section layout.
        if !ctxRecurring.isEmpty {
            print("")
            print("Context recurring (need \(CompoundLearning.dailySweepRecurrenceThreshold)× recurrence + ≥\(Int(CompoundLearning.dailySweepConfidenceThreshold * 100))% confidence):")
            for doc in ctxRecurring.sorted(by: { $0.recurrenceCount > $1.recurrenceCount }) {
                printContextDoc(doc, fmt: fmt)
            }
        }
        if !ctxStaged.isEmpty {
            print("")
            print("Context staged (pending review):")
            for doc in ctxStaged {
                printContextDoc(doc, fmt: fmt)
            }
            print("")
            print("Run 'senkani learn apply <context-id>' to write to .senkani/context/<title>.md.")
        }
        if !ctxApplied.isEmpty {
            print("")
            print("Context applied:")
            for doc in ctxApplied {
                print("  [\(doc.id.prefix(6))] \(doc.title) · \(doc.sessionCount) sessions · .senkani/context/\(doc.title).md")
            }
        }
    }

    /// Shared formatter for context doc sections.
    private func printContextDoc(_ doc: LearnedContextDoc, fmt: ISO8601DateFormatter) {
        let confPct = Int((doc.confidence * 100).rounded())
        let date = fmt.string(from: doc.createdAt)
        let recur = doc.recurrenceCount > 1 ? " · ×\(doc.recurrenceCount)" : ""
        print("  [\(doc.id.prefix(6))] \(doc.title)")
        print("         context signal · confidence: \(confPct)% · \(doc.sessionCount) sessions\(recur) · first seen \(date)")
    }

    /// Shared formatter for recurring + staged sections.
    private func printRule(_ rule: LearnedFilterRule, includeRationale: Bool, fmt: ISO8601DateFormatter) {
        let sub = rule.subcommand.map { "/\($0)" } ?? ""
        let opsStr = rule.ops.joined(separator: ", ")
        let confPct = Int((rule.confidence * 100).rounded())
        let date = fmt.string(from: rule.createdAt)
        let signal = rule.signalType.rawValue
        let recur = rule.recurrenceCount > 1 ? " · ×\(rule.recurrenceCount)" : ""
        print("  [\(rule.id.prefix(6))] \(rule.command)\(sub) — \(opsStr)")
        print("         \(signal) signal · confidence: \(confPct)% · \(rule.sessionCount) sessions\(recur) · first seen \(date)")
        if includeRationale {
            // H+2a: prefer LLM enrichment when requested AND available.
            // Falls back to deterministic rationale so the output is
            // never empty just because enrichment hasn't run yet.
            if enriched, let enrichedText = rule.enrichedRationale, !enrichedText.isEmpty {
                print("         ✦ \(enrichedText)")
            } else if !rule.rationale.isEmpty {
                print("         \(rule.rationale)")
            }
        }
    }
}

// MARK: - learn apply

struct LearnApply: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Apply staged learned rules (makes them active in FilterPipeline)."
    )

    @Argument(help: "Rule ID to apply (6-char prefix or full UUID). Omit to apply all staged rules.")
    var ruleId: String?

    func run() throws {
        LearnedRulesStore.reload()
        let file = LearnedRulesStore.shared
        let stagedRules = file.rules.filter { $0.status == .staged }
        let stagedContext = file.contextDocs.filter { $0.status == .staged }

        // H+2b — allow applying a specific context doc by ID. The
        // context-doc path needs a project root to write the markdown
        // file; use cwd when called from CLI.
        if let id = ruleId {
            // Try filter rule first.
            if let match = file.rules.first(where: {
                $0.status == .staged && ($0.id == id || $0.id.hasPrefix(id))
            }) {
                try LearnedRulesStore.apply(id: match.id)
                let sub = match.subcommand.map { "/\($0)" } ?? ""
                print("Applied: \(match.command)\(sub) — \(match.ops.joined(separator: ", "))")
                return
            }
            // Fall through to context doc lookup.
            if let doc = file.contextDocs.first(where: {
                $0.status == .staged && ($0.id == id || $0.id.hasPrefix(id))
            }) {
                let root = FileManager.default.currentDirectoryPath
                try CompoundLearning.applyContextDoc(id: doc.id, projectRoot: root)
                print("Applied context: \(doc.title)")
                print("Wrote .senkani/context/\(doc.title).md — edit to refine priming.")
                return
            }
            fputs("No staged rule or context doc with ID '\(id)'.\n", stderr)
            throw ExitCode(1)
        }

        if stagedRules.isEmpty && stagedContext.isEmpty {
            print("No staged rules or context docs to apply.")
            return
        }

        if !stagedRules.isEmpty {
            try LearnedRulesStore.applyAll()
            print("Applied \(stagedRules.count) learned rule(s).")
            print("New sessions will use the updated FilterPipeline.")
        }
        if !stagedContext.isEmpty {
            let root = FileManager.default.currentDirectoryPath
            var applied = 0
            for doc in stagedContext {
                try CompoundLearning.applyContextDoc(id: doc.id, projectRoot: root)
                applied += 1
            }
            print("Applied \(applied) context doc(s) — wrote to .senkani/context/.")
        }
    }
}

// MARK: - learn reject

struct LearnReject: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reject",
        abstract: "Reject a staged or recurring learned rule by ID."
    )

    @Argument(help: "Rule ID to reject (6-char prefix or full UUID).")
    var ruleId: String

    func run() throws {
        LearnedRulesStore.reload()
        let file = LearnedRulesStore.shared
        // H+1: allow rejecting recurring rules too so operators can
        // suppress noise before the daily sweep promotes them.
        if let match = file.rules.first(where: {
            ($0.status == .staged || $0.status == .recurring) &&
            ($0.id == ruleId || $0.id.hasPrefix(ruleId))
        }) {
            try LearnedRulesStore.reject(id: match.id)
            let sub = match.subcommand.map { "/\($0)" } ?? ""
            print("Rejected: \(match.command)\(sub)")
            return
        }
        // H+2b — also reject context docs by ID.
        if let doc = file.contextDocs.first(where: {
            ($0.status == .staged || $0.status == .recurring || $0.status == .applied) &&
            ($0.id == ruleId || $0.id.hasPrefix(ruleId))
        }) {
            try LearnedRulesStore.rejectContextDoc(id: doc.id)
            // If it was applied, remove the on-disk markdown too.
            if doc.status == .applied {
                let root = FileManager.default.currentDirectoryPath
                ContextFileStore.remove(projectRoot: root, title: doc.title)
            }
            print("Rejected context: \(doc.title)")
            return
        }
        fputs("No staged, recurring, or applied rule/context doc with ID '\(ruleId)'.\n", stderr)
        throw ExitCode(1)
    }
}

// MARK: - learn reset

struct LearnReset: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset",
        abstract: "Delete all learned rules (recurring, staged, applied, and rejected)."
    )

    @Flag(name: .long, help: "Skip confirmation prompt.")
    var force = false

    func run() throws {
        LearnedRulesStore.reload()
        guard force else {
            print("This will delete all \(LearnedRulesStore.shared.rules.count) learned rule(s).")
            print("Run with --force to confirm.")
            return
        }
        try LearnedRulesStore.reset()
        print("All learned rules deleted.")
    }
}

// MARK: - learn sweep (H+1 — manual daily cadence)

struct LearnSweep: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sweep",
        abstract: "Run the daily cadence sweep — promote recurring rules with enough evidence to staged."
    )

    func run() throws {
        let promoted = CompoundLearning.runDailySweep(db: .shared)
        if promoted == 0 {
            print("Daily sweep ran — no recurring rules met the promotion threshold.")
            print("Thresholds: recurrence ≥ \(CompoundLearning.dailySweepRecurrenceThreshold) AND confidence ≥ \(Int(CompoundLearning.dailySweepConfidenceThreshold * 100))%.")
        } else {
            print("Daily sweep promoted \(promoted) rule(s) from recurring → staged.")
            print("Run 'senkani learn status' to review them, then 'senkani learn apply'.")
        }
    }
}

// MARK: - learn enrich
//
// H+2a — report which staged rules still await LLM enrichment. The
// actual Gemma 4 inference runs inside MCP sessions (that's where MLX
// is loaded) — the CLI is lean by design. This subcommand surfaces
// enrichment state so operators can tell whether to wait for the next
// MCP session or consider a manual refresh.

struct LearnEnrich: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enrich",
        abstract: "Report staged rules awaiting LLM-enriched rationale."
    )

    @Flag(name: .long, help: "Show per-rule detail (default shows summary counts).")
    var verbose: Bool = false

    func run() throws {
        LearnedRulesStore.reload()
        let staged = LearnedRulesStore.shared.rules.filter { $0.status == .staged }
        let enriched = staged.filter { ($0.enrichedRationale ?? "").isEmpty == false }
        let pending = staged.filter { ($0.enrichedRationale ?? "").isEmpty }

        print("Enrichment status: \(enriched.count) enriched  ·  \(pending.count) pending")
        print("")
        if staged.isEmpty {
            print("No staged rules — nothing to enrich. Run 'senkani learn sweep' first.")
            return
        }
        print("Enrichment runs automatically during MCP sessions. The Gemma 4 model")
        print("is loaded inside the senkani-mcp binary; the CLI is kept lean. To")
        print("trigger enrichment of a pending rule, open a Senkani pane (which")
        print("starts an MCP session) — the daily sweep enricher hook fires on")
        print("session start and enriches any staged rule whose LLM-rewritten")
        print("rationale is still nil.")

        if verbose {
            print("")
            if !pending.isEmpty {
                print("Pending rules:")
                for rule in pending {
                    let sub = rule.subcommand.map { "/\($0)" } ?? ""
                    print("  [\(rule.id.prefix(6))] \(rule.command)\(sub)")
                }
            }
            if !enriched.isEmpty {
                print("")
                print("Enriched rules:")
                for rule in enriched {
                    let sub = rule.subcommand.map { "/\($0)" } ?? ""
                    print("  [\(rule.id.prefix(6))] \(rule.command)\(sub)")
                    if let text = rule.enrichedRationale { print("         ✦ \(text)") }
                }
            }
        }
    }
}

// MARK: - learn config
//
// H+2a — show or set thresholds in ~/.senkani/compound-learning.json.
// Env vars override file values at read time, so `config show` reads
// the effective values after resolution.

struct LearnConfig: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show or set compound-learning thresholds.",
        subcommands: [LearnConfigShow.self, LearnConfigSet.self],
        defaultSubcommand: LearnConfigShow.self
    )
}

struct LearnConfigShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Print the effective thresholds (env > file > default)."
    )

    func run() throws {
        let effective = CompoundLearningConfig.resolve()
        let file = CompoundLearningConfig.loadFile()
        print("Compound-learning thresholds:")
        print("  min confidence (to land in recurring):   \(format(effective.minConfidence))")
        print("    file override: \(optional(file.minConfidence))")
        print("  daily-sweep recurrence threshold:        \(effective.dailySweepRecurrenceThreshold)")
        print("    file override: \(optional(file.dailySweepRecurrenceThreshold))")
        print("  daily-sweep confidence threshold:        \(format(effective.dailySweepConfidenceThreshold))")
        print("    file override: \(optional(file.dailySweepConfidenceThreshold))")
        print("")
        print("File: \(CompoundLearningConfig.defaultPath)")
        print("Env precedence: SENKANI_COMPOUND_MIN_CONFIDENCE, SENKANI_COMPOUND_DAILY_RECURRENCE, SENKANI_COMPOUND_DAILY_CONFIDENCE.")
    }

    private func format(_ v: Double) -> String { String(format: "%.2f", v) }
    private func optional<T>(_ v: T?) -> String { v.map { String(describing: $0) } ?? "—" }
}

// MARK: - learn review (H+2d)

struct LearnReview: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "review",
        abstract: "Surface staged proposals from the last N days for human-gated triage."
    )

    @Option(name: .long, help: "Window in days to include (default 7).")
    var days: Int = 7

    func run() throws {
        LearnedRulesStore.reload()
        let set = CompoundLearningReview.sprintReviewSet(windowDays: days)
        if set.isEmpty {
            print("No staged proposals in the last \(days) days.")
            print("Staged artifacts surface once the daily sweep promotes them from `.recurring`.")
            return
        }

        print("Sprint review — \(set.totalCount) staged artifact(s) in last \(days) days:")
        print("")
        if !set.filterRules.isEmpty {
            print("Filter rules (\(set.filterRules.count)):")
            for r in set.filterRules {
                let sub = r.subcommand.map { "/\($0)" } ?? ""
                print("  [\(r.id.prefix(6))] \(r.command)\(sub) — \(r.ops.joined(separator: ", "))")
                if !r.rationale.isEmpty { print("         \(r.rationale)") }
            }
            print("")
        }
        if !set.contextDocs.isEmpty {
            print("Context docs (\(set.contextDocs.count)):")
            for d in set.contextDocs {
                print("  [\(d.id.prefix(6))] \(d.title) · \(d.sessionCount) sessions")
            }
            print("")
        }
        if !set.instructionPatches.isEmpty {
            print("Instruction patches (\(set.instructionPatches.count)):")
            for p in set.instructionPatches {
                print("  [\(p.id.prefix(6))] \(p.toolName)")
                print("         \(p.hint.prefix(120))")
            }
            print("")
        }
        if !set.workflowPlaybooks.isEmpty {
            print("Workflow playbooks (\(set.workflowPlaybooks.count)):")
            for w in set.workflowPlaybooks {
                print("  [\(w.id.prefix(6))] \(w.title) — \(w.steps.count) steps")
            }
            print("")
        }
        print("To apply: `senkani learn apply <id>`   ·   To reject: `senkani learn reject <id>`")
    }
}

// MARK: - learn audit (H+2d)

struct LearnAudit: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audit",
        abstract: "Quarterly currency review — flag applied artifacts that look stale."
    )

    @Option(name: .long, help: "Idle-days threshold for flagging (default 60).")
    var idle: Int = 60

    func run() throws {
        LearnedRulesStore.reload()
        let flags = CompoundLearningReview.quarterlyAuditFlags(
            appliedIdleDays: idle
        )
        if flags.isEmpty {
            print("No staleness flags. All applied artifacts are fresh (activity within \(idle) days).")
            return
        }
        print("Quarterly audit — \(flags.count) staleness flag(s) (idle threshold: \(idle)d):")
        print("")
        for f in flags {
            print("  [\(f.artifactId.prefix(6))] \(f.reason.rawValue) · idle \(f.idleDays)d")
            print("         \(f.note)")
        }
        print("")
        print("Review each and reject stale artifacts: `senkani learn reject <id>`")
    }
}

struct LearnConfigSet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set a threshold in the compound-learning config file."
    )

    @Argument(help: "Key: minConfidence | recurrence | dailyConfidence")
    var key: String

    @Argument(help: "Value (float for confidences, int for recurrence).")
    var value: String

    func run() throws {
        var file = CompoundLearningConfig.loadFile()
        switch key {
        case "minConfidence":
            guard let d = Double(value), (0...1).contains(d) else {
                fputs("minConfidence must be a float in [0, 1].\n", stderr)
                throw ExitCode(1)
            }
            file.minConfidence = d
        case "recurrence":
            guard let i = Int(value), i >= 1 else {
                fputs("recurrence must be an integer ≥ 1.\n", stderr)
                throw ExitCode(1)
            }
            file.dailySweepRecurrenceThreshold = i
        case "dailyConfidence":
            guard let d = Double(value), (0...1).contains(d) else {
                fputs("dailyConfidence must be a float in [0, 1].\n", stderr)
                throw ExitCode(1)
            }
            file.dailySweepConfidenceThreshold = d
        default:
            fputs("Unknown key '\(key)'. Valid: minConfidence, recurrence, dailyConfidence.\n", stderr)
            throw ExitCode(1)
        }
        try CompoundLearningConfig.save(file)
        print("Saved to \(CompoundLearningConfig.defaultPath).")
        print("Env vars still take precedence when set.")
    }
}
