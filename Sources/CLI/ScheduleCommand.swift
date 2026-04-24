import ArgumentParser
import Foundation
import Core

struct Schedule: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schedule",
        abstract: "Manage scheduled tasks powered by macOS launchd.",
        subcommands: [Create.self, ListTasks.self, Remove.self, Run.self, Preset.self]
    )
}

// MARK: - Create

extension Schedule {
    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a new scheduled task."
        )

        @Option(name: .long, help: "Task identifier (alphanumeric, dashes, underscores).")
        var name: String

        @Option(name: .long, help: "Cron expression, e.g. \"0 */6 * * *\" for every 6 hours.")
        var cron: String

        @Option(name: .long, help: "Shell command to run on schedule.")
        var command: String

        @Option(name: .long, help: "Budget limit in cents for this task (optional).")
        var budget: Int?

        @Flag(name: .long, help: "Run each fire inside a fresh git worktree (requires current dir to be a git repo when run).")
        var worktree: Bool = false

        func validate() throws {
            // Validate name: alphanumeric, dashes, underscores only
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                throw ValidationError("Name must contain only alphanumeric characters, dashes, and underscores.")
            }
            guard !name.isEmpty else {
                throw ValidationError("Name cannot be empty.")
            }

            // Validate cron expression
            guard CronToLaunchd.convert(cron) != nil else {
                throw ValidationError("Invalid cron expression: \"\(cron)\". Expected 5 fields: minute hour day-of-month month day-of-week.")
            }

            // Validate budget
            if let b = budget, b < 0 {
                throw ValidationError("Budget must be non-negative.")
            }
        }

        func run() throws {
            let task = ScheduledTask(
                name: name,
                cronPattern: cron,
                command: command,
                budgetLimitCents: budget,
                worktree: worktree
            )

            do {
                _ = try PresetInstaller.install(task: task)
                print("Saved schedule config: ~/.senkani/schedules/\(name).json")
                print("Loaded launchd plist: com.senkani.schedule.\(name)")
                print("Schedule: \(CronToLaunchd.humanReadable(cron))")
            } catch PresetInstaller.InstallError.invalidCronPattern(let c) {
                throw ValidationError("Failed to convert cron expression to launchd intervals: \"\(c)\".")
            } catch PresetInstaller.InstallError.writeFailed(let msg) {
                throw ValidationError(msg)
            }
        }
    }
}

// MARK: - List

extension Schedule {
    struct ListTasks: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List all scheduled tasks."
        )

        func run() throws {
            let tasks = ScheduleStore.list()

            if tasks.isEmpty {
                print("No scheduled tasks. Use `senkani schedule create` to add one.")
                return
            }

            // Print table header
            let nameW = 20
            let cronW = 20
            let cmdW = 30
            let enabledW = 8
            let lastRunW = 20
            let resultW = 16

            let header = [
                "NAME".padding(toLength: nameW, withPad: " ", startingAt: 0),
                "SCHEDULE".padding(toLength: cronW, withPad: " ", startingAt: 0),
                "COMMAND".padding(toLength: cmdW, withPad: " ", startingAt: 0),
                "ENABLED".padding(toLength: enabledW, withPad: " ", startingAt: 0),
                "LAST RUN".padding(toLength: lastRunW, withPad: " ", startingAt: 0),
                "RESULT".padding(toLength: resultW, withPad: " ", startingAt: 0),
            ].joined(separator: "  ")
            print(header)
            print(String(repeating: "-", count: header.count))

            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .short
            dateFormatter.timeStyle = .short

            for task in tasks {
                let humanCron = CronToLaunchd.humanReadable(task.cronPattern)
                let truncCmd = task.command.count > cmdW
                    ? String(task.command.prefix(cmdW - 3)) + "..."
                    : task.command
                let lastRun = task.lastRunAt.map { dateFormatter.string(from: $0) } ?? "never"
                let result = task.lastRunResult ?? "-"

                let row = [
                    task.name.padding(toLength: nameW, withPad: " ", startingAt: 0),
                    humanCron.padding(toLength: cronW, withPad: " ", startingAt: 0),
                    truncCmd.padding(toLength: cmdW, withPad: " ", startingAt: 0),
                    (task.enabled ? "yes" : "no").padding(toLength: enabledW, withPad: " ", startingAt: 0),
                    lastRun.padding(toLength: lastRunW, withPad: " ", startingAt: 0),
                    result.padding(toLength: resultW, withPad: " ", startingAt: 0),
                ].joined(separator: "  ")
                print(row)
            }
        }
    }
}

// MARK: - Remove

extension Schedule {
    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove a scheduled task."
        )

        @Option(name: .long, help: "Name of the task to remove.")
        var name: String

        func run() throws {
            guard ScheduleStore.load(name) != nil else {
                throw ValidationError("No scheduled task found with name: \(name)")
            }

            try ScheduleStore.remove(name)
            print("Removed schedule: \(name)")
        }
    }
}

// MARK: - Run (internal, called by launchd)

extension Schedule {
    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Execute a scheduled task (called by launchd)."
        )

        @Option(name: .long, help: "Name of the task to run.")
        var name: String

        func run() throws {
            guard var task = ScheduleStore.load(name) else {
                throw ValidationError("No scheduled task found with name: \(name)")
            }

            guard task.enabled else {
                print("Task '\(name)' is disabled, skipping.")
                return
            }

            let projectRoot = FileManager.default.currentDirectoryPath
            let runId = ScheduleTelemetry.makeRunId()

            // Check budget if configured
            if let budgetLimit = task.budgetLimitCents {
                let budget = BudgetConfig.load()
                let decision = budget.check(sessionCents: 0, todayCents: budgetLimit, weekCents: 0)
                if case .block(let reason) = decision {
                    task.lastRunAt = Date()
                    task.lastRunResult = "budget_exceeded"
                    try? ScheduleStore.save(task)
                    ScheduleTelemetry.recordBlocked(
                        projectRoot: projectRoot,
                        taskName: task.name,
                        runId: runId,
                        reason: reason
                    )
                    FileHandle.standardError.write(
                        Data("Budget exceeded for task '\(name)': \(reason)\n".utf8)
                    )
                    throw ExitCode(1)
                }
            }

            // Optionally spawn in a fresh git worktree. Must happen after
            // the budget gate so a blocked run doesn't leave disk litter.
            var worktreeHandle: ScheduleWorktree.Handle?
            if task.worktree {
                do {
                    worktreeHandle = try ScheduleWorktree.create(
                        projectRoot: projectRoot, scheduleName: task.name
                    )
                } catch {
                    task.lastRunAt = Date()
                    task.lastRunResult = "failed: \(error.localizedDescription)"
                    try? ScheduleStore.save(task)
                    FileHandle.standardError.write(
                        Data("Worktree create failed for '\(name)': \(error.localizedDescription)\n".utf8)
                    )
                    throw ExitCode(1)
                }
            }

            ScheduleTelemetry.recordStart(
                projectRoot: projectRoot,
                taskName: task.name,
                command: task.command,
                runId: runId
            )

            // Run the command
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", task.command]
            process.environment = ProcessInfo.processInfo.environment
            if let handle = worktreeHandle {
                process.currentDirectoryURL = URL(fileURLWithPath: handle.path)
            }

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            var exitCode: Int32 = -1
            do {
                try process.run()
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                // Forward output
                FileHandle.standardOutput.write(outData)
                FileHandle.standardError.write(errData)

                exitCode = process.terminationStatus
                task.lastRunAt = Date()
                if exitCode == 0 {
                    task.lastRunResult = "success"
                } else {
                    task.lastRunResult = "failed: exit \(exitCode)"
                }
            } catch {
                task.lastRunAt = Date()
                task.lastRunResult = "failed: \(error.localizedDescription)"
            }

            ScheduleTelemetry.recordEnd(
                projectRoot: projectRoot,
                taskName: task.name,
                runId: runId,
                exitCode: exitCode
            )

            // Cleanup worktree on success; retain on failure for inspection.
            if let handle = worktreeHandle {
                if task.lastRunResult == "success" {
                    try? ScheduleWorktree.cleanup(handle)
                } else {
                    FileHandle.standardError.write(
                        Data("Worktree retained for inspection: \(handle.path)\n".utf8)
                    )
                }
            }

            try? ScheduleStore.save(task)

            if let result = task.lastRunResult, result != "success" {
                throw ExitCode(1)
            }
        }
    }
}

// MARK: - Preset

extension Schedule {
    struct Preset: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "preset",
            abstract: "Install one of the shipped schedule presets (log-rotation, morning-brief, autoresearch, competitive-scan, senkani-improve).",
            subcommands: [ListPresets.self, Show.self, Install.self]
        )
    }
}

extension Schedule.Preset {
    struct ListPresets: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List shipped + user scheduled presets."
        )

        func run() throws {
            let presets = PresetCatalog.all()
            if presets.isEmpty {
                print("No presets available.")
                return
            }

            let nameW = 22
            let engineW = 10
            let descW = 60
            let readyW = 12

            let header = [
                "NAME".padding(toLength: nameW, withPad: " ", startingAt: 0),
                "ENGINE".padding(toLength: engineW, withPad: " ", startingAt: 0),
                "READY".padding(toLength: readyW, withPad: " ", startingAt: 0),
                "DESCRIPTION".padding(toLength: descW, withPad: " ", startingAt: 0)
            ].joined(separator: "  ")
            print(header)
            print(String(repeating: "-", count: header.count))

            for preset in presets {
                let ready = PresetPrerequisiteCheck.check(preset)
                let readyCol = ready.fullyReady ? "yes" : "\(ready.warnings.count) warn"
                let descText = preset.description.count > descW
                    ? String(preset.description.prefix(descW - 3)) + "..."
                    : preset.description
                let marker = PresetCatalog.isShipped(preset.name) ? "" : " (user)"
                let nameCol = (preset.name + marker).padding(toLength: nameW, withPad: " ", startingAt: 0)
                let row = [
                    nameCol,
                    preset.engine.rawValue.padding(toLength: engineW, withPad: " ", startingAt: 0),
                    readyCol.padding(toLength: readyW, withPad: " ", startingAt: 0),
                    descText.padding(toLength: descW, withPad: " ", startingAt: 0)
                ].joined(separator: "  ")
                print(row)
            }
        }
    }
}

extension Schedule.Preset {
    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Print the raw JSON record for a preset (no placeholder substitution)."
        )

        @Argument(help: "Name of the preset to show.")
        var name: String

        func run() throws {
            guard let preset = PresetCatalog.find(name) else {
                throw ValidationError("No preset named `\(name)`. Try `senkani schedule preset list`.")
            }
            let data = try PresetCatalog.encode(preset)
            if let s = String(data: data, encoding: .utf8) {
                print(s)
            }
        }
    }
}

extension Schedule.Preset {
    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Install a preset as a running ScheduledTask (with placeholder + budget + cron overrides)."
        )

        @Argument(help: "Name of the preset to install.")
        var name: String

        @Option(name: .long, help: "Topic for autoresearch-style presets (substitutes `<topic>`).")
        var topic: String?

        @Option(name: .long, help: "Competitor for competitive-scan-style presets (substitutes `<competitor>`).")
        var competitor: String?

        @Option(name: .long, help: "Override the preset's budget cap in cents.")
        var budget: Int?

        @Option(name: .long, help: "Override the preset's cron pattern.")
        var cron: String?

        func run() throws {
            guard let preset = PresetCatalog.find(name) else {
                throw ValidationError("No preset named `\(name)`. Try `senkani schedule preset list`.")
            }

            var overrides: [String: String] = [:]
            if let topic { overrides["topic"] = topic }
            if let competitor { overrides["competitor"] = competitor }

            let task = preset.toScheduledTask(
                overrides: overrides,
                budgetOverride: budget,
                cronOverride: cron
            )

            // Security gate — secret-scan the resolved command.
            switch PresetSecretDetector.scan(resolvedCommand: task.command) {
            case .clear:
                break
            case .block(let patterns):
                throw ValidationError(PresetSecretDetector.blockMessage(preset: name, patterns: patterns))
            }

            // Install via the shared plist generator.
            do {
                _ = try PresetInstaller.install(task: task)
            } catch PresetInstaller.InstallError.invalidCronPattern(let c) {
                throw ValidationError("Preset `\(name)` has an invalid cron pattern: \"\(c)\".")
            } catch PresetInstaller.InstallError.writeFailed(let msg) {
                throw ValidationError("Preset `\(name)` install failed: \(msg)")
            }

            print("Installed preset `\(name)` as schedule `\(task.name)` (cron: \(CronToLaunchd.humanReadable(task.cronPattern))).")

            // Prerequisite warnings — non-blocking.
            let result = PresetPrerequisiteCheck.check(preset)
            if let summary = PresetPrerequisiteCheck.summaryMessage(result) {
                print("")
                print(summary)
                for w in result.warnings {
                    print("  - \(w.message)")
                }
            }
        }
    }
}
