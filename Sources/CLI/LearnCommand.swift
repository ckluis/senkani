import ArgumentParser
import Foundation
import Core

// MARK: - Learn (root command)

struct Learn: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "learn",
        abstract: "Manage compound-learning filter rules proposed by post-session analysis.",
        subcommands: [LearnStatus.self, LearnApply.self, LearnReject.self, LearnReset.self],
        defaultSubcommand: LearnStatus.self
    )
}

// MARK: - learn status

struct LearnStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show staged, applied, and rejected learned rules."
    )

    func run() throws {
        let file = LearnedRulesStore.shared
        let staged   = file.rules.filter { $0.status == .staged }
        let applied  = file.rules.filter { $0.status == .applied }
        let rejected = file.rules.filter { $0.status == .rejected }

        let header = "Learned rules: \(staged.count) staged  ·  \(applied.count) applied  ·  \(rejected.count) rejected"
        print(header)

        if staged.isEmpty && applied.isEmpty {
            print("")
            print("No learned rules yet. Run a few sessions — rules are proposed automatically after session close.")
            return
        }

        if !staged.isEmpty {
            print("")
            print("Staged (pending review):")
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withFullDate]
            for rule in staged {
                let sub = rule.subcommand.map { "/\($0)" } ?? ""
                let date = fmt.string(from: rule.createdAt)
                let confPct = Int(rule.confidence * 100)
                let opsStr = rule.ops.joined(separator: ", ")
                print("  [\(rule.id.prefix(6))] \(rule.command)\(sub) — \(opsStr) · confidence: \(confPct)% · \(rule.sessionCount) sessions · staged \(date)")
            }
            print("")
            print("Run 'senkani learn apply' to apply all staged rules.")
        }

        if !applied.isEmpty {
            print("")
            print("Applied:")
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withFullDate]
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
        let file = LearnedRulesStore.shared
        let staged = file.rules.filter { $0.status == .staged }

        if staged.isEmpty {
            print("No staged rules to apply.")
            return
        }

        if let id = ruleId {
            // Find matching rule by ID prefix or full ID
            guard let match = file.rules.first(where: {
                $0.status == .staged && ($0.id == id || $0.id.hasPrefix(id))
            }) else {
                fputs("No staged rule with ID '\(id)'.\n", stderr)
                throw ExitCode(1)
            }
            try LearnedRulesStore.apply(id: match.id)
            let sub = match.subcommand.map { "/\($0)" } ?? ""
            print("Applied: \(match.command)\(sub) — \(match.ops.joined(separator: ", "))")
        } else {
            try LearnedRulesStore.applyAll()
            print("Applied \(staged.count) learned rule(s).")
            print("New sessions will use the updated FilterPipeline.")
        }
    }
}

// MARK: - learn reject

struct LearnReject: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reject",
        abstract: "Reject a staged learned rule by ID."
    )

    @Argument(help: "Rule ID to reject (6-char prefix or full UUID).")
    var ruleId: String

    func run() throws {
        let file = LearnedRulesStore.shared
        guard let match = file.rules.first(where: {
            $0.status == .staged && ($0.id == ruleId || $0.id.hasPrefix(ruleId))
        }) else {
            fputs("No staged rule with ID '\(ruleId)'.\n", stderr)
            throw ExitCode(1)
        }
        try LearnedRulesStore.reject(id: match.id)
        let sub = match.subcommand.map { "/\($0)" } ?? ""
        print("Rejected: \(match.command)\(sub)")
    }
}

// MARK: - learn reset

struct LearnReset: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset",
        abstract: "Delete all learned rules (staged, applied, and rejected)."
    )

    @Flag(name: .long, help: "Skip confirmation prompt.")
    var force = false

    func run() throws {
        guard force else {
            print("This will delete all \(LearnedRulesStore.shared.rules.count) learned rule(s).")
            print("Run with --force to confirm.")
            return
        }
        try LearnedRulesStore.reset()
        print("All learned rules deleted.")
    }
}
