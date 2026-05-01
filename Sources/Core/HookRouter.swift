import Foundation

/// Tracks recent Read denials for search upgrade hint detection.
/// Thread-safe via NSLock. Entries older than the window are pruned on each check.
final class ReadDenialTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(path: String, timestamp: Date)] = []

    /// Record a denied Read and return the count of distinct file paths in the window.
    func recordAndCount(filePath: String, windowSeconds: TimeInterval = 30) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = Date().addingTimeInterval(-windowSeconds)
        entries.removeAll { $0.timestamp < cutoff }
        entries.append((path: filePath, timestamp: Date()))
        return Set(entries.map(\.path)).count
    }

    /// Reset tracker — called after hint fires and by tests.
    func reset() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}

/// Processes hook events from the senkani-hook binary and returns
/// routing decisions (block/passthrough) for Claude Code tool calls.
///
/// Response format follows Claude Code hook protocol:
/// - Passthrough: `{}`
/// - Block: `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "..."}}`
public enum HookRouter {

    /// Injected entity observer — set at app startup by MCPServer layer.
    /// Called synchronously on hookQueue for every PostToolUse event.
    /// nil in stdio-mode MCP server and hook-relay mode (graceful no-op).
    nonisolated(unsafe) public static var entityObserver: ((_ toolName: String, _ toolInput: [String: Any]) -> Void)?

    /// Test seam for validation advisory delivery. Production uses `.shared`.
    nonisolated(unsafe) static var validationDatabase: SessionDatabase = .shared

    /// V.12b test seam — tests inject a feed with a short window or
    /// a custom rate-cap sink to assert the suppression behavior
    /// without polluting the shared feed's state. Production uses
    /// `HookAnnotationFeed.shared`.
    nonisolated(unsafe) public static var annotationFeed: HookAnnotationFeed = .shared

    /// Phase U.4a — process-wide detector instance. Soft-flag only:
    /// nothing in this file's denial paths reads its output. Tests
    /// reach into the detector via `fragmentationDetector.reset()`.
    public static let fragmentationDetector = FragmentationDetector()

    /// Persistence sink for soft flags. Tests inject a recorder closure
    /// to assert flags surface; production wires it to
    /// `SessionDatabase.shared.recordTrustFlag(...)`. Default sink is
    /// the production path so HookRouter "just works" with no setup.
    nonisolated(unsafe) public static var trustFlagSink: (FragmentationDetector.Flag, Int) -> Void = { flag, score in
        _ = SessionDatabase.shared.recordTrustFlag(flag, score: score)
    }

    /// Process a hook event JSON and return a response JSON.
    /// Returns `{}` (passthrough) for unrecognized or unroutable events.
    public static func handle(eventJSON: Data) -> Data {
        guard let event = try? JSONSerialization.jsonObject(with: eventJSON) as? [String: Any],
              let toolName = event["tool_name"] as? String else {
            return passthroughResponse
        }

        let toolInput = event["tool_input"] as? [String: Any] ?? [:]
        let eventName = event["hook_event_name"] as? String ?? "PreToolUse"
        let projectRoot = event["cwd"] as? String
        let sessionId = event["session_id"] as? String

        // Record the hook event for compliance tracking
        if let sid = sessionId {
            SessionDatabase.shared.recordHookEvent(
                sessionId: sid,
                toolName: toolName,
                eventType: eventName,
                projectRoot: projectRoot
            )

            // Phase U.4a — non-blocking soft-flag pass. Detector returns
            // any FragmentationDetector.Flag observations triggered by
            // this event; the sink persists them. NOTHING here can
            // deny the call — promotion-to-blocking lives in U.4b.
            let paneId = event["pane_id"] as? String
            let fragment = (toolInput["prompt"] as? String)
                ?? (toolInput["command"] as? String)
                ?? (toolInput["file_path"] as? String)
            let flags = fragmentationDetector.record(.init(
                sessionId: sid,
                paneId: paneId,
                toolName: toolName,
                fragment: fragment
            ))
            for flag in flags {
                let score = TrustScorer.score(flags: [flag])
                trustFlagSink(flag, score)
            }
        }

        // PostToolUse: record + enqueue auto-validation if Edit/Write
        if eventName == "PostToolUse" {
            if toolName == "Edit" || toolName == "Write" {
                handlePostEditWrite(toolInput: toolInput, sessionId: sessionId, projectRoot: projectRoot)
            }
            // Entity mention tracking — bridge to MCPServer layer via injected closure.
            // No-op when observer is nil (stdio mode, hook-relay mode, tests).
            entityObserver?(toolName, toolInput)
            return passthroughResponse
        }

        // Fetch pending validation advisories without mutating delivery state.
        // Rows are marked surfaced only after the advisory is appended to a
        // hook response the agent will actually see.
        var validationRows: [SessionDatabase.ValidationResultRow] = []
        var validationAdvisory = ""
        if let sid = sessionId {
            validationRows = validationDatabase.pendingValidationAdvisories(sessionId: sid)
            if !validationRows.isEmpty {
                validationAdvisory = formatValidationAdvisory(validationRows)
            }
        }

        // Budget enforcement on the hook path
        if case .block(let reason) = checkHookBudgetGate(projectRoot: projectRoot) {
            // V.12b: budget gate is a real blocker — emit must-fix.
            emitDenialAnnotation(
                severity: .mustFix,
                body: reason,
                toolName: toolName,
                toolInput: toolInput,
                sessionId: sessionId
            )
            return appendAndMarkValidationIfSurfaced(
                blockResponse(reason, eventName: eventName),
                advisory: validationAdvisory,
                rows: validationRows,
                projectRoot: projectRoot
            )
        }

        // T.6a: ConfirmationGate on write/exec-tagged tools. Read-tagged
        // tools and unknowns short-circuit at the gate with `.auto` and
        // no row written. The default policy resolver also returns
        // `.auto`, so production behavior on Edit/Write/Bash today is
        // "approve, but log a chained row" — Schneier's auditability
        // contract. A test-injected resolver can return `.deny` to
        // exercise the structured-error path.
        let confirmation = ConfirmationGate.evaluate(toolName: toolName)
        if confirmation.decision == .deny {
            // V.12b: ConfirmationGate deny is a real blocker — emit
            // must-fix. The deny response itself is unchanged so the
            // agent still sees the deny (acceptance: non-blocking
            // suppression).
            let body = ConfirmationGate.denyReason(toolName: toolName, reason: confirmation.reason)
            emitDenialAnnotation(
                severity: .mustFix,
                body: body,
                toolName: toolName,
                toolInput: toolInput,
                sessionId: sessionId
            )
            return appendAndMarkValidationIfSurfaced(
                blockResponse(body, eventName: eventName),
                advisory: validationAdvisory,
                rows: validationRows,
                projectRoot: projectRoot
            )
        }

        // Route the tool call
        var response: Data
        switch toolName {
        case "Read":
            response = handleRead(toolInput: toolInput, eventName: eventName, projectRoot: projectRoot, sessionId: sessionId)
        case "Bash":
            let command = toolInput["command"] as? String ?? ""
            response = handleBash(command: command, eventName: eventName, projectRoot: projectRoot, sessionId: sessionId)
        case "Grep":
            let pattern = toolInput["pattern"] as? String ?? ""
            response = handleGrep(pattern: pattern, eventName: eventName)
        default:
            response = passthroughResponse
        }

        // Phase J: append validation advisory to visible deny responses.
        return appendAndMarkValidationIfSurfaced(
            response,
            advisory: validationAdvisory,
            rows: validationRows,
            projectRoot: projectRoot
        )
    }

    // MARK: - V.12b denial-annotation emit

    /// Emit a `HookAnnotation` for a denial that is *tied to a code
    /// change* — the gate-level denials (budget + ConfirmationGate)
    /// where the agent's tool call would have mutated the project.
    /// Read/Bash/Grep advisory denials are excluded by design: those
    /// are token-saving redirects, not policy violations, and would
    /// flood the diff sidebar with "[must-fix]" badges.
    ///
    /// Goes through `HookAnnotationFeed.shared`; the feed enforces
    /// the per-minute must-fix rate cap and writes the suppression
    /// log row when a window rolls. Subscribers (DiffViewerPane in
    /// SenkaniApp) are notified iff the annotation is admitted.
    private static func emitDenialAnnotation(
        severity: DiffAnnotationSeverity,
        body: String,
        toolName: String,
        toolInput: [String: Any],
        sessionId: String?
    ) {
        let filePath = (toolInput["file_path"] as? String)
            ?? (toolInput["path"] as? String)
        let annotation = HookAnnotation(
            severity: severity,
            body: body,
            toolName: toolName,
            filePath: filePath,
            sessionId: sessionId
        )
        annotationFeed.record(annotation)
    }

    // MARK: - Search Upgrade (Phase I)

    /// Tracks Read denials to detect search-like behavior.
    static let readDenialTracker = ReadDenialTracker()

    /// Returns a search hint if 3+ distinct files denied in 30s, empty string otherwise.
    /// Resets the tracker after firing to prevent repeat hints.
    static func searchUpgradeHint(filePath: String) -> String {
        guard !filePath.isEmpty else { return "" }
        let count = readDenialTracker.recordAndCount(filePath: filePath)
        guard count >= 3 else { return "" }
        readDenialTracker.reset()
        return " You've read \(count) different files recently — if you're searching for a symbol, try mcp__senkani__search instead (~50 tokens vs reading each file)."
    }

    // MARK: - Tool Handlers

    private static func handleRead(toolInput: [String: Any], eventName: String, projectRoot: String?, sessionId: String?) -> Data {
        let filePath = toolInput["file_path"] as? String ?? ""

        // Phase I wedge: Re-read suppression
        // If this file was already served by senkani_read AND the file hasn't changed,
        // tell the agent it already has the content — eliminates the tool call entirely.
        if !filePath.isEmpty, let root = projectRoot {
            if let lastRead = SessionDatabase.shared.lastReadTimestamp(filePath: filePath, projectRoot: root) {
                let age = Date().timeIntervalSince(lastRead)

                // Only suppress if the read was recent (within 5 minutes) and the file is unchanged
                if age < 300 {
                    let fullPath = filePath.hasPrefix("/") ? filePath : root + "/" + filePath

                    if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
                       let mtime = attrs[.modificationDate] as? Date,
                       mtime < lastRead {

                        let ageStr = age < 60 ? "\(Int(age))s" : "\(Int(age / 60))m"

                        if let sid = sessionId {
                            SessionDatabase.shared.recordTokenEvent(
                                sessionId: sid,
                                paneId: nil,
                                projectRoot: root,
                                source: "intercept",
                                toolName: "Read",
                                model: nil,
                                inputTokens: 0,
                                outputTokens: 0,
                                savedTokens: estimateFileTokens(at: fullPath),
                                costCents: 0,
                                feature: "reread_suppression",
                                command: filePath,
                                modelTier: "tier2_estimated"
                            )
                        }

                        return blockResponse(
                            "This file was already read \(ageStr) ago via senkani and hasn't changed (mtime unchanged). "
                            + "Use your existing knowledge of this file's content. "
                            + "If you need to re-read it (e.g., after context compaction), call mcp__senkani__read — it returns from cache instantly (0 tokens)."
                            + searchUpgradeHint(filePath: filePath),
                            eventName: eventName
                        )
                    }
                }
            }
        }

        // Default: first Read of this file (or file changed since last read)
        let features = "session caching (re-reads free), compression, secret detection"
        return blockResponse(
            "Use mcp__senkani__read instead of Read. "
            + "Active features: \(features). "
            + "Pass the same file_path as the 'path' argument."
            + searchUpgradeHint(filePath: filePath),
            eventName: eventName
        )
    }

    /// Estimate token count for a file based on size (rough: 1 token per 4 bytes).
    private static func estimateFileTokens(at path: String) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int else { return 0 }
        return size / 4
    }

    private static func handleBash(command: String, eventName: String, projectRoot: String?, sessionId: String?) -> Data {
        guard !command.isEmpty else { return passthroughResponse }

        // Phase I: Command replay — check BEFORE passthrough.
        // If a replayable command was recently run and no files changed, deny with cached result.
        if let root = projectRoot {
            if let replayDeny = checkCommandReplay(command: command, projectRoot: root, sessionId: sessionId, eventName: eventName, db: .shared) {
                return replayDeny
            }
        }

        // Phase I: Trivial routing — answer ls, pwd, echo etc. directly in deny reason.
        // Saves a full tool call round-trip for commands with known local answers.
        if let trivialDeny = checkTrivialRouting(command: command, projectRoot: projectRoot, sessionId: sessionId, eventName: eventName) {
            return trivialDeny
        }

        // Allowlist: commands that must pass through natively
        if isBashPassthrough(command) {
            return passthroughResponse
        }

        return blockResponse(
            "Use mcp__senkani__exec instead of Bash for this read-only command. "
            + "It filters output (24 command rules, ANSI stripping, dedup, truncation, secret detection). "
            + "Pass command: \"\(command)\"",
            eventName: eventName
        )
    }

    /// Check if a command can be replayed from a recent cached result.
    /// Extracted as internal static for testability — tests pass a temp DB
    /// and optionally a fingerprint override.
    /// Returns a deny response if replay conditions are met, nil otherwise.
    static func checkCommandReplay(
        command: String,
        projectRoot: String,
        sessionId: String?,
        eventName: String,
        db: SessionDatabase,
        projectMaxMtime: (String) -> Date? = { ProjectFingerprint.maxSourceMtime(projectRoot: $0) }
    ) -> Data? {
        guard isReplayable(command) else { return nil }

        guard let lastExec = db.lastExecResult(command: command, projectRoot: projectRoot) else { return nil }

        let age = Date().timeIntervalSince(lastExec.timestamp)
        guard age < 300 else { return nil }

        // Only replay if NO tracked source file has been modified since the
        // last exec. Root directory mtime is unreliable — it doesn't change
        // when nested files are edited — so we walk the tree for the true
        // max source mtime. Empty project (no tracked files) is treated as
        // unchanged.
        let latest = projectMaxMtime(projectRoot) ?? .distantPast
        guard latest < lastExec.timestamp else { return nil }

        let ageStr = age < 60 ? "\(Int(age))s" : "\(Int(age / 60))m"
        let preview = lastExec.outputPreview ?? "(no output preview available)"

        // Record the replay intercept event
        if let sid = sessionId {
            let estimatedSaved = (lastExec.outputPreview?.utf8.count ?? 500) / 4
            db.recordTokenEvent(
                sessionId: sid,
                paneId: nil,
                projectRoot: projectRoot,
                source: "intercept",
                toolName: "Bash",
                model: nil,
                inputTokens: 0,
                outputTokens: 0,
                savedTokens: estimatedSaved,
                costCents: 0,
                feature: "command_replay",
                command: command,
                modelTier: "tier2_estimated"
            )
        }

        return blockResponse(
            "This command was already run \(ageStr) ago and no source files have changed since. "
            + "Previous result: \(preview). "
            + "Run it again only if you've made changes since the last run.",
            eventName: eventName
        )
    }

    /// Commands eligible for replay — deterministic, read-only, no side effects.
    ///
    /// The previous implementation used `hasPrefix` which let dangerous
    /// variants slip through: `swift test; rm -rf tmp` would prefix-match
    /// and replay. The hardened version requires:
    ///   1. A recognized base command (allowlist).
    ///   2. No shell metacharacters (`|`, `>`, `;`, `&&`, backticks, `$(…)`,
    ///      `&`, quotes).
    ///   3. No env-var prefix (`FOO=bar <cmd>`).
    ///   4. No flag from the "non-deterministic" blocklist (`--watch`,
    ///      `--interactive`, `--inspect`, `--debug`, `--`, etc.).
    /// Positional arguments (`swift test --filter Foo`, `go test ./...`,
    /// `eslint src/`) remain replayable because the command *string itself*
    /// is the cache key — replaying the same string with no source changes
    /// is safe.
    static func isReplayable(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        // Shell metacharacters that make the "same command" claim unsafe.
        // Reject backgrounding (&), chaining (;, &&, ||), piping (|),
        // redirection (<, >), subshells (`…`, $(…)), variable expansion
        // ($VAR), and quoting (which usually signals an argument we can't
        // inspect). `\` would enable escapes that bypass tokenization.
        let badChars: Set<Character> = [";", "|", "&", ">", "<", "`", "$", "'", "\"", "\\", "(", ")", "{", "}"]
        if trimmed.contains(where: { badChars.contains($0) }) { return false }

        // Env-var prefix like `FOO=bar swift test` is forbidden — the
        // assignment changes behavior and the cache key wouldn't catch it.
        let firstToken = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? trimmed
        if firstToken.contains("=") { return false }

        let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !tokens.isEmpty else { return false }

        // Must match a known base command exactly on its leading tokens.
        guard let baseLen = matchReplayableBase(tokens: tokens) else { return false }

        // Every remaining token must not be in the non-deterministic blocklist.
        let extras = tokens.dropFirst(baseLen)
        for extra in extras where nonDeterministicFlags.contains(extra) {
            return false
        }
        // The bare `--` separator forwards everything that follows to a
        // subcommand. We can't reason about what's after it without
        // tool-specific parsing, so bail out.
        if extras.contains("--") { return false }
        // Block tokens that start with `--watch` / `--inspect` / `--debug`
        // even with a suffix like `--watchAll` or `--inspect-brk`.
        for extra in extras {
            let lower = extra.lowercased()
            if lower.hasPrefix("--watch") { return false }
            if lower.hasPrefix("--inspect") { return false }
            if lower.hasPrefix("--debug") { return false }
            if lower.hasPrefix("--interactive") { return false }
        }
        return true
    }

    /// Return the number of tokens consumed by a matching base command,
    /// or nil if none match. The longest-matching base wins so
    /// `python -m pytest` is picked up before `python`.
    private static func matchReplayableBase(tokens: [String]) -> Int? {
        var bestMatch: Int? = nil
        for base in replayableBaseCommands {
            guard tokens.count >= base.count else { continue }
            var ok = true
            for (i, part) in base.enumerated() where tokens[i] != part {
                ok = false
                break
            }
            if ok {
                if let current = bestMatch, base.count <= current { continue }
                bestMatch = base.count
            }
        }
        return bestMatch
    }

    /// Exact base-command token sequences that are deterministic enough
    /// to cache + replay. The command STRING is the cache key, so a
    /// positional argument like `--filter Foo` is fine — replaying
    /// identical input gives identical output when source hasn't changed.
    private static let replayableBaseCommands: [[String]] = [
        ["swift", "test"],
        ["swift", "build"],
        ["npm", "test"],
        ["npm", "run", "test"],
        ["npx", "jest"],
        ["npx", "vitest"],
        ["npx", "tsc"],
        ["cargo", "test"],
        ["cargo", "build"],
        ["cargo", "check"],
        ["cargo", "clippy"],
        ["go", "test"],
        ["go", "build"],
        ["go", "vet"],
        ["pytest"],
        ["python", "-m", "pytest"],
        ["python", "-m", "unittest"],
        ["python3", "-m", "pytest"],
        ["python3", "-m", "unittest"],
        ["make", "test"],
        ["make", "build"],
        ["make", "check"],
        ["tsc"],
        ["eslint"],
        ["ruff", "check"],
        ["ruff"],
        ["flake8"],
        ["mypy"],
        ["pylint"],
        ["swiftlint"],
        ["rubocop"],
    ]

    /// Flags that make a command non-deterministic (watch loops, debuggers,
    /// interactive prompts). Exact-token match; prefix matches for
    /// `--watch*`, `--inspect*`, `--debug*`, `--interactive*` are handled
    /// separately in `isReplayable`.
    private static let nonDeterministicFlags: Set<String> = [
        "-i",
        "--fix",              // linters: mutates files
    ]

    private static func handleGrep(pattern: String, eventName: String) -> Data {
        guard !pattern.isEmpty else { return passthroughResponse }

        // Only intercept simple identifier patterns — regex stays native
        let hasRegexChars = pattern.contains(where: { "\\[](){}|+?^$.*".contains($0) })
        if hasRegexChars { return passthroughResponse }

        // Must look like an identifier: [a-zA-Z_][a-zA-Z0-9_]*
        let isIdentifier = pattern.first.map { $0.isLetter || $0 == "_" } ?? false
            && pattern.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        guard isIdentifier else { return passthroughResponse }

        return blockResponse(
            "Use mcp__senkani__search instead of Grep for symbol lookup. "
            + "Returns compact results (~50 tokens vs ~5000). "
            + "Pass query: \"\(pattern)\". "
            + "For regex or content search, Grep is fine.",
            eventName: eventName
        )
    }

    // MARK: - Trivial Routing (Phase I)

    /// Commands that can be answered locally without any tool call.
    /// Returns a deny with the answer embedded, saving a full round-trip.
    static func checkTrivialRouting(command: String, projectRoot: String?, sessionId: String?, eventName: String, db: SessionDatabase = .shared) -> Data? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)

        // Don't handle commands with pipes, semicolons, redirects, or subshells
        if trimmed.contains("|") || trimmed.contains(";") || trimmed.contains("$(") || trimmed.contains("`") || trimmed.contains(">") {
            return nil
        }

        var answer: String?

        if trimmed == "pwd" {
            answer = projectRoot ?? FileManager.default.currentDirectoryPath
        } else if trimmed == "whoami" {
            answer = NSUserName()
        } else if trimmed == "hostname" {
            answer = ProcessInfo.processInfo.hostName
        } else if trimmed == "date" {
            let formatter = DateFormatter()
            formatter.dateStyle = .full
            formatter.timeStyle = .medium
            answer = formatter.string(from: Date())
        } else if trimmed == "echo" {
            answer = ""  // bare echo prints empty line
        } else if trimmed.hasPrefix("echo ") {
            let text = String(trimmed.dropFirst(5))
            // Don't route if there are variable expansions
            if text.contains("$") { return nil }
            // Strip simple surrounding quotes
            var unquoted = text
            if (unquoted.hasPrefix("\"") && unquoted.hasSuffix("\"")) ||
               (unquoted.hasPrefix("'") && unquoted.hasSuffix("'")) {
                unquoted = String(unquoted.dropFirst().dropLast())
            }
            answer = unquoted
        } else if trimmed == "ls" || trimmed.hasPrefix("ls ") {
            let args = trimmed == "ls" ? "" : String(trimmed.dropFirst(3))
            // Only handle bare ls or ls <simple-path> — no flags
            if !args.isEmpty && args.hasPrefix("-") { return nil }

            // Resolve the target directory through ProjectSecurity so an
            // absolute path outside the root (or a `..` escape) cannot
            // short-circuit into a directory listing. `ls /Users/otheruser`
            // would otherwise leak a listing of someone else's home.
            guard let root = projectRoot else { return nil }
            let dir: String
            do {
                if args.isEmpty {
                    dir = try ProjectSecurity.resolveProjectFile(".", projectRoot: root)
                } else {
                    dir = try ProjectSecurity.resolveProjectFile(args, projectRoot: root)
                }
            } catch {
                // Out-of-root listing requests fall through to the original
                // tool rather than being answered locally.
                return nil
            }

            if let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                let visible = entries.filter { !$0.hasPrefix(".") }.sorted()
                if visible.count <= 50 {
                    answer = visible.isEmpty ? "(empty directory)" : visible.joined(separator: "  ")
                } else {
                    answer = visible.prefix(50).joined(separator: "  ") + "\n... and \(visible.count - 50) more entries"
                }
            }
        }

        guard let result = answer else { return nil }

        // Record the intercept event
        if let sid = sessionId, let root = projectRoot {
            db.recordTokenEvent(
                sessionId: sid,
                paneId: nil,
                projectRoot: root,
                source: "intercept",
                toolName: "Bash",
                model: nil,
                inputTokens: 0,
                outputTokens: 0,
                savedTokens: max(10, result.utf8.count / 4),
                costCents: 0,
                feature: "trivial_routing",
                command: trimmed,
                modelTier: "tier2_estimated"
            )
        }

        return blockResponse(
            "Result: \(result)",
            eventName: eventName
        )
    }

    // MARK: - Bash Allowlist

    /// Commands that must pass through to native Bash (destructive, build, or shell builtins).
    private static func isBashPassthrough(_ command: String) -> Bool {
        let prefixes = [
            // Git (mutating)
            "git commit", "git push", "git add", "git checkout", "git reset",
            "git stash", "git merge", "git rebase",
            // Filesystem mutations
            "rm ", "mv ", "cp ", "mkdir ", "touch ", "chmod ", "chown ",
            // Build systems
            "swift build", "swift test", "swift package", "swift run",
            "npm run", "npm start", "npm install", "yarn ", "bun run", "bun test", "bun install",
            "cargo build", "cargo test", "cargo run", "cargo install",
            "go build", "go test", "go run", "go install",
            "make ", "cmake ", "docker ", "kubectl ",
            // Package managers
            "pip install", "pip3 install", "brew install", "brew upgrade",
            // Shell builtins and dangerous
            "cd ", "export ", "source ", "eval ", "sudo ",
        ]

        for prefix in prefixes {
            if command.hasPrefix(prefix) { return true }
        }

        // Redirects (output to file)
        if command.contains(">") { return true }

        return false
    }

    // MARK: - Auto-Validate (Phase J)

    /// Handle PostToolUse for Edit/Write — enqueue background validation.
    /// Returns immediately (<1ms). Validation runs asynchronously.
    private static func handlePostEditWrite(
        toolInput: [String: Any],
        sessionId: String?,
        projectRoot: String?
    ) {
        guard let sid = sessionId, let root = projectRoot else { return }

        let filePath = toolInput["file_path"] as? String
            ?? toolInput["path"] as? String
            ?? ""
        guard !filePath.isEmpty else { return }

        let absPath = filePath.hasPrefix("/") ? filePath : root + "/" + filePath

        Task {
            await AutoValidateQueue.shared.enqueue(
                path: absPath,
                sessionId: sid,
                projectRoot: root
            )
        }
    }

    /// Format validation results into an advisory string for the deny reason.
    private static func formatValidationAdvisory(_ results: [SessionDatabase.ValidationResultRow]) -> String {
        var lines = ["\n\n--- Validation Results ---"]
        for result in results.prefix(5) {
            lines.append(result.advisory)
        }
        if results.count > 5 {
            lines.append("... and \(results.count - 5) more. Run senkani_validate for full output.")
        }
        return lines.joined(separator: "\n")
    }

    /// Append advisory text to an existing deny response JSON.
    private static func appendAdvisoryToResponse(_ response: Data, advisory: String) -> (data: Data, appended: Bool) {
        guard var json = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              var hookOutput = json["hookSpecificOutput"] as? [String: Any],
              let reason = hookOutput["permissionDecisionReason"] as? String
        else { return (response, false) }

        hookOutput["permissionDecisionReason"] = reason + advisory
        json["hookSpecificOutput"] = hookOutput
        guard let data = try? JSONSerialization.data(withJSONObject: json) else {
            return (response, false)
        }
        return (data, true)
    }

    private static func appendAndMarkValidationIfSurfaced(
        _ response: Data,
        advisory: String,
        rows: [SessionDatabase.ValidationResultRow],
        projectRoot: String?
    ) -> Data {
        guard !advisory.isEmpty, !rows.isEmpty, response != passthroughResponse else {
            return response
        }
        let result = appendAdvisoryToResponse(response, advisory: advisory)
        if result.appended {
            validationDatabase.markValidationAdvisoriesSurfaced(ids: rows.map(\.id))
            validationDatabase.recordEvent(type: "auto_validate.delivered", projectRoot: projectRoot)
        }
        return result.data
    }

    // MARK: - Budget Gate (testable)

    /// Hook-path budget gate. Pure function of (projectRoot, config, costs).
    /// Returns the decision that `handle()` should apply:
    /// - `.allow` when no projectRoot / no daily-or-weekly limit configured.
    /// - `.block(reason)` / `.warn(reason)` from `BudgetConfig.check`.
    ///
    /// The cost fetchers default to `SessionDatabase.shared` so production
    /// callers don't need to wire anything up; tests inject fabricated
    /// closures to exercise the gate without DB pollution.
    ///
    /// Note: this path passes `sessionCents: 0` by design — per-session limits
    /// are MCP-session-scoped (tracked by `MCPSession`) and don't apply to
    /// hook events from arbitrary tools. Only daily and weekly limits fire
    /// here. The ToolRouter path layers pane-cap + per-session on top of
    /// these same daily/weekly checks.
    public static func checkHookBudgetGate(
        projectRoot: String?,
        config: BudgetConfig = BudgetConfig.load(),
        costForToday: () -> Int = { SessionDatabase.shared.costForToday() },
        costForWeek: () -> Int = { SessionDatabase.shared.costForWeek() }
    ) -> BudgetConfig.Decision {
        guard projectRoot != nil else { return .allow }
        guard config.dailyLimitCents != nil || config.weeklyLimitCents != nil else {
            return .allow
        }
        return config.check(
            sessionCents: 0,
            todayCents: costForToday(),
            weekCents: costForWeek()
        )
    }

    // MARK: - Response Builders

    static let passthroughResponse = Data("{}".utf8)

    static func blockResponse(_ reason: String, eventName: String = "PreToolUse") -> Data {
        let response: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": eventName,
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            ] as [String: Any]
        ]
        return (try? JSONSerialization.data(withJSONObject: response)) ?? passthroughResponse
    }
}
