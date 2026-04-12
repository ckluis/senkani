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
        let modelsDir = NSHomeDirectory() + "/Documents/huggingface/models"
        let fm = FileManager.default

        let knownModels: [(id: String, name: String, dirPattern: String)] = [
            ("minilm-l6", "MiniLM-L6", "all-MiniLM-L6"),
            ("qwen2-vl-2b", "Qwen2-VL", "Qwen2-VL"),
        ]

        var statuses: [String] = []

        for model in knownModels {
            var downloaded = false
            if fm.fileExists(atPath: modelsDir),
               let contents = try? fm.contentsOfDirectory(atPath: modelsDir) {
                downloaded = contents.contains { $0.contains(model.dirPattern) }
            }
            statuses.append("\(model.name) (\(downloaded ? "downloaded" : "not downloaded"))")
        }

        printStatus(.pass, "Models: \(statuses.joined(separator: ", "))")
        results.passed += 1
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

        // Use cached results only — no network calls in doctor
        if let cached = GrammarVersionChecker.cachedResults() {
            let outdated = cached.filter { $0.isOutdated }
            if outdated.isEmpty {
                printStatus(.pass, "Grammars: \(count) vendored (\(languages)), all up to date")
                results.passed += 1
            } else {
                let names = outdated.map { "\($0.grammar.language) v\($0.grammar.version) \u{2192} v\($0.latestVersion ?? "?")" }
                printStatus(.fail, "Grammars: \(names.joined(separator: ", ")) outdated. Run: senkani grammars check")
                results.failed += 1
            }
        } else {
            printStatus(.pass, "Grammars: \(count) vendored (\(languages)). Run 'senkani grammars check' for updates")
            results.passed += 1
        }
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
}
