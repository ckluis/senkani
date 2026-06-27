import ArgumentParser
import Bench
import Core
import Foundation
import HookRelay
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

    @Flag(name: .long, help: "Walk the EgressProxy adversarial smoke (T.1c 5-scenario host corpus + T.1d-5 8-scenario MITM body-inspection corpus). Reports per-scenario pass/fail with rule_id, the MITM termination state (enabled/disabled + CA-on-disk), the body-inspection corpus pass rate, and recent egress_decisions deny-row counts by ruleId. Exits non-zero on any miss. Engine-level — does not spin the live listener.")
    var checkEgress = false

    @Flag(name: .long, help: "Report the senkani_exec execution-sandbox posture derived from the live ExecRoutingDecision (T.3b). Reports DENY-BY-DEFAULT / fail-CLOSED: user-supplied scripts are REFUSED (no host /bin/sh fallback), tool-internal callers use the host path, the positive wasm-sandbox path is deferred/unavailable. Read-only status; exit 0 when the fail-CLOSED invariant holds, non-zero if it is breached.")
    var checkSandbox = false

    @Flag(name: .long, help: "Generate the MITM egress CA pem and PRINT the operator-runnable `security add-trusted-cert ...` command to add it as a System trust root (T.1d-6). DRY-RUN scaffolding only: NEVER runs `security`, never sudo, never mutates the System Keychain (that is t1d-7, gui-human). Requires a typed-string confirm.")
    var installEgressCA = false

    @Flag(name: .long, help: "Reversible counterpart to --install-egress-ca: remove the local CA pem (if present) and PRINT the operator-runnable `security remove-trusted-cert ...` command (T.1d-6). DRY-RUN scaffolding only — never runs `security`, never touches the System Keychain.")
    var uninstallEgressCA = false

    @Flag(name: .long, help: "Round-trip the credential vault (t4c-1): write+read+delete a probe key, then report per-scope key counts as (scope, key, <N> bytes). NEVER prints credential values. Reads CredentialVault.shared (empty in-memory store until the operator-gated real-Keychain swap lands).")
    var vaultStatus = false

    @Option(name: .long, help: "With --vault-status, do N timed reads through CredentialVault.shared and report p95/p99 read latency (t4c-1).")
    var latencyRuns: Int?

    @Option(name: .long, help: "With --vault-status --latency-runs, the key to read on each latency probe (t4c-1). Defaults to the probe key the round-trip wrote.")
    var latencyKey: String?

    @Flag(name: .long, help: "Seed the Pushover credential into the credential vault (T.6c): prompts twice (entry + confirm, input hidden on a tty), writes through the Keychain seam under key '\(PushoverCredentialsRef.vaultKey)', and records ONE non-secret audit row (key NAME only — never the value). Mismatch or a missing confirm aborts with NO write. Seeding the REAL token is the operator's leg; this flag is the mechanism.")
    var seedPushoverKey = false

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

        // T.3b focused posture motion — report the senkani_exec
        // execution-sandbox routing posture DERIVED FROM the live
        // ExecRoutingDecision (the single source of truth), not a
        // hardcoded string. Read-only; exits non-zero only if the
        // fail-CLOSED invariant is breached (a user-supplied caller
        // routing to .host).
        if checkSandbox {
            try runCheckSandbox()
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

        // t4c-1 focused vault-status motion — round-trip CredentialVault
        // .shared, report per-scope key counts (value-free) and optional
        // p95/p99 read latency. Read-only of credential VALUES; the
        // round-trip writes + deletes only a probe key.
        if vaultStatus {
            try runVaultStatus()
            return
        }

        // T.6c focused seed motion — prompt twice (entry + confirm, no
        // echo on a tty), write the Pushover credential through the
        // Keychain vault seam, record ONE non-secret audit row (key NAME
        // only). Mismatch / missing confirm aborts BEFORE any write.
        if seedPushoverKey {
            try runSeedPushoverKey()
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

        // 4b. Hook relay drops — the read-side surface for carve-1's
        //     deadline-driven passthrough log (the gate-bypass signal of
        //     t6-hook-relay-5ms-deadline-drops). Reports per-reason counts,
        //     the PreToolUse-read_timeout bypass callout + fail-closed fire
        //     rate, and a 24h window. Informational: an absent log → "0 drops
        //     recorded" (healthy), never moves the doctor exit code.
        checkHookRelayDrops(&results)

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

        // 18a. MITM termination env-safety readiness (T.1d-2b-ii r85) —
        //      surfaces the operator-state where `mitmTlsTermination`
        //      is flipped ON in FeatureConfig but the on-disk CA pem
        //      is missing, so the listener silently falls through to
        //      the opaque tunnel. Mirrors the stderr WARNING the
        //      listener emits at bind time (`EgressListener.start()`).
        checkMITMTerminationReadiness(&results)

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

    /// Build the EXACT `security delete-certificate` invocation. PRINTED,
    /// not run. `remove-trusted-cert` withdraws the TRUST SETTING but leaves
    /// the cert OBJECT in the System Keychain, so a full baseline restore
    /// also needs this delete (surfaced live in the t1d-7 operator walk,
    /// 2026-06-14). Targets the CA by its subject CN in the System keychain.
    static func deleteCertificateInvocation() -> [String] {
        ["security", "delete-certificate", "-c", "senkani Egress MITM Root CA", systemKeychainPath]
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

        // `remove-trusted-cert` only withdraws the TRUST SETTING — it leaves
        // the cert OBJECT in the System Keychain. A full baseline restore
        // also needs `security delete-certificate` (surfaced live in the
        // t1d-7 operator walk, 2026-06-14). Routed through the SAME dry-run
        // executor — printed/recorded, never spawned.
        let deleteInvocation = deleteCertificateInvocation()
        print("Then DELETE the leftover cert object (remove-trusted-cert only")
        print("withdraws trust; the cert object remains) — run yourself, t1d-7:")
        print("  sudo " + deleteInvocation.joined(separator: " "))
        print("")
        executor.run(deleteInvocation)

        print("Done. Local CA files cleared; the System trust REMOVAL is NOT")
        print("done — run the commands above yourself (t1d-7).")
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

    // MARK: - --seed-pushover-key (Phase T.6c child A)

    /// Outcome of one `--seed-pushover-key` motion. Returned (not thrown)
    /// so the testable motion can be asserted hermetically; the CLI
    /// wrapper maps every non-`.seeded` outcome to a non-zero exit.
    enum SeedPushoverOutcome: Equatable {
        /// Entry + confirm matched — the credential was written through
        /// the Keychain seam and ONE non-secret audit row was recorded.
        case seeded
        /// The first prompt returned nil/whitespace — nothing was written.
        case abortedMissingEntry
        /// The confirm prompt returned nil/whitespace — nothing was written.
        case abortedMissingConfirm
        /// Entry and confirm did not match — nothing was written.
        case abortedMismatch
    }

    /// Canonical non-secret audit payload for a successful seed. Carries
    /// the key NAME + scope ONLY — there is no parameter shape by which
    /// the secret could reach this formatter (mirror of
    /// `CredentialGateway.canonicalPayload`'s name-only invariant).
    static func seedPushoverAuditPayload(key: String, scope: String) -> String {
        "pushover.seed key=\(key) scope=\(scope)"
    }

    /// Testable seed motion (mirrors `installEgressCAMotion`'s injectable
    /// shape). Prompts TWICE through the injected `promptReader` (entry +
    /// confirm — production reads with terminal echo disabled), hard-aborts
    /// on a missing entry, missing confirm, or mismatch BEFORE any write,
    /// then writes the secret through the Keychain seam (`CredentialVault`
    /// over `KeychainStore`) and records ONE non-secret audit row via
    /// `recordAudit`.
    ///
    /// Entries are whitespace/newline-TRIMMED before the empty-guard and
    /// the compare (a pasted trailing newline must not force a false
    /// mismatch); the TRIMMED bytes are what is stored — consistent with
    /// `AnthropicKeyProvisioner`'s trim-before-store contract.
    ///
    /// SECURITY (Schneier):
    ///   * The secret is never printed, echoed, or logged — its only
    ///     sinks are the vault write and the operator's own terminal.
    ///   * The audit payload is built by `seedPushoverAuditPayload`,
    ///     whose parameters are the key NAME and scope only — there is
    ///     no shape by which the secret can reach the audit row.
    ///   * NO real token is seeded by the autonomous build — CI drives
    ///     this motion with fake secrets against an
    ///     `InMemoryKeychainStore`-backed vault; the REAL token seed
    ///     (real Keychain + real Pushover token + device-push proof) is
    ///     the operator leg of the parent T.6c item.
    static func seedPushoverKeyMotion(
        vault: CredentialVault,
        key: String = PushoverCredentialsRef.vaultKey,
        scope: String = PushoverCredentialsRef.vaultScope,
        promptReader: (String) -> String?,
        recordAudit: (String) -> Void
    ) async throws -> SeedPushoverOutcome {
        print("Senkani Doctor — seed Pushover credential (T.6c)")
        print("=================================================")
        print("")
        print("You will be prompted TWICE (entry + confirm; input hidden on")
        print("a tty). On match the credential is written to the vault's")
        print("Keychain seam under key '\(key)' (scope '\(scope)') and ONE")
        print("non-secret audit row (key NAME only) is recorded. On mismatch")
        print("or a missing confirm, NOTHING is written.")
        print("")

        let firstRaw = promptReader("Paste the Pushover credential (input hidden): ")
        let first = firstRaw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !first.isEmpty else {
            print("Aborted: no credential entered. Nothing was written, no audit row recorded.")
            return .abortedMissingEntry
        }

        let secondRaw = promptReader("Paste it again to confirm (input hidden): ")
        let second = secondRaw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !second.isEmpty else {
            print("Aborted: missing confirmation. Nothing was written, no audit row recorded.")
            return .abortedMissingConfirm
        }

        guard first == second else {
            print("Aborted: the two entries did not match. Nothing was written, no audit row recorded.")
            return .abortedMismatch
        }

        try await vault.write(key: key, scope: scope, value: Data(first.utf8))
        recordAudit(Self.seedPushoverAuditPayload(key: key, scope: scope))
        print("Seeded Pushover credential under key '\(key)' (scope '\(scope)').")
        print("Recorded one audit row carrying the key NAME only — never the secret.")
        return .seeded
    }

    /// CLI dispatch wrapper. Bridges the async motion onto doctor's sync
    /// execution path via a `DispatchSemaphore` (mirror of
    /// `vaultRoundTrip`'s balanced-semaphore lifecycle) — with NO
    /// wall-clock ceiling, because the motion blocks on operator typing,
    /// which is unbounded. The Task ALWAYS `signal()`s via `defer`, so
    /// the wait ends exactly when the motion returns or throws.
    private func runSeedPushoverKey() throws {
        final class Slot: @unchecked Sendable {
            private let lock = NSLock()
            private var _value: Result<SeedPushoverOutcome, Error>?
            func publish(_ v: Result<SeedPushoverOutcome, Error>) {
                lock.lock(); defer { lock.unlock() }; _value = v
            }
            func snapshot() -> Result<SeedPushoverOutcome, Error>? {
                lock.lock(); defer { lock.unlock() }; return _value
            }
        }
        let slot = Slot()
        let sem = DispatchSemaphore(value: 0)
        Task {
            defer { sem.signal() }
            do {
                let outcome = try await Self.seedPushoverKeyMotion(
                    vault: .shared,
                    promptReader: { Self.readSecretLine(prompt: $0) },
                    recordAudit: { Self.recordPushoverSeedAudit($0) }
                )
                slot.publish(.success(outcome))
            } catch {
                slot.publish(.failure(error))
            }
        }
        sem.wait()
        switch slot.snapshot() {
        case .success(.seeded):
            return
        case .success:
            // The motion already printed WHY it aborted; exit non-zero so
            // the flag stays scriptable.
            throw ExitCode.failure
        case .failure(let error):
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            throw ExitCode.failure
        case nil:
            FileHandle.standardError.write(Data("error: seed motion produced no result.\n".utf8))
            throw ExitCode.failure
        }
    }

    /// Read one secret line for the seed prompts. The prompt goes to
    /// STDERR (mirror of `vault add`'s STDIN contract — a piped stdout
    /// captures no interactive text); on a tty the line is read with
    /// terminal echo DISABLED (termios `ECHO` cleared, restored on the
    /// way out) and a newline is emitted after the hidden input. Non-tty
    /// stdin (heredocs / scripts) falls back to a plain line read so the
    /// prompt-twice flow stays scriptable.
    private static func readSecretLine(prompt: String) -> String? {
        FileHandle.standardError.write(Data(prompt.utf8))
        if isatty(STDIN_FILENO) != 0 {
            var original = termios()
            if tcgetattr(STDIN_FILENO, &original) == 0 {
                var quiet = original
                quiet.c_lflag &= ~tcflag_t(ECHO)
                _ = tcsetattr(STDIN_FILENO, TCSANOW, &quiet)
                defer { tcsetattr(STDIN_FILENO, TCSANOW, &original) }
                let line = readLine(strippingNewline: true)
                FileHandle.standardError.write(Data("\n".utf8))
                return line
            }
        }
        return readLine(strippingNewline: true)
    }

    /// Production audit recorder for a successful seed: ONE
    /// `token_events` row (source "doctor", feature "pushover.seed")
    /// whose `command` column is the canonical non-secret payload (key
    /// NAME + scope — built by `seedPushoverAuditPayload`, which cannot
    /// carry the value). Mirrors `recordEgressCAInstallAudit`'s
    /// single-row write + flush.
    private static func recordPushoverSeedAudit(_ payload: String) {
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
            feature: "pushover.seed",
            command: payload
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

        // U.9b-3 — parity sub-row, summed across all project roots from the
        // existing `session_work_bus.parity_*` event counters minted in
        // u9b-1. Informational only; doctor exit code stays 0.
        let parityRows = SessionDatabase.shared.eventCounts(prefix: "session_work_bus.parity_")
        func paritySum(_ type: String) -> Int {
            parityRows.filter { $0.eventType == type }.reduce(0) { $0 + $1.count }
        }
        let pMatch = paritySum(AutoValidateDualWrite.parityMatch)
        let pDiverge = paritySum(AutoValidateDualWrite.parityDiverge)
        let pBusOnly = paritySum(AutoValidateDualWrite.parityBusOnly)
        let pInProcOnly = paritySum(AutoValidateDualWrite.parityInProcessOnly)
        printStatus(.pass, "work-bus parity — match: \(pMatch) | diverge: \(pDiverge) | bus_only: \(pBusOnly) | inprocess_only: \(pInProcOnly)")
        results.passed += 1

        // U.9b-3b leg 4 — the latency sub-rows the u9b-3 spine deferred:
        // latency-delta p50/p95 over matched (succeeded) dual-write pairs
        // + the age of the oldest unmatched (pending/processing) pair.
        // Pairing/timing derives from the queue rows themselves — see
        // `SessionWorkQueueStore.ParityTiming`. Informational only: the
        // formatter emits `.pass` lines exclusively, so the doctor exit
        // code stays 0 regardless of bus latency.
        let timing = SessionDatabase.shared.sessionWorkQueueStore.parityTiming(
            kinds: [AutoValidateDualWrite.kind, PaneRefreshDualWrite.kind]
        )
        for (status, message) in Self.formatWorkBusLatencyLines(timing: timing) {
            printStatus(status, message)
            results.passed += 1
        }
    }

    /// U.9b-3b leg 4 — pure formatter for the work-bus latency sub-rows.
    /// Lifted out of `checkSessionWorkBus` (mirror of
    /// `formatChainAuditLines`) so tests assert on the doctor surface
    /// without dup2-capturing stdout. Every line is `.pass` by
    /// construction — the sub-rows are informational and can never move
    /// the doctor exit code.
    static func formatWorkBusLatencyLines(
        timing: SessionWorkQueueStore.ParityTiming
    ) -> [(Status, String)] {
        let p50 = timing.percentile(50).map(formatWorkBusInterval) ?? "n/a"
        let p95 = timing.percentile(95).map(formatWorkBusInterval) ?? "n/a"
        let age = timing.oldestUnmatchedAge.map(formatWorkBusInterval) ?? "n/a"
        return [
            (.pass, "work-bus latency-delta — matched_pairs: \(timing.matchedDeltas.count) | p50: \(p50) | p95: \(p95)"),
            (.pass, "work-bus oldest-unmatched-pair — unmatched: \(timing.unmatchedCount) | age: \(age)")
        ]
    }

    /// Render a parity-timing interval: sub-second values as whole
    /// milliseconds (a bus path trailing by 50ms must not render as
    /// "0.0s"), everything else as seconds with one decimal.
    static func formatWorkBusInterval(_ v: TimeInterval) -> String {
        v < 1.0 ? String(format: "%.0fms", v * 1000) : String(format: "%.1fs", v)
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

    // MARK: - Check 4b: Hook relay drops (hook-relay-drop-log-doctor-surface)

    /// Surface the hook-relay drop log written by carve-1's
    /// `HookRelay.recordDrop`. Every line is informational — the doctor exit
    /// code never moves on drop state: a deadline-driven passthrough is a
    /// SIGNAL to act on (tune a deadline), not a config defect. An absent /
    /// empty log → "0 drops recorded" (the healthy fresh-machine state).
    ///
    /// SECURITY: prints ONLY the reason / hookEvent / count data already in
    /// the log — never any credential or payload bytes. Carve-1's writer made
    /// the log lines non-sensitive by construction; this read-side surface
    /// adds nothing the writer didn't already record.
    private func checkHookRelayDrops(_ results: inout Results) {
        let path = HookRelayDropSummary.defaultDropLogPath()
        let summary = HookRelayDropSummary.load(now: Date())

        printStatus(.pass, "Hook relay drops — \(path)")
        results.passed += 1

        guard summary.total > 0 else {
            // Distinguish a genuinely empty/absent log (healthy) from a
            // non-empty log whose rows could not be parsed — drops may be
            // present but unreadable, which is NOT the healthy state.
            if summary.malformedLines > 0 {
                printStatus(.pass, "  log present but no parseable drop rows (\(summary.malformedLines) unrecognized line(s))")
            } else {
                printStatus(.pass, "  0 drops recorded")
            }
            results.passed += 1
            return
        }

        let scopeNote = summary.truncated ? " (showing last ~1 MB; older entries omitted)" : ""
        printStatus(.pass, "  \(summary.total) drops recorded (last 24h: \(summary.recentTotal))\(scopeNote)")
        results.passed += 1

        // Per-reason breakdown. NOTE: only PreToolUse is deny-capable, so the
        // AGGREGATE read_timeout count is NOT the gate-bypass number (it folds
        // in never-deny hooks) — the PreToolUse-specific line below is.
        let readTimeouts = summary.byReason["read_timeout"] ?? 0
        let failClosed = summary.failClosedFires
        let connectTimeouts = summary.byReason["connect_timeout"] ?? 0
        printStatus(.pass, "  read_timeout: \(readTimeouts)  (deadline passthroughs, all hooks)")
        results.passed += 1
        printStatus(.pass, "  read_timeout_failclosed_ask: \(failClosed)  (fail-closed fire rate)")
        results.passed += 1
        printStatus(.pass, "  connect_timeout: \(connectTimeouts)")
        results.passed += 1

        // THE actionable gate-bypass line: a PreToolUse read_timeout is a
        // deny-capable hook whose verdict was dropped past the deadline.
        printStatus(.pass, "  PreToolUse read_timeout: \(summary.preToolUseReadTimeouts)  (gate-bypass indicator)")
        results.passed += 1

        // Top hook_event_names by count (top 3), count desc then name asc for a
        // deterministic tie-break. The name is LOG-DERIVED (an external hook
        // payload field), so SANITIZE it — a crafted name carrying ANSI escapes
        // must not spoof or corrupt this trusted diagnostic's output.
        let topEvents = summary.byHookEvent
            .sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
            }
            .prefix(3)
            .map { "\(HookRelayDropSummary.sanitizeForDisplay($0.key))=\($0.value)" }
            .joined(separator: ", ")
        printStatus(.pass, "  top hook events: \(topEvents)")
        results.passed += 1

        // ONE conditional tuning hint when recent read_timeouts are
        // non-trivial (the deadline-too-tight signal). Kept to a single line
        // — no p99 over-build.
        if (summary.recentByReason["read_timeout"] ?? 0) > 0 {
            printStatus(.pass, "  hint: recent read_timeouts — consider raising SENKANI_HOOK_DENY_DEADLINE_MS")
            results.passed += 1
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

        // Per-binary install budgets (D5) are the authoritative install
        // gate — render them under the install.size line and fold any
        // breach into the block verdict.
        let installCheck = history.latestInstallBudgetCheck()

        let anyFailing = evaluations.contains { e in
            e.verdict == .overBudget || e.verdict == .regression
        } || (installCheck?.anyOverBudget ?? false)

        if anyFailing {
            printStatus(.fail, "Release commitments (Phase V.14):")
            results.failed += 1
        } else {
            printStatus(.pass, "Release commitments (Phase V.14):")
            results.passed += 1
        }

        for evaluation in evaluations {
            print("    " + releaseSLOLine(evaluation))
            if evaluation.slo == .installSize, let installCheck {
                for line in installCheck.lines {
                    print("      " + installBudgetLine(line))
                }
            }
        }
    }

    /// Render one per-binary install-budget line (stripped size vs budget).
    private func installBudgetLine(_ l: ReleaseSLOInstallBudget.CheckResult.Line) -> String {
        let head = String(format: "%@: %.1f MB (< %.0f MB budget, stripped)",
                          l.product, l.measuredMB, l.budgetMB)
        return l.overBudget ? head + " — OVER BUDGET" : head
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

        // T.1d-5 — 8-scenario MITM body-inspection adversarial corpus
        // runs immediately after the T.1c host corpus. Each scenario
        // exercises the body-aware enforcement path (host allow + body
        // deny / inner-Host rebind / oversized-head / unknown-protocol
        // / secret redaction) at the pure-logic surface. Failure here
        // BLOCKS the doctor exit (Allspaw P1 activation-gate).
        let bodyCorpus = MITMBodyInspectionCorpus.run()
        print("")
        print("MITM body-inspection corpus (8/8 adversarial scenarios)")
        print(String(repeating: "=", count: 56))
        for outcome in bodyCorpus.outcomes {
            let marker = outcome.passed ? "[ok]  " : "[fail]"
            print("  \(marker) \(outcome.label) → \(outcome.observedRuleId) (expected: \(outcome.expectedRuleId))")
        }
        let bodyFailed = bodyCorpus.outcomes.filter { !$0.passed }.count
        let bodyPassed = bodyCorpus.outcomes.count - bodyFailed
        print("")
        print("\(bodyCorpus.outcomes.count) body-inspection scenarios, \(bodyPassed) passed, \(bodyFailed) failed.")

        // r99 t1d-5 r52 Karpathy P2 — CONNECT-path body-deny scenarios.
        // `scenarios()` (above) is the FROZEN 8-scenario activation gate;
        // the new CONNECT-path corpus reports separately so the operator
        // sees both surfaces in --check-egress. Failures here do NOT
        // gate the doctor exit — only the frozen 8-scenario corpus does.
        let connectPathCorpus = MITMBodyInspectionCorpus.runConnectPath()
        let connectPathFailed = connectPathCorpus.outcomes.filter { !$0.passed }.count
        let connectPathPassed = connectPathCorpus.outcomes.count - connectPathFailed
        if !connectPathCorpus.outcomes.isEmpty {
            print("")
            print("MITM CONNECT-path body-deny corpus (\(connectPathPassed)/\(connectPathCorpus.outcomes.count) scenarios)")
            print(String(repeating: "=", count: 56))
            for outcome in connectPathCorpus.outcomes {
                let marker = outcome.passed ? "[ok]  " : "[fail]"
                print("  \(marker) \(outcome.label) → \(outcome.observedRuleId) (expected: \(outcome.expectedRuleId))")
            }
            print("")
            print("\(connectPathCorpus.outcomes.count) CONNECT-path scenarios, \(connectPathPassed) passed, \(connectPathFailed) failed.")
        }

        // T.1d-5 — MITM termination state line + recent-denial counts.
        // Both helpers live in Core (`MITMBodyInspectionCorpus`) so the
        // CLI never names the egress-decisions row type directly —
        // preserves the `ServeArmEgressAuditDualRowTests` egress-write
        // API deny-list (the deny-list pattern matches the row-type
        // namespace and would flag the type-name reference here).
        let features = FeatureConfig.resolve()
        let caPaths = defaultCAPaths()
        let publicExists = FileManager.default.fileExists(atPath: caPaths.publicCertPEM)
        let privateExists = FileManager.default.fileExists(atPath: caPaths.privateKeyPEM)
        let recentDenials = SessionDatabase.shared.recentEgressDecisions(limit: 200)
        let denialCounts = MITMBodyInspectionCorpus.countDenialsByRuleId(recentDenials)
        // v47 Allspaw P2 — capture-state distribution over the same 200-row
        // window. Surfaces a per-state counter so the operator can spot an
        // `.overflowed` spike (16 KB peek window undersized for their traffic).
        let captureStateCounts = MITMBodyInspectionCorpus.countByCaptureState(recentDenials)
        let stateLines = MITMBodyInspectionCorpus.formatCheckEgressMITMStateLines(
            flagOn: features.mitmTlsTermination,
            caOnDisk: publicExists && privateExists,
            bodyCorpusPassed: bodyPassed,
            bodyCorpusTotal: bodyCorpus.outcomes.count,
            recentDenialCounts: denialCounts,
            connectPathPassed: connectPathPassed,
            connectPathTotal: connectPathCorpus.outcomes.count,
            captureStateCounts: captureStateCounts
        )
        print("")
        for line in stateLines {
            print(line)
        }

        if failed > 0 || bodyFailed > 0 {
            throw ExitCode.failure
        }
    }

    // MARK: - --check-sandbox (T.3b)

    /// Result of probing the live `ExecRoutingDecision` for the
    /// execution-sandbox posture. `failClosedBreached` is the
    /// load-bearing field: it is `true` IFF any user-supplied caller
    /// routes to `.host` (an untrusted script reaching the host shell —
    /// RCE). The CLI exits non-zero when it is set. Lifted out of
    /// `runCheckSandbox` (and made pure) so a test can assert the exact
    /// posture lines + the breach flag WITHOUT capturing stdout, mirroring
    /// `formatChainAuditLines` and `formatCheckEgressMITMStateLines`.
    struct SandboxPosture: Equatable {
        var lines: [(Status, String)]
        var failClosedBreached: Bool

        static func == (lhs: SandboxPosture, rhs: SandboxPosture) -> Bool {
            guard lhs.failClosedBreached == rhs.failClosedBreached,
                  lhs.lines.count == rhs.lines.count else { return false }
            for (a, b) in zip(lhs.lines, rhs.lines) where a != b { return false }
            return true
        }
    }

    /// Derive the operator-facing sandbox posture purely from the live
    /// `ExecRoutingDecision.route(...)` — the SINGLE source of truth for
    /// the v2 routing branch. This deliberately does NOT hardcode the
    /// posture text: it probes the real router for each `ExecCallerKind`
    /// (and the future trusted-wasm-opt-in arm) and reports what the
    /// router actually decides. If `ExecRoutingDecision` ever changes
    /// (e.g. a positive wasm path is authorized), this surface — and the
    /// tests pinning it — move with it, so the doctor output can never
    /// drift into overclaiming the posture.
    ///
    /// Schneier: the headline ("deny-by-default / fail-CLOSED") is
    /// emitted ONLY when the router actually denies user-supplied callers
    /// for BOTH `sandboxAvailable` states. If the router ever routed a
    /// user-supplied caller to `.host`, this returns `failClosedBreached`
    /// and a FAIL line instead — no false reassurance.
    static func deriveSandboxPosture() -> SandboxPosture {
        var lines: [(Status, String)] = []

        // 1. The RCE-blocker: user-supplied scripts. Probe the router for
        //    both sandbox-availability states — the fail-CLOSED invariant
        //    is that NEITHER routes to .host.
        let userSuppliedAvail = ExecRoutingDecision.route(
            callerKind: .userSupplied, sandboxAvailable: true
        )
        let userSuppliedNoAvail = ExecRoutingDecision.route(
            callerKind: .userSupplied, sandboxAvailable: false
        )
        let userSuppliedDenied =
            userSuppliedAvail == .deny(.userSuppliedDenyByDefault)
            && userSuppliedNoAvail == .deny(.userSuppliedDenyByDefault)
        let failClosedBreached =
            userSuppliedAvail == .host || userSuppliedNoAvail == .host

        // 2. The trusted host arm: tool-internal callers (no wasm opt-in)
        //    keep today's Foundation Process /bin/sh path.
        let toolInternal = ExecRoutingDecision.route(callerKind: .toolInternal)
        let toolInternalIsHost = toolInternal == .host

        // 3. The future positive-wasm arm: a trusted opt-in caller whose
        //    sandbox runtime is missing must fail CLOSED, never fall back.
        let wasmOptInMissingRuntime = ExecRoutingDecision.route(
            callerKind: .toolInternal, sandboxAvailable: false, wantsSandbox: true
        )
        let wasmFailsClosed =
            wasmOptInMissingRuntime == .deny(.sandboxRuntimeUnavailable)

        if failClosedBreached {
            // The router leaked a user-supplied caller to the host shell.
            // This must never happen; report it as a hard FAIL.
            lines.append((
                .fail,
                "exec sandbox: FAIL-CLOSED BREACH — a user-supplied senkani_exec caller routes to the host shell (RCE). ExecRoutingDecision must deny .userSupplied."
            ))
            return SandboxPosture(lines: lines, failClosedBreached: true)
        }

        // Headline posture — emitted only when the router genuinely denies.
        if userSuppliedDenied {
            lines.append((
                .pass,
                "exec sandbox: deny-by-default / fail-CLOSED"
            ))
        } else {
            // Router neither denied nor leaked to host (e.g. a future
            // positive path returned some non-.host route). Report
            // honestly rather than claim deny-by-default.
            lines.append((
                .skip,
                "exec sandbox: user-supplied routing changed — \(userSuppliedAvail) (no longer plain deny-by-default; review ExecRoutingDecision)"
            ))
        }

        // Per-caller facts, each derived from the router above.
        lines.append((
            userSuppliedDenied ? .pass : .skip,
            "  user-supplied scripts: REFUSED (reason=\(ExecDenyReason.userSuppliedDenyByDefault.rawValue)) — no host /bin/sh fallback"
        ))
        lines.append((
            toolInternalIsHost ? .pass : .skip,
            "  tool-internal callers: host path (Foundation Process /bin/sh) — reserved for explicitly-trusted in-process callers"
        ))
        lines.append((
            wasmFailsClosed ? .pass : .skip,
            "  positive wasm sandbox path: deferred / unavailable — trusted wasm opt-in fails CLOSED (reason=\(ExecDenyReason.sandboxRuntimeUnavailable.rawValue)) on missing runtime, never falls back to host"
        ))

        return SandboxPosture(lines: lines, failClosedBreached: false)
    }

    /// CLI dispatch for `--check-sandbox`. Prints the posture derived from
    /// the live `ExecRoutingDecision` and exits non-zero only if the
    /// fail-CLOSED invariant is breached. Read-only — no DB writes, no
    /// process spawn, no mutation; safe to run anytime.
    private func runCheckSandbox() throws {
        print("Senkani Doctor — exec sandbox posture (T.3b)")
        print(String(repeating: "=", count: 44))
        print("")

        let posture = Self.deriveSandboxPosture()
        for (status, message) in posture.lines {
            printStatus(status, message)
        }

        print("")
        print("""
        Derived from ExecRoutingDecision (the live v2 routing source of
        truth). No third-party wasm shell is vendored, so user-supplied
        scripts have no sandboxed surface to run on — the safe action is
        to refuse. Ratified operator decision 2026-06-05; the positive
        wasm-shell path is deferred indefinitely.
        """)

        if posture.failClosedBreached {
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

    /// T.1d-2b-ii r85 — env-safety readiness check for the operator
    /// state where `FeatureConfig.mitmTlsTermination` is flipped ON
    /// but no on-disk CA pem exists for the listener to mint leaves
    /// from. In that state `EgressConnectionHandler` silently falls
    /// through to the opaque tunnel — the security control the
    /// flag is supposed to deliver is INACTIVE. Doctor reports the
    /// mismatch as `.fail` with the operator-runnable next step.
    ///
    /// Doctor runs in a separate process from the listener so we can't
    /// directly observe whether the listener was constructed with a
    /// leaf provider. Instead we report on the necessary precondition
    /// for any wired provider: the on-disk CA pem + private-key pair
    /// at `~/.senkani/egress-ca.{pem,key}`. If both exist + the flag
    /// is ON → `.pass`. If the flag is ON but the CA materials are
    /// missing → `.fail` (operator-actionable). Flag OFF → `.skip`.
    ///
    /// Mirror of the stderr WARNING emitted by `EgressListener.start()`.
    private func checkMITMTerminationReadiness(_ results: inout Results) {
        let features = FeatureConfig.resolve()
        let paths = defaultCAPaths()
        let publicExists = FileManager.default.fileExists(atPath: paths.publicCertPEM)
        let privateExists = FileManager.default.fileExists(atPath: paths.privateKeyPEM)
        let caOnDisk = publicExists && privateExists
        let (status, message) = Self.formatMITMTerminationReadinessLine(
            flagOn: features.mitmTlsTermination,
            caOnDisk: caOnDisk
        )
        printStatus(status, message)
        switch status {
        case .pass: results.passed += 1
        case .fixed: results.fixed += 1
        case .fail: results.failed += 1
        case .skip: results.skipped += 1
        }
    }

    /// T.1d-2b-ii r85 — pure formatter for the MITM termination
    /// env-safety readiness check. Lifted out so the unit test can
    /// drive the three states without touching the filesystem or
    /// resolving the live FeatureConfig (mirror of
    /// `formatAnthropicVaultLabelsLine`).
    ///
    /// - Flag OFF → `.skip` "opaque tunnel mode".
    /// - Flag ON + CA on disk → `.pass`.
    /// - Flag ON + CA missing → `.fail` with the operator-runnable
    ///   `senkani doctor --install-egress-ca` next step.
    static func formatMITMTerminationReadinessLine(
        flagOn: Bool,
        caOnDisk: Bool
    ) -> (Status, String) {
        if !flagOn {
            return (
                .skip,
                "MITM termination: flag is OFF — opaque tunnel mode (default)"
            )
        }
        if caOnDisk {
            return (
                .pass,
                "MITM termination: flag is ON; on-disk CA pem + key present"
            )
        }
        return (
            .fail,
            "MITM termination: flag is ON but no on-disk CA pem/key — opaque tunnel is in effect. Run `senkani doctor --install-egress-ca` and re-enable the flag."
        )
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
        // `(result, done)` atomically; the main thread reads it
        // atomically after the semaphore fires (or sees `done ==
        // false` on timeout). No `nonisolated(unsafe)` shared state.
        final class LookupSlot: @unchecked Sendable {
            private let lock = NSLock()
            private var _result: KeychainVaultLookupResult? = nil

            func publish(_ result: KeychainVaultLookupResult) {
                lock.lock()
                defer { lock.unlock() }
                _result = result
            }

            func snapshot() -> KeychainVaultLookupResult? {
                lock.lock()
                defer { lock.unlock() }
                return _result
            }
        }

        let slot = LookupSlot()
        let sem = DispatchSemaphore(value: 0)
        Task {
            defer { sem.signal() }
            // Delegate classification to the shared async helper. The
            // helper has NO internal wall-clock ceiling (timeoutSeconds:
            // nil) because the ceiling on doctor's sync path is enforced
            // here by the semaphore wait below — keeping the production
            // behavior (a 5s wall-clock budget on doctor's blocking call
            // path) byte-for-byte unchanged.
            let result = await Self.listAnthropicVaultLabelsAsync(
                vault: vault, timeoutSeconds: nil
            )
            slot.publish(result)
        }
        // V.13b-4c: 5s ceiling (was 3s). This wall-clock budget bounds
        // doctor's BLOCKING sync execution path — it is intentionally a
        // real-machine deadline so a hung Security daemon cannot wedge
        // `senkani doctor`. (Tests do NOT exercise this blocking path —
        // they call `listAnthropicVaultLabelsAsync` directly, whose
        // ceiling is a logical Task.sleep race, not a wall-clock wait —
        // so the suite is independent of cooperative-pool scheduling
        // latency under full-suite parallel load.)
        let waitResult = sem.wait(timeout: .now() + .seconds(5))
        if waitResult == .timedOut {
            // Timed out — do NOT collapse to empty labels.
            return .timedOut
        }
        // Semaphore signaled → the async helper published a result.
        return slot.snapshot() ?? .timedOut
    }

    /// V.13b-4c / flake-doctor-keychain-vault-sleep-timing — the pure
    /// async classification core shared by doctor's sync bridge
    /// (`listAnthropicVaultLabels`) and the unit tests. Performs the
    /// exact same fault-class mapping the sync bridge used to inline:
    ///
    /// - vault list returns → `.ok(VaultLabels(labels))`
    /// - vault list throws a permission-denied OSStatus → `.permissionDenied`
    /// - vault list throws anything else → `.otherFailure`
    /// - the logical ceiling (when `timeoutSeconds != nil`) elapses
    ///   before the vault list completes → `.timedOut`
    ///
    /// **Why this exists (test-flake fix, 2026-06-05):** the prior
    /// design only exposed the *synchronous* bridge, whose 5s ceiling is
    /// a real `DispatchSemaphore` wall-clock wait. Under full-suite
    /// parallel load (~3.7k tests saturating the cooperative pool) the
    /// background `Task` could not be scheduled within 5s of wall time —
    /// so even an instant in-memory vault lookup wall-clock-stretched
    /// past the deadline and returned `.timedOut` instead of `.ok`,
    /// flaking 4 tests that PASSED 9/9 in isolation. The tests now drive
    /// THIS async helper instead. The non-timeout paths (`.ok`,
    /// `.permissionDenied`) have no wall-clock dependence at all — they
    /// resolve the instant the vault `await` returns, regardless of pool
    /// saturation. The timeout-contract tests pass `timeoutSeconds:` and
    /// race the vault's `Task.sleep` against a `Task.sleep`-based
    /// ceiling: both sleeps are scheduled on the same clock and starve
    /// together under load, so their RELATIVE ordering (a 4s store sleep
    /// resolving before a 5s ceiling; a 7s store sleep losing to it) is
    /// preserved even when absolute wall-clock stretches. The assertion
    /// still verifies the real contract — a 4s lookup succeeds under the
    /// 5s ceiling, a 7s lookup times out — without depending on absolute
    /// scheduler latency.
    ///
    /// `timeoutSeconds: nil` disables the logical ceiling entirely
    /// (used by the sync bridge, which enforces its own wall-clock
    /// ceiling via the semaphore).
    static func listAnthropicVaultLabelsAsync(
        vault: CredentialVault,
        timeoutSeconds: Double?
    ) async -> KeychainVaultLookupResult {
        // Classify the vault list into a fault class. Factored as a
        // closure so both the no-timeout fast path and the timeout race
        // share one classification site.
        func classifiedList() async -> KeychainVaultLookupResult {
            do {
                let labels = try await vault.list(
                    scope: AnthropicKeyProvisioner.vaultScope
                )
                return .ok(VaultLabels(labels))
            } catch {
                if Self.isPermissionDeniedError(error) {
                    return .permissionDenied(error)
                }
                return .otherFailure(error)
            }
        }

        guard let timeoutSeconds = timeoutSeconds else {
            // No logical ceiling — resolve as soon as the vault returns.
            return await classifiedList()
        }

        // Logical timeout race: the classified vault list vs a
        // `Task.sleep` ceiling. First to finish wins; the loser is
        // cancelled. `Task.sleep` honors cancellation, so the ceiling
        // task is torn down promptly when the list wins. Both arms are
        // scheduled on the same clock, so under cooperative-pool
        // starvation they stretch together and their relative ordering
        // is preserved — that is what makes the timeout assertion
        // load-independent.
        let timeoutNanos = UInt64(timeoutSeconds * 1_000_000_000)
        return await withTaskGroup(
            of: KeychainVaultLookupResult.self
        ) { group in
            group.addTask {
                await classifiedList()
            }
            group.addTask {
                // Sleep losing the race is cancelled; treat cancellation
                // (CancellationError thrown by Task.sleep) as "I lost".
                do {
                    try await Task.sleep(nanoseconds: timeoutNanos)
                    return .timedOut
                } catch {
                    // Cancelled because the list arm already won. Return a
                    // sentinel the harvester below filters out by taking
                    // the FIRST completed result only.
                    return .timedOut
                }
            }
            // Take the first arm to finish, cancel the rest.
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
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

    // MARK: - t4c-1: --vault-status

    /// t4c-1 — result of a credential-vault round-trip probe. Distinct
    /// cases let the formatter render distinct operator-facing messages
    /// per fault class rather than collapsing every failure into one
    /// "vault broken" line (Schneier P2, mirror of
    /// `KeychainVaultLookupResult`).
    ///
    /// - `.ok`: the probe key wrote, read back byte-identical, and
    ///   deleted cleanly. Carries the round-trip wall-clock in
    ///   milliseconds plus the per-scope `(scope, key, <N> bytes)`
    ///   summaries (VALUE-FREE — `VaultKeyByteSummary` has no field that
    ///   can hold the raw value).
    /// - `.mismatch`: the read-back bytes did not equal the written probe
    ///   bytes — a storage-integrity fault.
    /// - `.failure(Error)`: the vault threw on write/read/delete.
    enum VaultStatusResult: Sendable {
        case ok(roundTripMs: Double, summaries: [VaultKeyByteSummary])
        case mismatch
        case failure(Error)
    }

    /// t4c-1 — pure formatter for the `--vault-status` round-trip line +
    /// the per-scope key-count lines. Returns `(Status, [String])` so the
    /// unit test can assert on the operator-facing surface directly
    /// (mirror of `formatAnthropicVaultLabelsLine`).
    ///
    /// **Schneier (no-secret-on-stdout):** the input is a
    /// `VaultStatusResult` whose only data-bearing case carries
    /// `VaultKeyByteSummary` (key name + byte LENGTH) and a round-trip
    /// duration. There is no parameter shape by which a raw credential
    /// value could reach this formatter — the value-free guarantee is
    /// type-level via `VaultKeyByteSummary`.
    ///
    /// - `.ok` → `.pass` "vault round-trip OK / <N> ms" plus one
    ///   `(scope, key, <N> bytes)` line per provisioned key and a
    ///   per-scope count line.
    /// - `.mismatch` → `.fail` "vault round-trip MISMATCH".
    /// - `.failure(err)` → `.fail` "vault round-trip FAILED: <desc>".
    static func formatVaultStatusLine(
        _ result: VaultStatusResult
    ) -> (Status, [String]) {
        switch result {
        case let .ok(roundTripMs, summaries):
            var lines: [String] = []
            lines.append(String(format: "vault round-trip OK / %.2f ms", roundTripMs))
            for summary in summaries {
                lines.append("scope '\(summary.scope)': \(summary.count) key(s)")
            }
            lines.append(contentsOf: Vault.formatVaultListLines(summaries))
            return (.pass, lines)
        case .mismatch:
            return (
                .fail,
                ["vault round-trip MISMATCH — the probe key read back different bytes than were written. Storage-integrity fault."]
            )
        case let .failure(error):
            return (
                .fail,
                ["vault round-trip FAILED: \(error.localizedDescription)"]
            )
        }
    }

    /// t4c-1 — pure formatter for the optional `--latency-runs` p95/p99
    /// line. Takes the sorted per-read durations (milliseconds) and
    /// renders one line. No secret material is involved — durations only.
    static func formatVaultLatencyLine(samplesMs: [Double]) -> (Status, String) {
        guard !samplesMs.isEmpty else {
            return (.skip, "vault read latency: no samples collected")
        }
        let sorted = samplesMs.sorted()
        func percentile(_ p: Double) -> Double {
            let idx = min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.down)))
            return sorted[idx]
        }
        let p95 = percentile(0.95)
        let p99 = percentile(0.99)
        return (
            .pass,
            String(format: "vault read latency (%d runs): p95=%.3fms p99=%.3fms", sorted.count, p95, p99)
        )
    }

    /// t4c-1 — synchronously round-trip `CredentialVault.shared` and
    /// summarize per-scope key counts. Bridges the async actor onto
    /// doctor's sync execution path via a bounded-timeout
    /// `DispatchSemaphore` (mirror of `listAnthropicVaultLabels`).
    ///
    /// Carmack lifecycle: the semaphore is balanced — the background Task
    /// always `signal()`s in a `defer` so the wait cannot hang past the
    /// 5s ceiling, and the probe key is deleted in a `defer` so a throw
    /// mid-round-trip still cleans up the probe entry. No fd is opened;
    /// the bridge is purely an actor hop.
    ///
    /// The probe writes a unique, value-free probe key
    /// (`__senkani_doctor_probe_<uuid>`) into `CredentialVault.defaultScope`,
    /// reads it back, asserts byte-identity, then deletes it — so the
    /// round-trip never leaves residue and never collides with a real key.
    static func vaultRoundTrip(
        vault: CredentialVault = .shared,
        scopes: [String] = Vault.knownScopes,
        probeKey: String = "__senkani_doctor_probe_\(UUID().uuidString)"
    ) -> VaultStatusResult {
        final class Slot: @unchecked Sendable {
            private let lock = NSLock()
            private var _value: VaultStatusResult?
            func publish(_ v: VaultStatusResult) {
                lock.lock(); defer { lock.unlock() }; _value = v
            }
            func snapshot() -> VaultStatusResult? {
                lock.lock(); defer { lock.unlock() }; return _value
            }
        }
        let slot = Slot()
        let sem = DispatchSemaphore(value: 0)
        Task {
            defer { sem.signal() }
            let probeValue = Data("probe-\(UUID().uuidString)".utf8)
            let start = DispatchTime.now()
            do {
                try await vault.write(key: probeKey, scope: CredentialVault.defaultScope, value: probeValue)
                // Ensure the probe is removed even if read-back throws.
                var readBack: Data?
                do {
                    readBack = try await vault.read(key: probeKey, scope: CredentialVault.defaultScope)
                }
                // Best-effort cleanup; a delete failure must not mask the
                // round-trip verdict.
                try? await vault.delete(key: probeKey, scope: CredentialVault.defaultScope)

                let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
                guard readBack == probeValue else {
                    slot.publish(.mismatch)
                    return
                }
                var summaries: [VaultKeyByteSummary] = []
                for scope in scopes {
                    summaries.append(try await vault.listKeyByteSummary(scope: scope))
                }
                slot.publish(.ok(roundTripMs: elapsedMs, summaries: summaries))
            } catch {
                // Make a best-effort to clean up the probe key on any throw.
                try? await vault.delete(key: probeKey, scope: CredentialVault.defaultScope)
                slot.publish(.failure(error))
            }
        }
        // 5s wall-clock ceiling so a hung Security daemon (after the
        // operator-gated real-Keychain swap) cannot wedge `senkani doctor`.
        if sem.wait(timeout: .now() + .seconds(5)) == .timedOut {
            return .failure(NSError(
                domain: "DoctorVaultStatus", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "vault round-trip timed out (>5s) — the store may be unresponsive (locked login Keychain?)."]
            ))
        }
        return slot.snapshot() ?? .failure(NSError(
            domain: "DoctorVaultStatus", code: -2,
            userInfo: [NSLocalizedDescriptionKey: "vault round-trip produced no result."]
        ))
    }

    /// t4c-1 — measure read latency over `runs` reads of `key` through
    /// `vault`. Returns the per-read durations in milliseconds. Sync
    /// bridge with the same balanced-semaphore lifecycle as
    /// `vaultRoundTrip`. Value-free: the read result's bytes are
    /// discarded — only the wall-clock duration is recorded.
    static func vaultReadLatencySamples(
        vault: CredentialVault = .shared,
        key: String,
        scope: String = CredentialVault.defaultScope,
        runs: Int
    ) -> [Double] {
        guard runs > 0 else { return [] }
        final class Slot: @unchecked Sendable {
            private let lock = NSLock()
            private var _value: [Double] = []
            func publish(_ v: [Double]) {
                lock.lock(); defer { lock.unlock() }; _value = v
            }
            func snapshot() -> [Double] {
                lock.lock(); defer { lock.unlock() }; return _value
            }
        }
        let slot = Slot()
        let sem = DispatchSemaphore(value: 0)
        Task {
            defer { sem.signal() }
            var samples: [Double] = []
            samples.reserveCapacity(runs)
            for _ in 0..<runs {
                let start = DispatchTime.now()
                // Discard the bytes — only the duration is recorded.
                _ = try? await vault.read(key: key, scope: scope)
                let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
                samples.append(elapsedMs)
            }
            slot.publish(samples)
        }
        // Generous ceiling: 100 in-memory reads are sub-millisecond, but
        // the real-Keychain path (operator-gated) is bounded too.
        _ = sem.wait(timeout: .now() + .seconds(30))
        return slot.snapshot()
    }

    /// t4c-1 — thin wrapper: round-trip the production vault, render the
    /// value-free status lines, and (when requested) the latency line.
    /// Exits non-zero only if the round-trip itself failed/mismatched,
    /// so the flag is scriptable.
    private func runVaultStatus() throws {
        print("Senkani Doctor — credential vault status (t4c-1)")
        print("================================================")

        let probeKey = "__senkani_doctor_probe_\(UUID().uuidString)"
        let result = Self.vaultRoundTrip(probeKey: probeKey)
        let (status, lines) = Self.formatVaultStatusLine(result)
        for line in lines {
            printStatus(line == lines.first ? status : .skip, line)
        }

        // Optional latency probe.
        if let runs = latencyRuns, runs > 0 {
            // Default the latency key to the probe key if the operator
            // didn't name one — the probe key was just deleted, so reads
            // measure the miss path (still a real read round-trip).
            let key = latencyKey ?? probeKey
            let samples = Self.vaultReadLatencySamples(key: key, runs: runs)
            let (latStatus, latLine) = Self.formatVaultLatencyLine(samplesMs: samples)
            printStatus(latStatus, latLine)
        }

        if case .pass = status { return }
        throw ExitCode.failure
    }
}
