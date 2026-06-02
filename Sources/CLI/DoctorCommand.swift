import ArgumentParser
import Bench
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

    @Flag(name: .long, help: "Run only the audit-chain integrity check (Phase T.5). Exit 0 on OK, non-zero on tamper.")
    var verifyChain = false

    @Flag(name: .long, help: "Open a fresh audit-chain segment after a verified tamper. Requires --table and --from-rowid. Double-confirms unless --force.")
    var repairChain = false

    @Option(name: .long, help: "Table to repair (token_events | validation_results | commands).")
    var table: String?

    @Option(name: .long, help: "First rowid to re-anchor under the new repair anchor.")
    var fromRowid: Int64?

    @Flag(name: .long, help: "Skip the typed-string double-confirm. Required when stdin is not a tty, or to override the 'repair anchor already exists' guard.")
    var force = false

    @Option(name: .long, help: "Free-form note recorded on the new repair anchor's operator_note field.")
    var note: String?

    @Flag(name: .long, help: "When check #20 detects a stale walk bundle, skip the auto-rebuild and only warn. Default is rebuild.")
    var noRebuildStaleBundle = false

    @Flag(name: .long, help: "Print the operator-runnable command to install Playwright Chromium (U.2a-1). Does NOT auto-download. Idempotent: writes a single `validation.browser.install` chained audit row on first cache detection.")
    var installValidationBrowser = false

    @Flag(name: .long, help: "Walk the EgressProxy 5-scenario adversarial smoke subset (T.1c). Reports per-scenario pass/fail with rule_id; exits non-zero on any miss. Engine-level — does not spin the live listener.")
    var checkEgress = false

    @Flag(name: .long, help: "Generate the MITM egress CA pem and PRINT the operator-runnable `security add-trusted-cert ...` command to add it as a System trust root (T.1d-6). DRY-RUN scaffolding only: NEVER runs `security`, never sudo, never mutates the System Keychain (that is t1d-7, gui-human). Requires a typed-string confirm.")
    var installEgressCA = false

    @Flag(name: .long, help: "Reversible counterpart to --install-egress-ca: remove the local CA pem (if present) and PRINT the operator-runnable `security remove-trusted-cert ...` command (T.1d-6). DRY-RUN scaffolding only — never runs `security`, never touches the System Keychain.")
    var uninstallEgressCA = false

    // MARK: - Counters

    private struct Results {
        var passed = 0
        var fixed = 0
        var failed = 0
        var skipped = 0
    }

    func run() throws {
        // T.5 round 4: focused repair mode. Required: --table and
        // --from-rowid. Double-confirm prompts unless --force is supplied.
        if repairChain {
            try runRepairChain()
            return
        }

        // T.5 round 2: focused verify mode — only the audit chain check,
        // scriptable exit code, no other noise.
        if verifyChain {
            var results = Results()
            checkAuditChain(&results)
            if results.failed > 0 { throw ExitCode.failure }
            return
        }

        // U.2a-1 focused install motion — print the operator-runnable
        // command, refuse to auto-download, write a chained audit row on
        // first cache detection.
        if installValidationBrowser {
            runInstallValidationBrowser()
            return
        }

        // T.1c focused smoke motion — walk the 5-scenario adversarial
        // smoke subset purely at the rule-engine / normalizer level,
        // print per-scenario verdicts, exit non-zero on any miss.
        if checkEgress {
            try runCheckEgress()
            return
        }

        // T.1d-6 focused install motion — generate the CA pem and PRINT
        // (never run) the `security add-trusted-cert ...` command, gated
        // behind a typed-string confirm. Routes through the dry-run
        // executor so no `security` process is ever spawned here (the real
        // trust install + sudo is t1d-7, gui-human).
        if installEgressCA {
            try runInstallEgressCA()
            return
        }

        // T.1d-6 reversible counterpart — remove the local CA pem and
        // PRINT (never run) the `security remove-trusted-cert ...` command
        // through the same dry-run executor.
        if uninstallEgressCA {
            try runUninstallEgressCA()
            return
        }

        print("Senkani Doctor")
        print("==============")

        var results = Results()

        // Numbering note: the inline `// N.` comments below are DISPATCH
        // RUN-ORDER (the sequence checks execute in), NOT the stable
        // `// MARK: - Check N` IDs the functions carry. The two schemes
        // intentionally diverge for checks whose stable ID was assigned in
        // creation order rather than run order — e.g. Release commitments
        // runs 15th here but is stable Check 22; Audit chain runs 16th but is
        // stable Check 15; Session work bus runs 17b but is stable Check 21;
        // Runtime telemetry runs 21st but is stable Check 23; OpenAI endpoint
        // runs 22nd but is stable Check 16. Do NOT
        // "reconcile" them by renumbering the MARK headers — the stable IDs
        // are a durable cross-reference (see doctor-unnumbered-checks-
        // 2026-05-27). Matching note lives above `// MARK: - Check 15`.

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

        // 5b. Per-RAM-tier Gemma 4 output quality
        checkMLTierQuality(&results)

        // 5c. PIIClassifier Layer 3 wiring (T.2b-1). Surfaces the four
        // states the operator needs to see: not pulled (status .available),
        // backend not ready (status .verified but adapter throws),
        // available (status .verified + smoke OK), verification failed
        // (status .broken / .error). T.2b-2 extends this with the F1 +
        // commit-sha + last-eval-run suffixes.
        checkPIIClassifierLayer3(&results)

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

        // 14. SLO pack — three published SLOs + hook-active ceiling
        checkSLOs(&results)

        // 15. Release commitments (Phase V.14) — cold-start, idle
        // memory, install size, classifier slot.
        checkReleaseSLOs(&results)

        // 16. Audit chain integrity (Phase T.5)
        checkAuditChain(&results)

        // 17. Trust flags — soft-flag FP-rate counter (Phase U.4a)
        checkTrustFlags(&results)

        // 17b. Session work bus — U.9a queue + stream + offsets
        checkSessionWorkBus(&results)

        // 18. Egress proxy — T.1a daemon scaffold + decision audit log
        checkEgressProxy(&results)

        // 18b. Anthropic serve egress allow rule (V.13b-4b, Option B) —
        //      surface the one-line hint when api.anthropic.com is not yet
        //      authorized in egress-policy.json (deny-on-miss preserved).
        checkAnthropicEgressAllowRule(&results)

        // 18c. Anthropic vault labels (V.13b-5) — list provisioned upstream
        //      anthropic-key labels (label only, NEVER plaintext). Together
        //      with 18b this forms the operator-facing "anthropic arm
        //      readiness" surface: 18b proves the egress allow rule is
        //      authorized, 18c proves at least one upstream key is
        //      provisioned so `senkani serve --openai` can serve a
        //      non-local tier.
        checkAnthropicVaultLabels(&results)

        // 19. FileProvider eviction risk on .build/ checkouts
        //     (build-env-swiftpm-checkout-corruption-icloud-eviction-2026-05-09 Phase A).
        checkFileProviderEviction(&results)

        // 20. Walk-bundle staleness — `tools/soak/runner/[_onboarding-pass-]SenkaniApp.app`
        //     binary mtime vs merge-target HEAD commit time. Auto-
        //     rebuilds via BundleRebuilder unless --no-rebuild-stale-bundle.
        //     (onboarding-pass-stale-bundle-hazard-2026-05-14.)
        checkBundleStaleness(&results)

        // 21. Runtime telemetry receiver (Phase V.18a-3) — last-bound
        //     loopback port + cumulative drops. Loopback boundary is
        //     performative; see spec/architecture.md.
        checkRuntimeTelemetryReceiver(&results)

        // 22. OpenAI-compatible endpoint (Phase V.13e-2) — bind / port /
        //     key-count + trailing-24h request count + 429-rate. The last
        //     two read v13e-1's persisted request-log query API, so they
        //     survive a process restart.
        checkOpenAIEndpoint(&results)

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

    // MARK: - --install-validation-browser (U.2a-1)

    /// Operator-runnable motion: print `npx playwright install chromium`,
    /// probe the Chromium cache, write a single `validation.browser.install`
    /// chained audit row on first detection. Does NOT auto-download —
    /// keeps the operator in the loop for any third-party-binary install.
    ///
    /// Idempotency: the chained-row write is gated on a
    /// `tokenEventExists(source: "doctor", feature: "validation.browser.install")`
    /// probe. Subsequent invocations after the first detection print
    /// `already installed` and write no new audit row.
    private func runInstallValidationBrowser() {
        let cachePath = PlaywrightSubprocessRunner.defaultChromiumCachePath
        let installed = FileManager.default.fileExists(atPath: cachePath)

        if !installed {
            print("Playwright Chromium is not installed at:")
            print("  \(cachePath)")
            print("")
            print("Run:")
            print("  npx playwright install chromium")
            print("")
            print("This is the operator-runnable install for U.2a-1's")
            print("browser-validation runtime. senkani will NOT auto-download")
            print("third-party binaries.")
            return
        }

        let alreadyRecorded = SessionDatabase.shared.tokenEventExists(
            source: "doctor",
            feature: "validation.browser.install"
        )
        if !alreadyRecorded {
            SessionDatabase.shared.recordTokenEvent(
                sessionId: "doctor",
                paneId: nil,
                projectRoot: nil,
                source: "doctor",
                toolName: nil,
                model: nil,
                inputTokens: 0,
                outputTokens: 0,
                savedTokens: 0,
                costCents: 0,
                feature: "validation.browser.install",
                command: nil
            )
            // Wait for the async write to land before returning so the
            // next invocation's existence probe sees the row.
            SessionDatabase.shared.flushWrites()
            print("Playwright Chromium detected at:")
            print("  \(cachePath)")
            print("First detection recorded to validation_results audit chain.")
            return
        }

        print("Playwright Chromium already installed at:")
        print("  \(cachePath)")
    }

    // MARK: - --install-egress-ca / --uninstall-egress-ca (Phase T.1d-6)

    /// Injectable trust-install executor seam.
    ///
    /// SECURITY INVARIANT (Schneier): this leg ships NO real-exec
    /// implementation. The ONLY conforming type below is
    /// `DryRunTrustInstallExecutor`, which PRINTS the `security ...`
    /// invocation and RECORDS it but NEVER spawns a process. There is no
    /// code path in this build — not in the CLI, not in tests, not in the
    /// autonomous loop — that runs `security add-trusted-cert` /
    /// `remove-trusted-cert`, sudo, or any mutation of the System Keychain.
    /// The real trust install is a separate gui-human item (t1d-7).
    ///
    /// Default polarity is INVERTED from `ScheduleConfig`'s launchctl seam
    /// (which defaults to real exec): the install/uninstall motions default
    /// to the dry-run recorder, so a caller that forgets to inject simply
    /// gets the print/record executor and CANNOT reach a real `security`
    /// spawn. "Never mutate the System Keychain" is therefore structurally
    /// guaranteed, not merely a convention.
    protocol TrustInstallExecutor: AnyObject {
        /// Print + record the invocation. Implementations MUST NOT spawn a
        /// process.
        func run(_ invocation: [String])
    }

    /// The only executor in this leg: a print-and-record sink. NEVER spawns
    /// `security`. The recorded `invocations` array is the sole place a
    /// trust-install command "goes" — tests assert against it to prove no
    /// process was launched (there is no process-spawn code to reach).
    final class DryRunTrustInstallExecutor: TrustInstallExecutor {
        private(set) var invocations: [[String]] = []
        let silent: Bool
        init(silent: Bool = false) { self.silent = silent }

        func run(_ invocation: [String]) {
            invocations.append(invocation)
            if !silent {
                print("  [dry-run] would run (operator's job, t1d-7 — NOT executed here):")
                print("    " + invocation.joined(separator: " "))
            }
        }
    }

    /// The System trust-store keychain path the operator targets. PRINTED
    /// only — never opened, never written.
    static let systemKeychainPath = "/Library/Keychains/System.keychain"

    /// Build the EXACT `security add-trusted-cert` invocation the operator
    /// would run (with sudo) to add the CA pem as a System trust root. Pure
    /// + static so tests assert the argv without side effects. PRINTED, not
    /// run.
    static func addTrustedCertInvocation(pemPath: String) -> [String] {
        [
            "security", "add-trusted-cert", "-d",
            "-r", "trustRoot",
            "-k", systemKeychainPath,
            pemPath,
        ]
    }

    /// Build the EXACT `security remove-trusted-cert` invocation. PRINTED,
    /// not run.
    static func removeTrustedCertInvocation(pemPath: String) -> [String] {
        ["security", "remove-trusted-cert", "-d", pemPath]
    }

    /// Pure typed-confirm comparison. Extracted so the accept/reject logic
    /// is unit-testable without a tty. Exact-match only (no trim, no
    /// case-fold): the operator must type the expected phrase verbatim.
    static func confirmMatches(input: String?, expected: String) -> Bool {
        input == expected
    }

    /// The fixed confirmation phrase the operator types to authorize the
    /// install motion. A fixed phrase (not a y/N) so muscle-memory can't
    /// bypass the gate — same rationale as `--repair-chain`'s typed asks.
    static let installConfirmPhrase = "INSTALL-EGRESS-CA"

    /// Resolve the CA pem path. Real default is `~/.senkani/egress-ca.pem`
    /// via `MITMCertificateAuthority.Paths.defaultPaths()`; tests inject a
    /// temp-dir path so they NEVER touch `~/.senkani` or the System
    /// Keychain.
    private func defaultCAPaths() -> MITMCertificateAuthority.Paths {
        .defaultPaths()
    }

    /// CLI dispatch wrapper. Generates the CA (real default path) and runs
    /// the testable install motion with the default dry-run executor and a
    /// `readLine`-backed confirm reader.
    private func runInstallEgressCA() throws {
        try Self.installEgressCAMotion(
            caPaths: defaultCAPaths(),
            executor: DryRunTrustInstallExecutor(),
            confirmReader: { readLine() },
            recordAudit: { Self.recordEgressCAInstallAudit() }
        )
    }

    /// CLI dispatch wrapper for the reversible counterpart.
    private func runUninstallEgressCA() throws {
        try Self.uninstallEgressCAMotion(
            caPaths: defaultCAPaths(),
            executor: DryRunTrustInstallExecutor()
        )
    }

    /// Testable install motion (mirrors `runInstallValidationBrowser`'s
    /// PRINT-DON'T-EXECUTE shape). Generates the CA pem via
    /// `MITMCertificateAuthority`, requires the typed-string confirm
    /// (MISMATCH hard-aborts BEFORE any invocation is built or recorded),
    /// then routes the `security add-trusted-cert ...` invocation through
    /// the injected dry-run executor (prints + records, never spawns).
    ///
    /// Returns nothing; the executor's `invocations` is the observable
    /// outcome. `recordAudit` is an optional hook so the CLI can write one
    /// chained `egress.ca.install` audit row while tests pass a no-op.
    static func installEgressCAMotion(
        caPaths: MITMCertificateAuthority.Paths,
        executor: DryRunTrustInstallExecutor,
        confirmReader: () -> String?,
        recordAudit: () -> Void = {}
    ) throws {
        print("Senkani Doctor — install egress CA (DRY RUN scaffolding)")
        print("=======================================================")
        print("")
        print("This will:")
        print("  1. Generate the local MITM egress root CA pem at:")
        print("       \(caPaths.publicCertPEM)")
        print("     (private key, 0600, at \(caPaths.privateKeyPEM))")
        print("  2. PRINT the `security add-trusted-cert ...` command you")
        print("     would run (with sudo) to trust it as a System root.")
        print("")
        print("It will NOT run `security`, NOT sudo, and NOT mutate the")
        print("System Keychain. The real trust install is the operator's")
        print("job (t1d-7, gui-human).")
        print("")

        // Typed-string gate. MISMATCH hard-aborts here — BEFORE the CA is
        // generated and BEFORE any invocation is built or recorded, so a
        // rejected confirm leaves the executor's `invocations` EMPTY.
        print("Type '\(installConfirmPhrase)' to confirm, or anything else to abort:")
        print("> ", terminator: "")
        let typed = confirmReader()
        guard confirmMatches(input: typed, expected: installConfirmPhrase) else {
            print("Aborted (input did not match '\(installConfirmPhrase)'). No CA generated, no command recorded.")
            throw ExitCode.failure
        }

        // Confirm matched — generate the CA pem (writes the public pem +
        // 0600 key to the configured paths; tests pass a temp dir).
        try generateCASync(paths: caPaths)
        print("Generated CA pem at \(caPaths.publicCertPEM)")
        print("")

        // Build + route the invocation through the dry-run executor. This
        // PRINTS and RECORDS — it does not spawn `security`.
        let invocation = addTrustedCertInvocation(pemPath: caPaths.publicCertPEM)
        print("Operator-runnable trust-install command (run yourself, t1d-7):")
        print("  sudo " + invocation.joined(separator: " "))
        print("")
        executor.run(invocation)

        recordAudit()
        print("Done. The CA pem is on disk; the System trust install is NOT")
        print("done — run the command above yourself (t1d-7).")
    }

    /// Testable uninstall motion. Removes the CA pem (if present) and routes
    /// the `security remove-trusted-cert ...` invocation through the dry-run
    /// executor (prints + records, never spawns). No typed-confirm: this is
    /// the safe/reversible direction (it only deletes a local pem and prints
    /// a command).
    static func uninstallEgressCAMotion(
        caPaths: MITMCertificateAuthority.Paths,
        executor: DryRunTrustInstallExecutor
    ) throws {
        print("Senkani Doctor — uninstall egress CA (DRY RUN scaffolding)")
        print("=========================================================")
        print("")

        let fm = FileManager.default
        var removedAny = false
        for path in [caPaths.publicCertPEM, caPaths.privateKeyPEM] {
            if fm.fileExists(atPath: path) {
                try? fm.removeItem(atPath: path)
                print("Removed local CA file: \(path)")
                removedAny = true
            }
        }
        if !removedAny {
            print("No local CA files at \(caPaths.publicCertPEM) — nothing to remove.")
        }
        print("")

        let invocation = removeTrustedCertInvocation(pemPath: caPaths.publicCertPEM)
        print("Operator-runnable trust-removal command (run yourself, t1d-7):")
        print("  sudo " + invocation.joined(separator: " "))
        print("")
        executor.run(invocation)

        print("Done. Local CA files cleared; the System trust REMOVAL is NOT")
        print("done — run the command above yourself (t1d-7).")
    }

    /// Synchronously ensure the CA at `paths` exists on disk (generate if
    /// missing, else load + validate) from the sync `ParsableCommand.run()`.
    ///
    /// phase-t1d-6 P0 fix: this no longer bridges through a
    /// `DispatchSemaphore`-over-`Task`. `MITMCertificateAuthority.ensureRoot()`
    /// is genuinely synchronous (its `await` was a pure actor-isolation hop, no
    /// suspension point), so the CA is now minted/persisted by an actor-
    /// nonisolated static (`ensureRootOnDisk`) entirely on the calling thread —
    /// no Task, no semaphore, no cooperative-pool dependency. The old bridge
    /// deadlocked a full `swift test` run under cooperative-pool saturation
    /// (stack-sampled to dispatch_semaphore_wait at
    /// DoctorEgressCACommandTests.swift:93). Rethrows the authority's error.
    static func generateCASync(paths: MITMCertificateAuthority.Paths) throws {
        try MITMCertificateAuthority.ensureRootOnDisk(paths: paths)
    }

    /// Optionally write one chained `egress.ca.install` audit row (mirrors
    /// `runInstallValidationBrowser`'s single-row write). Idempotency is not
    /// required for this leg — re-running install regenerates the CA, so a
    /// fresh row per invocation is acceptable.
    private static func recordEgressCAInstallAudit() {
        SessionDatabase.shared.recordTokenEvent(
            sessionId: "doctor",
            paneId: nil,
            projectRoot: nil,
            source: "doctor",
            toolName: nil,
            model: nil,
            inputTokens: 0,
            outputTokens: 0,
            savedTokens: 0,
            costCents: 0,
            feature: "egress.ca.install",
            command: nil
        )
        SessionDatabase.shared.flushWrites()
    }

    // MARK: - --repair-chain (Phase T.5 round 4)

    private func runRepairChain() throws {
        let supportedList = ChainRepairer.supportedTables.sorted().joined(separator: "|")
        guard let table else {
            FileHandle.standardError.write(Data("error: --repair-chain requires --table <\(supportedList)>\n".utf8))
            throw ExitCode.failure
        }
        guard let fromRowid else {
            FileHandle.standardError.write(Data("error: --repair-chain requires --from-rowid <N>\n".utf8))
            throw ExitCode.failure
        }
        guard ChainRepairer.supportedTables.contains(table) else {
            let listText = ChainRepairer.supportedTables.sorted().joined(separator: ", ")
            FileHandle.standardError.write(Data("error: --table '\(table)' is not supported. Supported: \(listText)\n".utf8))
            throw ExitCode.failure
        }

        // Tty enforcement: refuse to run interactively when stdin isn't a
        // tty unless --force is passed. This is the load-bearing security
        // gate Schneier called for during the round audit — a non-tty
        // invocation might be a script bypassing the typed-string confirm.
        let stdinIsTTY = isatty(fileno(stdin)) == 1
        if !stdinIsTTY && !force {
            FileHandle.standardError.write(Data("""
                error: --repair-chain refuses non-tty invocations without --force.
                       Run interactively, or pass --force to indicate you've reviewed
                       the operation in a script.
                """.utf8))
            throw ExitCode.failure
        }

        // Three-phase prompt (Norman): explain, confirm typed string, show
        // diff, confirm second typed string. The two typed-string asks are
        // 'REPAIR' then '<table>' so muscle-memory y/N can't bypass them.
        printRepairExplanation(table: table, fromRowid: fromRowid)

        if !force {
            print("Type 'REPAIR' to confirm the operation, or anything else to abort:")
            print("> ", terminator: "")
            let line1 = readLine() ?? ""
            guard line1 == "REPAIR" else {
                print("Aborted (input was not 'REPAIR').")
                throw ExitCode.failure
            }

            print("Type '\(table)' to confirm the affected table, or anything else to abort:")
            print("> ", terminator: "")
            let line2 = readLine() ?? ""
            guard line2 == table else {
                print("Aborted (input was not '\(table)').")
                throw ExitCode.failure
            }
        }

        let outcome: ChainRepairer.RepairOutcome
        do {
            outcome = try SessionDatabase.shared.repairChain(
                table: table,
                fromRowid: fromRowid,
                operatorNote: note,
                force: force
            )
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            throw ExitCode.failure
        }

        let priorTip = outcome.priorTipHash.map { String($0.prefix(16)) + "…" } ?? "<empty>"
        print("""
        Repair complete.
          Table:        \(outcome.table)
          From rowid:   \(outcome.fromRowid)
          New anchor:   \(outcome.newAnchorId)
          Prior tip:    \(priorTip)
          Rows rebound: \(outcome.rowsRebound)
        Run `senkani doctor --verify-chain` to confirm both segments verify.
        """)
    }

    private func printRepairExplanation(table: String, fromRowid: Int64) {
        print("""
        Senkani Doctor — chain repair

        You are about to OPEN A NEW AUDIT-CHAIN SEGMENT for the table:
            \(table)
        starting at rowid >= \(fromRowid).

        What this does:
          1. Inserts a new row in `chain_anchors` with reason=`repair-\(fromRowid)`.
             The new anchor's `operator_note` records the prior chain's tip hash
             so a third party can audit the cryptographic linkage.
          2. Re-binds every row with id >= \(fromRowid) in `\(table)` to the new
             anchor and CLEARS its prev_hash + entry_hash.
          3. The next insert into `\(table)` starts a fresh chain under the new
             anchor. Pre-repair rows continue to verify against the prior anchor;
             the repair count surfaces in `senkani doctor --verify-chain`.

        What this does NOT do:
          - It does not delete the prior chain. Pre-repair rows verify
            independently against the prior anchor's tip.
          - It does not retroactively re-hash the rebound rows. They become
            anchor-from-now under the new anchor.

        This is an admin operation. After you confirm, the change is logged in
        the new chain segment itself (the repair is auditable).
        """)
        if !force {
            print("\nThis prompt requires TWO typed-string confirmations to proceed.\n")
        } else {
            print("\n--force is set — proceeding without typed-string confirms.\n")
        }
    }

    // Numbering note: `// MARK: - Check N` headers are STABLE IDs, assigned
    // in creation order and never renumbered, so they appear out of order in
    // this file and deliberately differ from the DISPATCH RUN-ORDER `// N.`
    // comments in `run()` above (e.g. this check is run-order 16 but stable
    // Check 15). Neither number reaches operator output — `printStatus`
    // emits descriptive text and run()'s summary counts by
    // pass/fail/fixed/skip, not by check number. Do NOT reconcile the two
    // schemes. Matching note lives at the top of `run()`'s check sequence.

    // MARK: - Check 15: Audit chain integrity (Phase T.5)

    /// Display order for the chain-audit per-table walk. Single source of
    /// truth shared with the summary line below and with tests asserting
    /// on the doctor surface. Adding a chain participant requires
    /// extending this array AND `ChainVerifier.verifyAll`'s switch.
    static let chainAuditOrder: [String] = [
        "token_events", "validation_results", "sandboxed_results",
        "commands", "pane_refresh_state", "policy_snapshots",
        "confirmations", "trust_audits", "egress_decisions",
        "pack_audits", "eval_results", "surrogate_writes",
        "workstream_handoffs", "openai_request_log",
        "thread_handoff_event"
    ]

    private static let chainAuditSummaryNames: String =
        chainAuditOrder.joined(separator: " / ")

    /// Pure formatter for the audit-chain check. Returns the
    /// `(Status, message)` lines the doctor surface emits, plus
    /// `anyBroken` so the caller can short-circuit the summary line.
    /// Lifted out of `checkAuditChain` so tests can assert on doctor
    /// output without dup2-capturing stdout.
    static func formatChainAuditLines(
        perTable: [String: ChainVerifier.Result],
        totalRepairs: Int
    ) -> (lines: [(Status, String)], anyBroken: Bool) {
        var lines: [(Status, String)] = []
        var anyBroken = false
        var earliestStart: Date?

        for table in chainAuditOrder {
            guard let result = perTable[table] else { continue }
            switch result {
            case .ok(let startedAt, _):
                if let s = startedAt {
                    if let cur = earliestStart {
                        if s < cur { earliestStart = s }
                    } else {
                        earliestStart = s
                    }
                }
            case .brokenAt(_, let rowid, let expected, let actual):
                lines.append((
                    .fail,
                    "chain integrity (\(table)): BROKEN at row \(rowid) — expected \(expected.prefix(16))…, got \(actual.prefix(16))…"
                ))
                anyBroken = true
            case .noChain:
                continue
            }
        }

        if anyBroken {
            return (lines, true)
        }

        if earliestStart == nil {
            lines.append((.skip, "chain integrity: no chain anchors yet (fresh DB)"))
        } else {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withFullDate]
            let since = " since \(fmt.string(from: earliestStart!))"
            lines.append((
                .pass,
                "chain integrity: OK across \(chainAuditSummaryNames)\(since) / \(totalRepairs) repairs"
            ))
        }
        return (lines, false)
    }

    private func checkAuditChain(_ results: inout Results) {
        // T.5 round 3: verify all chain-anchored tables. Surface a per-
        // table line so the operator sees where a tamper happened, plus
        // a summary line.
        // T.5 round 4: total repair count comes from the central
        // SessionDatabase API so the summary is consistent across CLI
        // invocations even if a verification produced .noChain (no anchor
        // start date) but repairs still exist.
        let database = SessionDatabase.shared
        let perTable = ChainVerifier.verifyAll(database)
        let totalRepairs = database.totalRepairCount()
        let (lines, _) = Self.formatChainAuditLines(
            perTable: perTable, totalRepairs: totalRepairs
        )
        for (status, message) in lines {
            printStatus(status, message)
            switch status {
            case .pass: results.passed += 1
            case .fixed: results.fixed += 1
            case .fail: results.failed += 1
            case .skip: results.skipped += 1
            }
        }
    }

    // MARK: - Check 21: Session work bus (Phase U.9a)

    /// Surface the U.9a queue + stream diagnostics: pending/processing/
    /// dead-letter row counts, active leases, retried total, by-kind
    /// rollup, and per-consumer lag against `session_event_stream`.
    /// All non-blocking informational lines — `senkani doctor` exit
    /// code stays 0 regardless of bus state in U.9a (substrate-only).
    private func checkSessionWorkBus(_ results: inout Results) {
        let q = SessionDatabase.shared.sessionWorkQueueStore.diagnostics()
        let kinds = q.byKind.isEmpty
            ? "none"
            : q.byKind.sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        printStatus(.pass, "session work queue — pending: \(q.pending) | processing: \(q.processing) | succeeded: \(q.succeeded) | dead_letter: \(q.deadLetter) | active_leases: \(q.activeLeases) | retried_total: \(q.retriedTotal) | by_kind: \(kinds)")
        results.passed += 1

        let stream = SessionDatabase.shared.sessionEventStreamStore
        let consumers = stream?.allConsumerIds() ?? []
        for cid in consumers {
            let lag = stream?.lag(consumerId: cid) ?? 0
            printStatus(.pass, "session event stream consumer '\(cid)' — lag: \(lag) rows")
            results.passed += 1
        }

        let cfg = (try? WorkBusConfigStore.load()) ?? WorkBusConfig()
        printStatus(.pass, "work-bus config — dual_write: \(cfg.dualWrite)")
        results.passed += 1
    }

    // MARK: - Check 17: Trust flags (Phase U.4a)

    /// Surface the rolling 30-day soft-flag count + confirmed FP/TP
    /// totals. U.4a is non-blocking — the counter is informational
    /// only. U.4b promotes the FP rate to a release gate once the
    /// operator has labelled enough samples.
    private func checkTrustFlags(_ results: inout Results) {
        let stats = SessionDatabase.shared.trustFlagStatsLast30Days()
        printStatus(.pass, "trust flags — \(stats.doctorLine)")
        results.passed += 1

        // U.4b-1 — surface the operator-flippable trust mode plus a
        // gap-to-promotion readout (observed FP-rate vs configured
        // threshold + observed sample vs configured min). Defaults to
        // the fresh-install posture when the settings file is missing.
        let settings = (try? TrustSettingsStore.load()) ?? TrustSettings()
        let observedRate = PromotionGate.observedRate(fp: stats.confirmedFP, tp: stats.confirmedTP)
        let observedSample = stats.confirmedFP + stats.confirmedTP
        let rateStr = observedRate.map { String(format: "%.3f", $0) } ?? "n/a"
        let rateMaxStr = settings.fpRateMax.map { String(format: "%.3f", $0) } ?? "<unset>"
        let minSampleStr = settings.minLabeledSample.map(String.init) ?? "<unset>"
        printStatus(.pass, "trust mode: \(settings.mode.rawValue) — observed_rate: \(rateStr) / max: \(rateMaxStr) — sample: \(observedSample) / min: \(minSampleStr)")
        results.passed += 1
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

    // MARK: - Check 5b: ML Tier Quality

    /// Read the cached `ml-tier-eval.json` report and surface a per-tier
    /// quality rating. Degraded tiers emit a warning so 8 GB Mac users
    /// know the lower tier is materially worse before they're routed to it.
    private func checkMLTierQuality(_ results: inout Results) {
        guard let report = MLTierEvalReportStore.load() else {
            printStatus(.skip, "ML tier quality: no eval cached (run `senkani ml-eval` to populate)")
            results.skipped += 1
            return
        }

        let installedIds = Set(ModelManager.shared.models
            .filter { $0.status == .verified || $0.status == .downloaded }
            .map(\.id))

        let installedTiers = report.tiers.filter { installedIds.contains($0.tierId) }

        if installedTiers.isEmpty {
            printStatus(.skip, "ML tier quality: no Gemma tiers installed yet")
            results.skipped += 1
            return
        }

        for tier in installedTiers {
            let label = mlTierLine(tier)
            switch tier.rating {
            case .excellent, .acceptable:
                printStatus(.pass, label)
                results.passed += 1
            case .degraded:
                printStatus(.fail, label + " — consider upgrading to a larger tier if RAM allows")
                results.failed += 1
            case .notEvaluated:
                printStatus(.skip, label)
                results.skipped += 1
            }
        }
    }

    private func mlTierLine(_ r: MLTierEvalResult) -> String {
        let head = "ml.tier.\(r.tierId): \(r.rating.rawValue)"
        switch r.rating {
        case .notEvaluated:
            let why = r.skipReason.map { " — \($0)" } ?? ""
            return "\(head)\(why)"
        case .excellent, .acceptable, .degraded:
            let pct = Int((r.passRate * 100).rounded())
            return String(
                format: "%@ (%d/%d, %d%% pass, median %dms, %d output tok)",
                head, r.passed, r.total, pct,
                Int(r.medianLatencyMs.rounded()), r.totalOutputTokens
            )
        }
    }

    // MARK: - Check 5c: PIIClassifier Layer 3 (T.2b-1)

    /// Outcome of the Layer 3 smoke probe — used by the pure formatter
    /// so tests can drive all four branches without touching the live
    /// `Layer3Inference.productionDefault` (which always throws
    /// BackendNotReadyError until T.2a-followup ships inference wiring).
    enum Layer3SmokeOutcome {
        case success
        case backendNotReady
        case unexpectedError(String)
    }

    /// Single-line formatter — kept for tests that exercise the
    /// Layer 3 status line in isolation. Production now calls
    /// `formatLayer3PIIClassifierLines` (plural) so the T.2b-2
    /// commit-sha + last-eval lines surface alongside.
    ///
    /// Schneier (silent-degradation visibility): the backend-not-ready
    /// branch is an EXPLICIT line, not a silent skip. Operators see
    /// the gating in doctor output, not just at log time.
    static func formatLayer3PIIClassifierLine(
        status: ModelStatus?,
        smoke: () -> Layer3SmokeOutcome,
        lastError: String? = nil
    ) -> (Status, String) {
        guard let status else {
            return (.skip, "Layer 3 PII classifier: model id '\(PIIClassifierAdapter.modelId)' not registered")
        }
        switch status {
        case .available:
            return (.skip, "Layer 3 PII classifier: not pulled (regex+entropy active)")
        case .verified:
            switch smoke() {
            case .success:
                return (.pass, "Layer 3 PII classifier: available")
            case .backendNotReady:
                return (.skip, "Layer 3 PII classifier: backend not ready (T.2a-followup not yet wired)")
            case .unexpectedError(let detail):
                return (.fail, "Layer 3 PII classifier: smoke probe failed — \(detail)")
            }
        case .broken, .error:
            let why = lastError.map { " — \($0)" } ?? ""
            return (.fail, "Layer 3 PII classifier: verification failed\(why)")
        case .downloading, .downloaded, .verifying:
            return (.skip, "Layer 3 PII classifier: \(status.rawValue)")
        }
    }

    /// Three-line formatter (T.2b-2 extension). Returns the Layer 3
    /// status line (always) plus the model-id-plus-commit-sha line
    /// AND the last-eval line whenever the classifier is `.verified`.
    /// The two extra lines are NOT emitted for non-verified states
    /// (regex+entropy or downloading paths) — there's nothing
    /// meaningful to surface yet.
    static func formatLayer3PIIClassifierLines(
        status: ModelStatus?,
        smoke: () -> Layer3SmokeOutcome,
        lastError: String? = nil,
        localCommitSha: String? = nil,
        lastEval: (timestamp: Date, f1: Double)? = nil
    ) -> [(Status, String)] {
        let primary = formatLayer3PIIClassifierLine(
            status: status,
            smoke: smoke,
            lastError: lastError
        )
        guard status == .verified else { return [primary] }

        let sha = localCommitSha.map { String($0.prefix(12)) } ?? "unknown"
        let modelLine: (Status, String) = (
            localCommitSha == nil ? .skip : .pass,
            "Layer 3 classifier model: \(PIIClassifierAdapter.modelId) @ \(sha)"
        )

        let evalLine: (Status, String)
        if let lastEval {
            let band = PIIClassifierEvalGate.bandLabel(
                for: PIIClassifierEvalGate.f1Status(lastEval.f1)
            )
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let ts = formatter.string(from: lastEval.timestamp)
            let status: Status
            switch PIIClassifierEvalGate.f1Status(lastEval.f1) {
            case .clean: status = .pass
            case .warn: status = .fail
            case .abort: status = .fail
            }
            evalLine = (
                status,
                String(format: "Layer 3 last eval: %@ — F1 %.3f (%@)", ts, lastEval.f1, band)
            )
        } else {
            evalLine = (.skip, "Layer 3 last eval: never run")
        }

        return [primary, modelLine, evalLine]
    }

    /// Thin wrapper. Reads the live `ModelManager` + smokes the
    /// production `Layer3Inference.productionDefault` + pulls the
    /// last eval row from the shared `SessionDatabase`.
    private func checkPIIClassifierLayer3(_ results: inout Results) {
        let info = ModelManager.shared.models.first(where: { $0.id == PIIClassifierAdapter.modelId })
        let latest = SessionDatabase.shared.latestEvalResult(modelId: PIIClassifierAdapter.modelId)
        let lastEvalTuple: (timestamp: Date, f1: Double)? = latest.map {
            (timestamp: $0.timestamp, f1: $0.f1)
        }
        let lines = Self.formatLayer3PIIClassifierLines(
            status: info?.status,
            smoke: {
                do {
                    _ = try Layer3Inference.productionDefault.detectSpans("ping", 0.85)
                    return .success
                } catch is PIIClassifierAdapter.BackendNotReadyError {
                    return .backendNotReady
                } catch {
                    return .unexpectedError(String(describing: error))
                }
            },
            lastError: info?.lastError,
            localCommitSha: nil,  // populated by T.2a-followup
            lastEval: lastEvalTuple
        )
        for (status, message) in lines {
            printStatus(status, message)
            switch status {
            case .pass: results.passed += 1
            case .skip: results.skipped += 1
            case .fail: results.failed += 1
            case .fixed: results.fixed += 1
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

    // MARK: - Check 14: SLOs

    /// Render one line per published SLO with the rolling 24-hour p99
    /// and a green / warn / burn / unknown verdict. See `spec/slos.md`
    /// for the contract; `Core/SLO.swift` for the math.
    private func checkSLOs(_ results: inout Results) {
        for evaluation in SLOSampleStore.shared.evaluateAll() {
            let label = sloLine(evaluation)
            switch evaluation.state {
            case .green:
                printStatus(.pass, label)
                results.passed += 1
            case .warn:
                printStatus(.fail, label + " — within 80% of threshold; investigate before it burns")
                results.failed += 1
            case .burn:
                printStatus(.fail, label + " — SLO BURNING; p99 over threshold or >1% over budget")
                results.failed += 1
            case .unknown:
                printStatus(.skip, label + " — fewer than \(SLOSampleStore.minSamples) samples in window")
                results.skipped += 1
            }
        }
    }

    private func sloLine(_ e: SLOEvaluation) -> String {
        let head = "SLO \(e.slo.rawValue): \(e.state.rawValue)"
        if e.state == .unknown {
            return "\(head) (\(e.sampleCount) samples, threshold \(formatMs(e.slo.thresholdMs)))"
        }
        return String(
            format: "%@ — p99 %@ (threshold %@, %d samples, %.2f%% over)",
            head, formatMs(e.p99Ms), formatMs(e.slo.thresholdMs),
            e.sampleCount, e.overBudgetPct
        )
    }

    private func formatMs(_ ms: Double) -> String {
        if ms < 10 { return String(format: "%.2fms", ms) }
        return String(format: "%.0fms", ms)
    }

    // MARK: - Check 22: Release commitments (Phase V.14)

    private func checkReleaseSLOs(_ results: inout Results) {
        let history = ReleaseSLOHistory.shared
        let evaluations = history.evaluateAll()

        // Surface as one labelled block; aggregate verdict drives one
        // pass/skip/fail counter so this check doesn't quadruple-count
        // on the doctor summary line.
        let allNoHistory = evaluations.allSatisfy { $0.verdict == .noHistory }
        if allNoHistory {
            printStatus(.skip,
                "Release commitments: n/a — run tools/measure-slos.sh to populate "
                + history.historyPath)
            results.skipped += 1
            return
        }

        let anyFailing = evaluations.contains { e in
            e.verdict == .overBudget || e.verdict == .regression
        }

        if anyFailing {
            printStatus(.fail, "Release commitments (Phase V.14):")
            results.failed += 1
        } else {
            printStatus(.pass, "Release commitments (Phase V.14):")
            results.passed += 1
        }

        for evaluation in evaluations {
            print("    " + releaseSLOLine(evaluation))
        }
    }

    private func releaseSLOLine(_ e: ReleaseSLOEvaluation) -> String {
        let head = "  \(e.slo.rawValue) (\(e.slo.thresholdLabel))"
        switch e.verdict {
        case .noHistory:
            return "\(head): n/a — no history yet"
        case .missing:
            let why = e.missingReason ?? "not captured"
            return "\(head): n/a — \(why)"
        case .ok:
            return "\(head): \(formatReleaseValue(e.latest, unit: e.slo.unit))"
                + baselineSuffix(e)
        case .regression:
            return "\(head): \(formatReleaseValue(e.latest, unit: e.slo.unit))"
                + baselineSuffix(e) + " — REGRESSION (≥10% over baseline)"
        case .overBudget:
            return "\(head): \(formatReleaseValue(e.latest, unit: e.slo.unit))"
                + baselineSuffix(e) + " — OVER BUDGET"
        }
    }

    private func formatReleaseValue(_ v: Double?, unit: String) -> String {
        guard let v else { return "n/a" }
        if unit == "ms" {
            if v < 10 { return String(format: "%.2f ms", v) }
            return String(format: "%.0f ms", v)
        }
        return String(format: "%.1f %@", v, unit)
    }

    private func baselineSuffix(_ e: ReleaseSLOEvaluation) -> String {
        guard let baseline = e.baseline, let pct = e.percentOverBaseline else {
            return " (no baseline yet)"
        }
        let sign = pct >= 0 ? "+" : ""
        return String(
            format: " (baseline %@, %@%.1f%%)",
            formatReleaseValue(baseline, unit: e.slo.unit), sign, pct
        )
    }

    // MARK: - Output Helpers

    enum Status {
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

    // MARK: - Check 19: FileProvider eviction risk

    /// Pure formatter for the FileProvider eviction check. Lifted out
    /// of `checkFileProviderEviction` so tests can synthesize reports
    /// (the `SF_DATALESS` flag is FileProvider-only and cannot be set
    /// from user space) and assert on the operator-facing surface
    /// without dup2-capturing stdout. Mirror of `formatChainAuditLines`.
    static func formatFileProviderEvictionLines(
        _ report: FileProviderEvictionReport
    ) -> [(Status, String)] {
        if !report.hasFinding {
            return [(.pass, "FileProvider: no iCloud-Drive eviction symptoms (root, .build/checkouts/, source tree clean)")]
        }
        var lines: [(Status, String)] = []
        if report.pathUnderFileProvider {
            lines.append((
                .fail,
                "FileProvider eviction risk — \(report.scannedRoot) sits under an iCloud-Drive-managed path. See CONTRIBUTING.md `## macOS / iCloud Drive` for the disable-Desktop-&-Documents-sync remediation."
            ))
        }
        if !report.datalessPaths.isEmpty {
            let n = report.datalessPaths.count
            let sample = report.datalessPaths.prefix(3).joined(separator: ", ")
            let plural = n == 1 ? "" : "s"
            lines.append((
                .fail,
                "FileProvider eviction — \(n) dataless-flagged file\(plural) under \(report.scannedRoot)/.build/ (sample: \(sample)). After disabling iCloud Desktop & Documents sync, run `rm -rf .build`; rebuild from a clean tree."
            ))
        }
        if !report.star2Siblings.isEmpty {
            let n = report.star2Siblings.count
            let sample = report.star2Siblings.prefix(3).joined(separator: ", ")
            let plural = n == 1 ? "" : "s"
            lines.append((
                .fail,
                "FileProvider eviction — \(n) `* 2` Finder-shadow sibling\(plural) detected (sample: \(sample)). Each is an iCloud sync conflict; verify byte-identity with `cmp` before removing the shadows."
            ))
        }
        return lines
    }

    private func checkFileProviderEviction(_ results: inout Results) {
        let cwd = FileManager.default.currentDirectoryPath
        let report = FileProviderEvictionScanner.scan(root: cwd)
        for (status, message) in Self.formatFileProviderEvictionLines(report) {
            printStatus(status, message)
            switch status {
            case .pass: results.passed += 1
            case .fixed: results.fixed += 1
            case .fail: results.failed += 1
            case .skip: results.skipped += 1
            }
        }
    }

    // MARK: - Check 20: Walk-bundle staleness

    /// Pure formatter for the bundle-staleness check.
    ///
    /// Shape (`.stale`):
    ///   ✗ Bundle staleness — <bundle> is older than HEAD (<ref>)
    ///     bundle: <yyyy-MM-dd HH:mm:ss> | HEAD: <yyyy-MM-dd HH:mm:ss> [— <subject>]
    ///     recommended: `senkani walk rebuild-bundle <bundle>` (or rely on auto-rebuild)
    static func formatBundleStalenessLines(
        _ report: BundleStalenessReport,
        mergeTarget: String
    ) -> [(Status, String)] {
        switch report.verdict {
        case .fresh:
            return [(.pass, "Bundle staleness: \(report.bundlePath) is up-to-date with \(mergeTarget) HEAD")]
        case .notApplicable:
            let reason = report.notApplicableReason ?? "not applicable"
            return [(.skip, "Bundle staleness: skipped (\(reason))")]
        case .stale:
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let bundleStr = report.binaryMtime.map { fmt.string(from: $0) } ?? "?"
            let headStr = report.headCommitTime.map { fmt.string(from: $0) } ?? "?"
            let subject = report.headCommitSubject.map { " — \($0)" } ?? ""
            return [
                (.fail, "Bundle staleness — \(report.bundlePath) is older than \(mergeTarget) HEAD"),
                (.fail, "  bundle: \(bundleStr) | HEAD: \(headStr)\(subject)"),
                (.fail, "  recommended: `senkani walk rebuild-bundle \(report.bundlePath)` (or rely on auto-rebuild)"),
            ]
        }
    }

    private func checkBundleStaleness(_ results: inout Results) {
        let projectRoot = FileManager.default.currentDirectoryPath
        guard let bundlePath = BundleStalenessScanner.discoverBundlePath(
            projectRoot: projectRoot
        ) else {
            // Silent skip — no walk bundle present, so the check is
            // irrelevant. Don't bump the skipped counter (the doctor
            // surface already has many "X: not running" skips; this
            // one is too niche to surface for non-walk runs).
            return
        }
        let mergeTarget = BundleStalenessScanner.resolveMergeTarget(
            projectRoot: projectRoot
        )
        let headCt = BundleStalenessScanner.headCommitTime(
            projectRoot: projectRoot, ref: mergeTarget
        )
        let headSubject = BundleStalenessScanner.headCommitSubject(
            projectRoot: projectRoot, ref: mergeTarget
        )
        let report = BundleStalenessScanner.scan(
            bundlePath: bundlePath,
            headCommitTime: headCt,
            headCommitSubject: headSubject
        )
        for (status, message) in Self.formatBundleStalenessLines(
            report, mergeTarget: mergeTarget
        ) {
            printStatus(status, message)
            switch status {
            case .pass: results.passed += 1
            case .fixed: results.fixed += 1
            case .fail: results.failed += 1
            case .skip: results.skipped += 1
            }
        }
        // Auto-rebuild on stale unless opted out. The print line is the
        // operator-visible signal that doctor is about to invoke a side
        // effect; --no-rebuild-stale-bundle reverses the default.
        guard report.verdict == .stale else { return }
        if noRebuildStaleBundle {
            printStatus(.skip, "Bundle staleness: --no-rebuild-stale-bundle set; skipping auto-rebuild.")
            return
        }
        printStatus(.fixed, "Bundle staleness: rebuilding via shared helper...")
        do {
            try BundleRebuilder.rebuild(
                bundlePath: bundlePath,
                projectRoot: projectRoot
            ) { print("  \($0)") }
            // Re-balance counters: the .fail lines from the report
            // tripped results.failed by 3; the rebuild succeeded, so
            // demote those to fixed.
            results.failed -= 3
            results.fixed += 3
            printStatus(.fixed, "Bundle staleness: bundle refreshed.")
        } catch {
            printStatus(.fail, "Bundle staleness: rebuild failed — \(error)")
            results.failed += 1
        }
    }

    // MARK: - Check 18: Egress proxy (Phase T.1a)

    // MARK: - --check-egress (T.1c)

    /// 5-scenario adversarial smoke subset: 1 from each of the 5
    /// behavioural categories that the 20-scenario corpus (under
    /// `Tests/SenkaniTests/EgressProxyAdversarialTests.swift`) covers.
    /// Pure rule-engine + normalizer assertions — no live listener,
    /// no SQLite writes, no judge inference. Wall-clock <2 s.
    ///
    /// Schneier P0: each scenario constructs a representative rule set
    /// and a single attacker-controlled host; asserts the engine
    /// returns the expected decision + rule_id. A failure here means
    /// the corpus contract drifted from the engine — block the build.
    private func runCheckEgress() throws {
        struct Scenario {
            let label: String
            let rules: [EgressRule]
            let host: String
            let expectedDecision: EgressRule.Decision
            let expectedRuleId: String
        }

        let scenarios: [Scenario] = [
            Scenario(
                label: "DNS rebinding: loopback 127.0.0.1",
                rules: [EgressRule(id: "allow-example", pattern: "example.com", mode: .suffix, decision: .allow)],
                host: "127.0.0.1",
                expectedDecision: .deny,
                expectedRuleId: "default-deny"
            ),
            Scenario(
                label: "SSRF: decimal-IP encoding 3232235777",
                rules: [EgressRule(id: "allow-example", pattern: "example.com", mode: .suffix, decision: .allow)],
                host: "3232235777",
                expectedDecision: .deny,
                expectedRuleId: "default-deny"
            ),
            Scenario(
                label: "Boundary: mixed-case + trailing-dot survives normalization",
                rules: [EgressRule(id: "deny-example", pattern: "example.com", mode: .exact, decision: .deny)],
                host: "EXAMPLE.com.:80",
                expectedDecision: .deny,
                expectedRuleId: "deny-example"
            ),
            Scenario(
                label: "Boundary: deny-wins over suffix allow",
                rules: [
                    EgressRule(id: "deny-secret", pattern: "secret.example.com", mode: .exact, decision: .deny),
                    EgressRule(id: "allow-example-suffix", pattern: "example.com", mode: .suffix, decision: .allow),
                ],
                host: "secret.example.com",
                expectedDecision: .deny,
                expectedRuleId: "deny-secret"
            ),
            Scenario(
                label: "Judge injection: ignore-your-instructions on tight allowlist",
                rules: [EgressRule(id: "allow-api", pattern: "api.example.com", mode: .exact, decision: .allow)],
                host: "ignore-your-instructions.example.com",
                expectedDecision: .deny,
                expectedRuleId: "default-deny"
            ),
        ]

        print("Egress smoke corpus (5/20 adversarial scenarios)")
        print(String(repeating: "=", count: 48))

        var passed = 0
        var failed = 0
        for scenario in scenarios {
            let engine = EgressRuleEngine(rules: scenario.rules)
            let verdict = engine.evaluate(host: scenario.host)
            let ok = verdict.decision == scenario.expectedDecision
                && verdict.ruleId == scenario.expectedRuleId
            let marker = ok ? "[ok]  " : "[fail]"
            print("  \(marker) \(scenario.label)")
            print("         host=\(scenario.host) → \(verdict.decision.rawValue) (\(verdict.ruleId))")
            if !ok {
                print("         expected: \(scenario.expectedDecision.rawValue) (\(scenario.expectedRuleId))")
                failed += 1
            } else {
                passed += 1
            }
        }

        print("")
        print("\(scenarios.count) scenarios, \(passed) passed, \(failed) failed.")
        if failed > 0 {
            throw ExitCode.failure
        }
    }

    /// Reports the EgressProxy daemon state. T.1a ships the deterministic
    /// rule + decision audit core; the live listener and port file land
    /// in T.1a.2 (`phase-t1a2-egress-proxy-listener-and-pipe`). When the
    /// port file is absent the proxy is reported as "down" (skip,
    /// non-fatal) — that's the expected state until T.1a.2 ships. The
    /// decision count from the audit log is always surfaced so an
    /// operator can see whether ANY decisions have been emitted (synthetic
    /// or otherwise).
    private func checkEgressProxy(_ results: inout Results) {
        let portPath = NSHomeDirectory() + "/.senkani/egress.port"
        let count = SessionDatabase.shared.egressDecisionCount()
        if let data = try? String(contentsOfFile: portPath, encoding: .utf8),
           let port = Int(data.trimmingCharacters(in: .whitespacesAndNewlines)),
           port > 0 {
            printStatus(.pass, "Egress proxy: running on :\(port) (decisions: \(count))")
            results.passed += 1
        } else {
            printStatus(.skip, "Egress proxy: down (decisions: \(count))")
            results.skipped += 1
        }
    }

    /// V.13b-4b (Option B) — surface whether the operator has authorized
    /// `api.anthropic.com` egress (required to serve the Claude-API arm).
    /// Informational only: deny-on-miss is the default and senkani never
    /// auto-adds the rule — this points the operator at the one-line
    /// `egress-policy.json` edit when it is absent, and confirms it when
    /// present. Reuses the same `EgressPolicy.serveEgressAllowHint` seam
    /// the serve-startup hint (b-4c) will use.
    private func checkAnthropicEgressAllowRule(_ results: inout Results) {
        let policyPath = NSHomeDirectory() + "/.senkani/egress-policy.json"
        let (policy, _) = EgressPolicy.load(from: policyPath)
        if let hint = policy.serveEgressAllowHint() {
            printStatus(.skip, "Anthropic serve egress: \(hint)")
            results.skipped += 1
        } else {
            printStatus(.pass, "Anthropic serve egress: api.anthropic.com allowed under serve (general) mode")
            results.passed += 1
        }
    }

    /// V.13b-4c — result type returned by `listAnthropicVaultLabels`.
    /// Schneier P2 (perm-denied conflation, timeout-as-empty): distinct
    /// cases let the formatter render distinct operator-facing messages
    /// for each fault class, instead of collapsing every failure mode
    /// into "unprovisioned".
    ///
    /// - `.ok(VaultLabels)`: vault query returned (possibly zero labels).
    /// - `.timedOut`: the 5s semaphore ceiling elapsed before the
    ///   background Task signaled. Distinct from `.ok([])` so the
    ///   formatter can render `"Keychain query timed out"` rather than
    ///   `"no labels provisioned"`.
    /// - `.permissionDenied(Error)`: the underlying Keychain store threw
    ///   with an OSStatus that indicates a locked / permission-denied
    ///   state (`errSecAuthFailed`, `errSecInteractionNotAllowed`,
    ///   `errSecUserCanceled`, `errSecAuthFailed`-class). Distinct from
    ///   `.otherFailure` so the formatter can render a "re-run after
    ///   unlocking the login Keychain" hint.
    /// - `.otherFailure(Error)`: any other thrown error from the vault
    ///   layer (corrupted item, future broker-store I/O, etc.).
    enum KeychainVaultLookupResult: Sendable {
        case ok(VaultLabels)
        case timedOut
        case permissionDenied(Error)
        case otherFailure(Error)
    }

    /// V.13b-5 — pure formatter for the Anthropic vault-labels check.
    /// Returns `(Status, message)` for the doctor surface. Lifted out of
    /// `checkAnthropicVaultLabels` so the unit test can assert on the
    /// operator-facing line directly (mirror of `formatOpenAIEndpointLine`
    /// / `formatChainAuditLines`).
    ///
    /// **Schneier (no-secret-on-stdout):** input is a `VaultLabels` of
    /// LABELS — there is no parameter shape by which a raw API key could
    /// reach this formatter. The vault layer (`CredentialVault.list(scope:)`)
    /// returns label keys only; the raw key material lives in the value
    /// payload that this formatter never sees. V.13b-4c made the no-secret
    /// guarantee type-level via the `VaultLabels` wrapper — a future
    /// refactor that swapped the inner element type would fail to
    /// compile here.
    ///
    /// V.13b-4c (Schneier P2): distinct messages per failure class.
    ///
    /// - `.ok` zero labels → `.skip` with the operator-actionable
    ///   `senkani vault add anthropic-key --label <name>` pointer.
    /// - `.ok` one or more labels → `.pass` listing every label in the order
    ///   the vault returned them.
    /// - `.timedOut` → `.fail` "Keychain query timed out — re-run doctor".
    /// - `.permissionDenied(err)` → `.fail` "Keychain unavailable
    ///   (locked / permission denied)". The error's `localizedDescription`
    ///   is appended — OSStatus error descriptions carry only status
    ///   codes + Apple-canned text, never vault values, so no secret
    ///   material can reach this surface through the error.
    /// - `.otherFailure(err)` → `.fail` "Keychain query failed:
    ///   <localizedDescription>".
    static func formatAnthropicVaultLabelsLine(
        _ result: KeychainVaultLookupResult
    ) -> (Status, String) {
        switch result {
        case .ok(let vaultLabels):
            let labels = vaultLabels.labels
            if labels.isEmpty {
                return (
                    .skip,
                    "Anthropic vault: no labels provisioned. Run `senkani vault add anthropic-key --label <name>` to seed the upstream key."
                )
            }
            let listed = labels.joined(separator: ", ")
            return (
                .pass,
                "Anthropic vault: \(labels.count) label(s) provisioned (\(listed))"
            )
        case .timedOut:
            return (
                .fail,
                "Anthropic vault: Keychain query timed out (>5s) — re-run `senkani doctor`. If this persists, your login Keychain may be locked or the Security daemon is unresponsive."
            )
        case .permissionDenied(let error):
            return (
                .fail,
                "Anthropic vault: Keychain unavailable (locked / permission denied): \(error.localizedDescription)"
            )
        case .otherFailure(let error):
            return (
                .fail,
                "Anthropic vault: Keychain query failed: \(error.localizedDescription)"
            )
        }
    }

    /// V.13b-5 / V.13b-4c — synchronously list provisioned Anthropic
    /// vault labels with a 5s ceiling. Bridges the async
    /// `CredentialVault.list` actor call onto doctor's sync execution
    /// path via a bounded-timeout semaphore. The list call is bounded
    /// by the underlying store's single Keychain query; no network I/O.
    /// Extracted so the unit test can drive the bridge with an injected
    /// `InMemoryKeychainStore`-backed vault and assert the label list
    /// (label-only — the raw key never reaches this surface).
    ///
    /// V.13b-4c hardening:
    /// - **Thread-safe publish**: the prior `nonisolated(unsafe) var
    ///   labels` had a real TSan race on the timeout codepath (the
    ///   background Task could still be writing `labels` when the main
    ///   thread returned it). Replaced with an `NSLock`-guarded
    ///   `LookupSlot` so the background-Task write and the main-thread
    ///   read are serialized, and the main thread only ever returns
    ///   what was atomically published.
    /// - **5s ceiling** (was 3s): matches the b-4d test ceiling; on
    ///   timeout, returns `.timedOut` (NOT `.ok([])`) so the formatter
    ///   renders a distinct "Keychain query timed out" message instead
    ///   of the false-negative "no labels provisioned" hint.
    /// - **Perm-denied classification**: caught throws are classified
    ///   into `.permissionDenied` vs `.otherFailure` based on the
    ///   underlying NSError's `code` (OSStatus). `errSecAuthFailed`,
    ///   `errSecInteractionNotAllowed`, `errSecUserCanceled`, and
    ///   `errSecAuthFailed`-class statuses route to `.permissionDenied`;
    ///   everything else routes to `.otherFailure`.
    static func listAnthropicVaultLabels(
        vault: CredentialVault
    ) -> KeychainVaultLookupResult {
        // NSLock-guarded slot: the background Task writes
        // `(labels, error, done)` atomically; the main thread reads
        // them atomically after the semaphore fires (or sees `done ==
        // false` on timeout). No `nonisolated(unsafe)` shared state.
        final class LookupSlot: @unchecked Sendable {
            private let lock = NSLock()
            private var _labels: [String] = []
            private var _error: Error? = nil
            private var _done: Bool = false

            func publish(labels: [String]?, error: Error?) {
                lock.lock()
                defer { lock.unlock() }
                if let labels = labels {
                    _labels = labels
                }
                _error = error
                _done = true
            }

            func snapshot() -> (labels: [String], error: Error?, done: Bool) {
                lock.lock()
                defer { lock.unlock() }
                return (_labels, _error, _done)
            }
        }

        let slot = LookupSlot()
        let sem = DispatchSemaphore(value: 0)
        Task {
            defer { sem.signal() }
            do {
                let labels = try await vault.list(
                    scope: AnthropicKeyProvisioner.vaultScope
                )
                slot.publish(labels: labels, error: nil)
            } catch {
                slot.publish(labels: nil, error: error)
            }
        }
        // V.13b-4c: 5s ceiling (was 3s).
        let waitResult = sem.wait(timeout: .now() + .seconds(5))
        let snap = slot.snapshot()
        if waitResult == .timedOut || !snap.done {
            // Timed out — do NOT collapse to empty labels.
            return .timedOut
        }
        if let error = snap.error {
            if Self.isPermissionDeniedError(error) {
                return .permissionDenied(error)
            }
            return .otherFailure(error)
        }
        return .ok(VaultLabels(snap.labels))
    }

    /// V.13b-4c — classify a Keychain `list` throw as permission-denied
    /// vs other-failure. The `MacOSKeychainStore` wraps OSStatus into
    /// an `NSError(domain: "MacOSKeychainStore", code: Int(status))`,
    /// so we read back the OSStatus from the NSError code. The status
    /// codes treated as permission-denied are:
    ///
    /// - `errSecAuthFailed` (-25293): authentication failed (canonical
    ///   "Keychain locked / wrong password" status).
    /// - `errSecInteractionNotAllowed` (-25308): UI prompt required
    ///   but disallowed (headless serve hitting a locked Keychain).
    /// - `errSecUserCanceled` (-128): operator dismissed an unlock
    ///   prompt.
    /// - `errSecNotAvailable` (-25291): no Keychain available
    ///   (e.g. headless CI without a login Keychain).
    ///
    /// Everything else (e.g. `errSecParam`, future broker-store I/O
    /// errors) routes to `.otherFailure`.
    static func isPermissionDeniedError(_ error: Error) -> Bool {
        let ns = error as NSError
        // OSStatus values (from `<Security/SecBase.h>`):
        // errSecAuthFailed = -25293, errSecInteractionNotAllowed = -25308,
        // errSecUserCanceled = -128, errSecNotAvailable = -25291.
        let permissionDeniedCodes: Set<Int> = [-25293, -25308, -128, -25291]
        return permissionDeniedCodes.contains(ns.code)
    }

    /// V.13b-5 — surface provisioned upstream Anthropic vault labels.
    /// Production reads via `AnthropicKeyProvisioner.vault()` (the real
    /// macOS Keychain). The test path drives the pure formatter
    /// (`formatAnthropicVaultLabelsLine`) + the bridge
    /// (`listAnthropicVaultLabels`) directly with an
    /// `InMemoryKeychainStore`-backed vault so CI never touches the live
    /// Keychain. Mirror of the egress-policy file-path injection pattern
    /// used by `checkAnthropicEgressAllowRule` above (line 1920) — there
    /// the seam was a path argument, here the seam is the static helpers
    /// because the vault is an async-capable actor rather than a flat
    /// file.
    ///
    /// The check is non-blocking (.skip on missing labels — not .fail) so
    /// a fresh install without an Anthropic key still passes `doctor`
    /// overall; the absence of an upstream key is an operator
    /// configuration choice (the local-only tiers still serve), not a
    /// broken state.
    private func checkAnthropicVaultLabels(_ results: inout Results) {
        let lookup = Self.listAnthropicVaultLabels(vault: AnthropicKeyProvisioner.vault())
        let (status, message) = Self.formatAnthropicVaultLabelsLine(lookup)
        printStatus(status, message)
        switch status {
        case .pass: results.passed += 1
        case .fixed: results.fixed += 1
        case .fail: results.failed += 1
        case .skip: results.skipped += 1
        }
    }

    // MARK: - Check 23: Runtime telemetry receiver (Phase V.18a-3)

    /// V.18a-3 — surface the runtime-telemetry receiver's last-bound
    /// loopback port + cumulative drop count from the persisted
    /// config file at `~/.senkani/runtime-telemetry-receiver.json`.
    /// Doctor does not start the receiver; it just reads whatever
    /// snapshot the last running instance wrote. The loopback bind
    /// is performative — see spec/architecture.md.
    private func checkRuntimeTelemetryReceiver(_ results: inout Results) {
        let cfg = (try? RuntimeTelemetryReceiverConfigStore.load()) ?? RuntimeTelemetryReceiverConfig()
        let portText = cfg.port > 0 ? ":\(cfg.port)" : "not yet bound"
        let rateText = "\(cfg.perSourceSpansPerSecond) spans/s/source"
        printStatus(.pass, "Runtime telemetry receiver — \(portText) | drops: \(cfg.totalDrops) | rate cap: \(rateText) | loopback boundary: performative (local-user trust)")
        results.passed += 1
    }

    // MARK: - Check 16: OpenAI-compatible endpoint (Phase V.13e-2)

    /// Pure formatter for the OpenAI-endpoint check. Returns one
    /// informational line: bind / port / key-count / trailing-24h request
    /// count / 429-rate. Lifted out of `checkOpenAIEndpoint` so the
    /// `doctor-openai-check-render` test asserts on the operator-facing
    /// surface without dup2-capturing stdout (mirror of
    /// `formatChainAuditLines` / `formatBundleStalenessLines`).
    ///
    /// Always `.pass` — the check is informational (non-blocking), like the
    /// runtime-telemetry-receiver check. An endpoint that has served zero
    /// requests is a normal state, not a failure; the config carries
    /// loopback defaults even when the operator has never run
    /// `senkani serve --openai`.
    ///
    /// Schneier (no-secret-on-stdout): the line surfaces only the key
    /// COUNT. The raw API key, its hash, and its label never reach this
    /// formatter — `keyCount` is a plain `Int`. `loadAllSync` returns
    /// hash-only records, and the caller passes `.count`, so no key
    /// material can leak through the doctor surface.
    static func formatOpenAIEndpointLine(
        config: OpenAIEndpointConfig,
        keyCount: Int,
        stats: OpenAIRequestLogStore.TrailingStats
    ) -> (Status, String) {
        let rate = String(format: "%.1f%%", stats.rate429 * 100)
        return (
            .pass,
            "OpenAI endpoint — bind: \(config.bind) | port: \(config.port) | keys: \(keyCount) | requests (24h): \(stats.count24h) | 429-rate: \(rate)"
        )
    }

    /// Thin wrapper. Reads the persisted endpoint config (bind / port),
    /// counts the provisioned keys straight off disk, and pulls the
    /// trailing-24h request count + 429-rate from v13e-1's persisted query
    /// API on the shared `SessionDatabase` (so the last two fields are
    /// correct cross-process — they survive a `senkani serve --openai`
    /// restart because they read the durable rows, not in-memory state).
    private func checkOpenAIEndpoint(_ results: inout Results) {
        let config = OpenAIEndpointConfig.load()
        let keyCount = OpenAIKeyProvisioner.loadAllSync().count
        let stats = SessionDatabase.shared.openAIRequestTrailing24hStats()
        let (status, message) = Self.formatOpenAIEndpointLine(
            config: config, keyCount: keyCount, stats: stats
        )
        printStatus(status, message)
        switch status {
        case .pass: results.passed += 1
        case .fixed: results.fixed += 1
        case .fail: results.failed += 1
        case .skip: results.skipped += 1
        }
    }
}
