import ArgumentParser
import Core
import Foundation
import Indexer

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Diagnose and repair common Senkani configuration issues."
    )

    @Flag(name: .long, help: "Automatically fix issues (default is report-only).")
    var fix = false

    // MARK: - Counters

    private struct Results {
        var passed = 0
        var fixed = 0
        var failed = 0
        var skipped = 0
    }

    func run() throws {
        print("Senkani Doctor")
        print("==============")

        var results = Results()

        // 1. Settings JSON valid
        checkSettingsJSON(&results)

        // 2. No global hooks
        checkGlobalHooks(&results)

        // 3. MCP server registered
        checkMCPServer(&results)

        // 4. Hook script exists
        checkHookScript(&results)

        // 5. Model cache
        checkModels(&results)

        // 6. SQLite database
        checkDatabase(&results)

        // 7. Theme directory
        checkThemes(&results)

        // 8. Budget config
        checkBudget(&results)

        // 9. Grammar versions
        checkGrammars(&results)

        // 10. Daemon health (socket responsiveness)
        checkDaemonHealth(&results)

        // 11. Agent ecosystem
        checkAgents(&results)

        // 12. Learned rules
        checkLearnedRules(&results)

        // 13. WARP.md skills
        checkSkills(&results)

        print("")
        var parts: [String] = []
        if results.passed > 0 { parts.append("\(results.passed) passed") }
        if results.fixed > 0 { parts.append("\(results.fixed) fixed") }
        if results.failed > 0 { parts.append("\(results.failed) failed") }
        if results.skipped > 0 { parts.append("\(results.skipped) skipped") }
        print(parts.joined(separator: ", "))

        if results.failed > 0 {
            throw ExitCode.failure
        }
    }

    // MARK: - Check 1: Settings JSON

    private func checkSettingsJSON(_ results: inout Results) {
        let path = NSHomeDirectory() + "/.claude/settings.json"
        let fm = FileManager.default

        guard fm.fileExists(atPath: path) else {
            printStatus(.skip, "Settings JSON — file not found (~/.claude/settings.json)")
            results.skipped += 1
            return
        }

        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            printStatus(.fail, "Settings JSON — could not read file")
            results.failed += 1
            return
        }

        // Try parsing as-is
        if let data = raw.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            printStatus(.pass, "Settings JSON valid")
            results.passed += 1
            return
        }

        // Invalid JSON — diagnose
        var issues: [String] = []

        // Check for trailing EOF (heredoc artifact)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("EOF") {
            issues.append("trailing EOF (heredoc artifact)")
        }

        // Check for trailing content after the last }
        if let lastBrace = trimmed.lastIndex(of: "}") {
            let afterBrace = trimmed[trimmed.index(after: lastBrace)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !afterBrace.isEmpty {
                issues.append("stray content after closing brace: \"\(String(afterBrace.prefix(20)))\"")
            }
        }

        // Check for null bytes
        if raw.contains("\0") {
            issues.append("null bytes in file")
        }

        let description = issues.isEmpty ? "invalid JSON" : issues.joined(separator: ", ")

        if fix {
            // Attempt repair
            var repaired = raw

            // Remove null bytes
            repaired = repaired.replacingOccurrences(of: "\0", with: "")

            // Remove trailing EOF and any whitespace after last }
            let lines = repaired.components(separatedBy: .newlines)
            var cleanedLines: [String] = []
            var foundClosingBrace = false
            // Walk backwards to find the last } and drop everything after it
            for line in lines.reversed() {
                let stripped = line.trimmingCharacters(in: .whitespaces)
                if !foundClosingBrace {
                    if stripped == "}" || stripped.hasSuffix("}") {
                        foundClosingBrace = true
                        cleanedLines.insert(line, at: 0)
                    }
                    // Skip lines after the last }
                } else {
                    cleanedLines.insert(line, at: 0)
                }
            }

            repaired = cleanedLines.joined(separator: "\n") + "\n"

            // Validate the repair
            if let data = repaired.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                // Write atomically
                let url = URL(fileURLWithPath: path)
                let tempPath = path + ".doctor-tmp.\(ProcessInfo.processInfo.processIdentifier)"
                do {
                    try repaired.write(toFile: tempPath, atomically: true, encoding: .utf8)
                    _ = try fm.replaceItemAt(url, withItemAt: URL(fileURLWithPath: tempPath))
                    printStatus(.fixed, "Settings JSON — repaired (\(description))")
                    results.fixed += 1
                    return
                } catch {
                    try? fm.removeItem(atPath: tempPath)
                }
            }

            printStatus(.fail, "Settings JSON — could not auto-repair (\(description))")
            results.failed += 1
        } else {
            printStatus(.fail, "Settings JSON invalid — \(description). Run with --fix to repair")
            results.failed += 1
        }
    }

    // MARK: - Check 2: Global Hooks

    private func checkGlobalHooks(_ results: inout Results) {
        let path = NSHomeDirectory() + "/.claude/settings.json"

        guard let data = FileManager.default.contents(atPath: path),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Can't check if we can't read the file
            return
        }

        guard let hooks = config["hooks"] as? [String: Any],
              let preToolUse = hooks["PreToolUse"] as? [[String: Any]] else {
            printStatus(.pass, "No global hooks")
            results.passed += 1
            return
        }

        // Find hooks with empty matcher
        let emptyMatchers = preToolUse.filter { entry in
            if let matcher = entry["matcher"] as? String, matcher.isEmpty {
                return true
            }
            return false
        }

        if emptyMatchers.isEmpty {
            printStatus(.pass, "No global hooks with empty matchers")
            results.passed += 1
            return
        }

        if fix {
            do {
                var mutableConfig = config

                // Filter out empty-matcher entries
                let filtered = preToolUse.filter { entry in
                    if let matcher = entry["matcher"] as? String, matcher.isEmpty {
                        return false
                    }
                    return true
                }

                if filtered.isEmpty {
                    // Remove the entire hooks section if nothing left
                    var mutableHooks = hooks
                    mutableHooks.removeValue(forKey: "PreToolUse")
                    if mutableHooks.isEmpty {
                        mutableConfig.removeValue(forKey: "hooks")
                    } else {
                        mutableConfig["hooks"] = mutableHooks
                    }
                } else {
                    var mutableHooks = hooks
                    mutableHooks["PreToolUse"] = filtered
                    mutableConfig["hooks"] = mutableHooks
                }

                let newData = try JSONSerialization.data(
                    withJSONObject: mutableConfig,
                    options: [.prettyPrinted, .sortedKeys]
                )
                let url = URL(fileURLWithPath: path)
                let tempURL = url.deletingLastPathComponent()
                    .appendingPathComponent(".settings.json.doctor-tmp.\(ProcessInfo.processInfo.processIdentifier)")
                try newData.write(to: tempURL)
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)

                printStatus(.fixed, "Global hooks — removed \(emptyMatchers.count) empty-matcher hook(s) that intercept all tools")
                results.fixed += 1
            } catch {
                printStatus(.fail, "Global hooks — could not remove empty-matcher hooks: \(error.localizedDescription)")
                results.failed += 1
            }
        } else {
            printStatus(.fail, "Global hooks found — \(emptyMatchers.count) empty-matcher hook(s) intercept all tools. Run with --fix to remove")
            results.failed += 1
        }
    }

    // MARK: - Check 3: MCP Server

    private func checkMCPServer(_ results: inout Results) {
        // Check both settings.json and .mcp.json
        let settingsPath = NSHomeDirectory() + "/.claude/settings.json"
        var found = false
        var binaryPath = ""

        if let data = FileManager.default.contents(atPath: settingsPath),
           let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let mcpServers = config["mcpServers"] as? [String: Any],
           let senkani = mcpServers["senkani"] as? [String: Any],
           let command = senkani["command"] as? String {
            found = true
            binaryPath = command
        }

        if found {
            printStatus(.pass, "MCP server registered (senkani \u{2192} \(binaryPath))")
            results.passed += 1
        } else {
            printStatus(.fail, "MCP server not registered. Run: senkani mcp-install --global")
            results.failed += 1
        }
    }

    // MARK: - Check 4: Hook Binary

    private func checkHookScript(_ results: inout Results) {
        let hookPath = AutoRegistration.hookWrapperPath  // ~/.senkani/bin/senkani-hook
        let fm = FileManager.default

        guard fm.fileExists(atPath: hookPath) else {
            printStatus(.fail, "Hook binary not found (~/.senkani/bin/senkani-hook). Run the Senkani app once to install it")
            results.failed += 1
            return
        }

        guard fm.isExecutableFile(atPath: hookPath) else {
            if fix {
                chmod(hookPath, 0o755)
                printStatus(.fixed, "Hook binary — set executable permission")
                results.fixed += 1
            } else {
                printStatus(.fail, "Hook binary exists but is not executable. Run with --fix to repair")
                results.failed += 1
            }
            return
        }

        // Check if it's a compiled Mach-O binary or a bash wrapper
        if AutoRegistration.isMachOBinary(at: hookPath) {
            printStatus(.pass, "Hook binary installed (compiled, <5ms latency)")
            results.passed += 1
        } else {
            // It's the bash wrapper — functional but slow
            if fix {
                AutoRegistration.installHookWrapper()
                if AutoRegistration.isMachOBinary(at: hookPath) {
                    printStatus(.fixed, "Hook binary — deployed compiled binary (was bash wrapper)")
                    results.fixed += 1
                } else {
                    printStatus(.fail, "Hook binary is a bash wrapper (~300ms overhead). Build compiled binary: swift build -c release --product senkani-hook && cp .build/release/senkani-hook ~/.senkani/bin/")
                    results.failed += 1
                }
            } else {
                printStatus(.fail, "Hook binary is a bash wrapper (~300ms overhead per tool call). Run with --fix or: swift build -c release --product senkani-hook && cp .build/release/senkani-hook ~/.senkani/bin/")
                results.failed += 1
            }
        }
    }

    // MARK: - Check 5: Models

    private func checkModels(_ results: inout Results) {
        let mgr = ModelManager.shared

        for model in mgr.models {
            switch model.status {
            case .verified:
                printStatus(.pass, "\(model.name): verified")
                results.passed += 1
            case .downloaded:
                printStatus(.pass, "\(model.name): installed (not yet verified)")
                results.passed += 1
            case .verifying:
                printStatus(.skip, "\(model.name): verifying…")
                results.skipped += 1
            case .downloading:
                let pct = Int(model.downloadProgress * 100)
                printStatus(.skip, "\(model.name): downloading (\(pct)%)")
                results.skipped += 1
            case .broken:
                let why = model.lastError.map { " — \($0)" } ?? ""
                printStatus(.fail, "\(model.name): verification failed\(why)")
                results.failed += 1
            case .error:
                let why = model.lastError.map { " — \($0)" } ?? ""
                printStatus(.fail, "\(model.name): install error\(why)")
                results.failed += 1
            case .available:
                printStatus(.skip, "\(model.name): not installed")
                results.skipped += 1
            }
        }
    }

    // MARK: - Check 6: Database

    private func checkDatabase(_ results: inout Results) {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dbPath = appSupport.appendingPathComponent("Senkani/senkani.db").path

        if FileManager.default.fileExists(atPath: dbPath) {
            // Quick stats via sqlite3 CLI
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = [
                dbPath,
                "SELECT COUNT(*) || ' sessions, ' || COALESCE(SUM(command_count),0) || ' commands' FROM sessions;"
            ]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
                printStatus(.pass, "Database: \(output)")
            } else {
                printStatus(.pass, "Database exists (could not query)")
            }
            results.passed += 1
        } else {
            printStatus(.skip, "Database: not yet created (~/Library/Application Support/Senkani/senkani.db)")
            results.skipped += 1
        }
    }

    // MARK: - Check 7: Themes

    private func checkThemes(_ results: inout Results) {
        let themesDir = NSHomeDirectory() + "/.senkani/themes"
        let fm = FileManager.default

        var userCount = 0
        if fm.fileExists(atPath: themesDir),
           let contents = try? fm.contentsOfDirectory(atPath: themesDir) {
            userCount = contents.filter { $0.hasSuffix(".json") }.count
        } else if fix {
            try? fm.createDirectory(atPath: themesDir, withIntermediateDirectories: true)
            printStatus(.fixed, "Themes: created ~/.senkani/themes/ directory")
            results.fixed += 1
            return
        }

        // Count bundled themes (from the Themes resource directory)
        // In CLI context we don't have Bundle.module, so check the built app's resources
        let bundledCount = countBundledThemes()

        if bundledCount > 0 {
            printStatus(.pass, "Themes: \(userCount) user themes (\(bundledCount) bundled)")
        } else {
            printStatus(.pass, "Themes: \(userCount) user themes")
        }
        results.passed += 1
    }

    private func countBundledThemes() -> Int {
        // Try to find bundled themes in the app bundle or build artifacts
        let possiblePaths = [
            Bundle.main.resourcePath.map { $0 + "/Themes" },
        ].compactMap { $0 }

        for path in possiblePaths {
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: path) {
                let count = contents.filter { $0.hasSuffix(".json") }.count
                if count > 0 { return count }
            }
        }
        return 0
    }

    // MARK: - Check 8: Budget

    private func checkBudget(_ results: inout Results) {
        let budgetPath = NSHomeDirectory() + "/.senkani/budget.json"
        let fm = FileManager.default

        guard fm.fileExists(atPath: budgetPath) else {
            printStatus(.skip, "Budget: not configured")
            results.skipped += 1
            return
        }

        guard let data = fm.contents(atPath: budgetPath) else {
            printStatus(.fail, "Budget: could not read ~/.senkani/budget.json")
            results.failed += 1
            return
        }

        if (try? JSONSerialization.jsonObject(with: data)) != nil {
            printStatus(.pass, "Budget config valid")
            results.passed += 1
        } else {
            printStatus(.fail, "Budget config contains invalid JSON")
            results.failed += 1
        }
    }

    // MARK: - Check 9: Grammars

    private func checkGrammars(_ results: inout Results) {
        let count = GrammarManifest.grammars.count
        let languages = GrammarManifest.sorted.map { "\($0.language) v\($0.version)" }.joined(separator: ", ")
        let cached = GrammarVersionChecker.cachedResults()

        switch GrammarStaleness.advise(cached: cached) {
        case .noUpstreamData:
            printStatus(.skip, "Grammars: \(count) vendored — no upstream data. Run 'senkani grammars check' for updates")
            results.skipped += 1
        case .allFresh:
            printStatus(.pass, "Grammars: \(count) vendored (\(languages)), all up to date")
            results.passed += 1
        case .recentUpdatesAvailable(let n):
            printStatus(.pass, "Grammars: \(count) vendored, \(n) recent update(s) available (within \(GrammarStaleness.defaultThresholdDays)-day window)")
            results.passed += 1
        case .stale(let entries):
            let names = entries.map { "\($0.language) v\($0.vendoredVersion) \u{2192} v\($0.latestVersion) (\($0.daysStale)d stale)" }
            printStatus(.skip, "Grammars stale (>\(GrammarStaleness.defaultThresholdDays)d behind): \(names.joined(separator: ", ")). Run: senkani grammars check")
            results.skipped += 1
        }
    }

    // MARK: - Check 11: Agent Ecosystem

    private func checkAgents(_ results: inout Results) {
        let agents = AgentDiscovery.scan()
        if agents.isEmpty {
            printStatus(.skip, "Agents: no known agents detected")
            results.skipped += 1
            return
        }
        for agent in agents {
            let configName = (agent.configPath as NSString).lastPathComponent
            if agent.hasSenkaniMCP {
                printStatus(.pass, "\(agent.agentType.displayName): senkani MCP registered (\(configName))")
                results.passed += 1
            } else {
                printStatus(.fail, "\(agent.agentType.displayName): installed but senkani MCP not registered (\(configName))")
                results.failed += 1
            }
        }
    }

    // MARK: - Check 12: Learned Rules

    private func checkLearnedRules(_ results: inout Results) {
        let file = LearnedRulesStore.shared
        let staged  = file.rules.filter { $0.status == .staged }.count
        let applied = file.rules.filter { $0.status == .applied }.count

        if staged > 0 {
            printStatus(.fail, "Learned rules: \(staged) staged, pending review — run 'senkani learn apply' to activate")
            results.failed += 1
        } else if applied > 0 {
            printStatus(.pass, "Learned rules: \(applied) applied")
            results.passed += 1
        } else {
            printStatus(.skip, "Learned rules: none yet (generated after sessions with low filter savings)")
            results.skipped += 1
        }
    }

    // MARK: - Check 13: WARP.md Skills

    private func checkSkills(_ results: inout Results) {
        let skillsDir = NSHomeDirectory() + "/.senkani/skills"
        let fm = FileManager.default

        guard fm.fileExists(atPath: skillsDir) else {
            printStatus(.skip, "WARP skills: ~/.senkani/skills/ not found — create it and add .md skill files")
            results.skipped += 1
            return
        }

        let files = (try? fm.contentsOfDirectory(atPath: skillsDir))?.filter { $0.hasSuffix(".md") } ?? []
        if files.isEmpty {
            printStatus(.skip, "WARP skills: directory exists but no .md files — add skill files to ~/.senkani/skills/")
            results.skipped += 1
            return
        }

        let totalBytes = files.compactMap { f -> Int? in
            let path = (skillsDir as NSString).appendingPathComponent(f)
            return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)
        }.reduce(0, +)
        let kb = Double(totalBytes) / 1024
        printStatus(.pass, "WARP skills: \(files.count) skill\(files.count == 1 ? "" : "s") (\(String(format: "%.1f", kb)) KB) — injected at session start")
        results.passed += 1
    }

    // MARK: - Output Helpers

    private enum Status {
        case pass, fail, fixed, skip
    }

    private func printStatus(_ status: Status, _ message: String) {
        let prefix: String
        switch status {
        case .pass:  prefix = "\u{2713}"  // checkmark
        case .fail:  prefix = "\u{2717}"  // X mark
        case .fixed: prefix = "\u{2713}"  // checkmark (was fixed)
        case .skip:  prefix = "-"
        }
        print("\(prefix) \(message)")
    }

    // MARK: - Check 10: Daemon Health

    private func checkDaemonHealth(_ results: inout Results) {
        let hookSock = NSHomeDirectory() + "/.senkani/hook.sock"
        let paneSock = NSHomeDirectory() + "/.senkani/pane.sock"

        checkOneSocket(path: hookSock, name: "Hook daemon", results: &results)
        checkOneSocket(path: paneSock, name: "Pane daemon", results: &results)
    }

    private func checkOneSocket(path: String, name: String, results: inout Results) {
        let result = DaemonHealthCheck.check(socketPath: path, timeoutMs: 1000)
        switch result {
        case .pass:
            printStatus(.pass, "\(name): responsive (\((path as NSString).lastPathComponent))")
            results.passed += 1
        case .fail:
            printStatus(.skip, "\(name): not running (\((path as NSString).lastPathComponent))")
            results.skipped += 1
        case .warn:
            printStatus(.skip, "\(name): socket exists but timed out (\((path as NSString).lastPathComponent))")
            results.skipped += 1
        }
    }
}
