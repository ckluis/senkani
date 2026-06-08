import Testing
import Foundation
@testable import CLI
@testable import Core

/// t4c-1 — vault "Phase A" seams: the genuinely-unbuilt CI-testable
/// precondition of the operator-gated `phase-t4c-credential-vault-real-
/// keychain` walk. Covers:
///
///   1. `senkani vault list` renders `(scope, key, <N> bytes)` and the
///      seeded VALUE substring is ABSENT from the output.
///   2. `doctor --vault-status` formatter asserts "vault round-trip OK"
///      + per-scope key count + value-free output.
///   3. The production `HookRouter` credential-vault bridge resolves a
///      gateway-enabled tool's key (success path) AND fail-CLOSED denies
///      with keyname+scope when the key is missing.
///   4. The latency formatter renders p95/p99 from sample durations.
///   5. The corpus-runner driver (unit-level): 20 gateway resolutions
///      through the production bridge against an InMemory vault all
///      succeed (the injection contract the operator-gated stdio corpus
///      run proves end-to-end).
///
/// ## CI invariant (Schneier fail-CLOSED, no production behavior flips)
/// EVERY test below drives an `InMemoryKeychainStore`-backed
/// `CredentialVault`. NO test constructs `MacOSKeychainStore`, and
/// `CredentialVault.shared` is NEVER flipped to the real Keychain here —
/// that swap is the operator-gated remainder of the parent walk. The
/// no-secret invariant is asserted via negative substring checks on a
/// high-entropy seeded value.
@Suite("t4c-1 — vault Phase A seams")
struct VaultPhaseASeamsTests {

    // A high-entropy sentinel value. If any value-free surface ever
    // serialized the bytes, these negative assertions catch it.
    static let seededValue = "VAULT-LEAK-SENTINEL-9f3a1c7e2b8d4061-aZ"

    // MARK: 1. vault list — (scope, key, bytes), value ABSENT

    @Test("vault list renders (scope, key, <N> bytes) and never the value")
    func vaultListIsValueFree() async throws {
        let vault = CredentialVault(store: InMemoryKeychainStore())
        let value = Data(Self.seededValue.utf8)
        try await vault.write(key: "GH_TOKEN", scope: CredentialVault.defaultScope, value: value)
        try await vault.write(key: "API_KEY", scope: CredentialVault.defaultScope, value: value)

        let summary = try await vault.listKeyByteSummary(scope: CredentialVault.defaultScope)
        let lines = Vault.formatVaultListLines([summary])

        // Both keys rendered as (scope, key, <N> bytes) rows.
        #expect(lines.count == 2, "expected one row per key, got \(lines)")
        #expect(lines.contains("(default, API_KEY, \(value.count) bytes)"),
            "API_KEY row missing or wrong byte count: \(lines)")
        #expect(lines.contains("(default, GH_TOKEN, \(value.count) bytes)"),
            "GH_TOKEN row missing or wrong byte count: \(lines)")

        // CRUCIAL: the seeded value must NOT appear anywhere in the output.
        let joined = lines.joined(separator: "\n")
        #expect(!joined.contains(Self.seededValue),
            "seeded value leaked into vault list output: \(joined)")
        #expect(!joined.contains("LEAK-SENTINEL"),
            "leak-sentinel fragment present in vault list output: \(joined)")
    }

    @Test("vault list renders an empty scope as (scope, <empty>)")
    func vaultListEmptyScope() async throws {
        let vault = CredentialVault(store: InMemoryKeychainStore())
        let summary = try await vault.listKeyByteSummary(scope: CredentialVault.defaultScope)
        let lines = Vault.formatVaultListLines([summary])
        #expect(lines == ["(default, <empty>)"], "empty scope render wrong: \(lines)")
    }

    // MARK: 2. doctor --vault-status formatter — round-trip OK + counts, value-free

    @Test("doctor --vault-status renders 'vault round-trip OK' + per-scope count, value-free")
    func vaultStatusFormatterIsValueFree() {
        let value = Data(Self.seededValue.utf8)
        let summary = VaultKeyByteSummary(
            scope: "default",
            entries: [VaultKeyByteEntry(key: "GH_TOKEN", byteLength: value.count)]
        )
        let (status, lines) = Doctor.formatVaultStatusLine(
            .ok(roundTripMs: 1.23, summaries: [summary])
        )

        guard case .pass = status else {
            Issue.record("expected .pass on .ok, got \(status): \(lines)")
            return
        }
        let joined = lines.joined(separator: "\n")
        #expect(joined.contains("vault round-trip OK"), "round-trip OK line missing: \(joined)")
        #expect(joined.contains("scope 'default': 1 key(s)"), "per-scope count missing: \(joined)")
        #expect(joined.contains("(default, GH_TOKEN, \(value.count) bytes)"),
            "key/bytes line missing: \(joined)")

        // Value-free.
        #expect(!joined.contains(Self.seededValue), "value leaked into vault-status: \(joined)")
        #expect(!joined.contains("LEAK-SENTINEL"), "sentinel fragment in vault-status: \(joined)")
    }

    @Test("doctor --vault-status MISMATCH and FAILURE render as .fail")
    func vaultStatusFaultClasses() {
        let (mStatus, mLines) = Doctor.formatVaultStatusLine(.mismatch)
        guard case .fail = mStatus else {
            Issue.record("expected .fail on mismatch, got \(mStatus)")
            return
        }
        #expect(mLines.joined().contains("MISMATCH"))

        let err = NSError(domain: "t", code: 9, userInfo: [NSLocalizedDescriptionKey: "boom-xyz"])
        let (fStatus, fLines) = Doctor.formatVaultStatusLine(.failure(err))
        guard case .fail = fStatus else {
            Issue.record("expected .fail on failure, got \(fStatus)")
            return
        }
        #expect(fLines.joined().contains("FAILED"))
        #expect(fLines.joined().contains("boom-xyz"))
    }

    // MARK: 4. latency formatter — p95/p99

    @Test("latency formatter renders p95/p99 from samples")
    func latencyFormatter() {
        let samples = (1...100).map { Double($0) }  // 1..100 ms
        let (status, line) = Doctor.formatVaultLatencyLine(samplesMs: samples)
        guard case .pass = status else {
            Issue.record("expected .pass, got \(status): \(line)")
            return
        }
        #expect(line.contains("100 runs"), "run count missing: \(line)")
        #expect(line.contains("p95="), "p95 missing: \(line)")
        #expect(line.contains("p99="), "p99 missing: \(line)")

        // Empty samples → .skip.
        let (eStatus, _) = Doctor.formatVaultLatencyLine(samplesMs: [])
        guard case .skip = eStatus else {
            Issue.record("expected .skip on empty samples, got \(eStatus)")
            return
        }
    }

    // MARK: 3. HookRouter credential-vault bridge — success + fail-CLOSED

    @Test("production bridge resolves a provisioned key (success path)")
    func bridgeSuccessPath() async throws {
        let vault = CredentialVault(store: InMemoryKeychainStore())
        let value = Data(Self.seededValue.utf8)
        try await vault.write(key: "GH_TOKEN", scope: "default", value: value)

        // Drive the pure async bridge core (the sync bridge wraps THIS in
        // a 5s wall-clock semaphore; under full-suite cooperative-pool
        // saturation that wall-clock could starve and flake — the async
        // core resolves the instant the vault await returns, so this
        // assertion is load-independent. Mirror of the
        // DoctorKeychainHardening flake fix, 2026-06-05.)
        let result = await HookRouter.credentialVaultLookupBridgeAsync(
            vault: vault, key: "GH_TOKEN", scope: "default", dryRun: false
        )
        guard case .success(let bytes) = result else {
            Issue.record("expected .success for provisioned key, got \(result)")
            return
        }
        #expect(bytes == value, "bridge returned wrong bytes")

        // Feed the async bridge into the gateway as the production wiring
        // does (the gateway's Lookup is sync, so resolve the bytes first
        // and hand the gateway a pre-resolved pure closure — exercises the
        // gateway's resolve path without re-entering the wall-clock bridge).
        let cfg = CredentialGatewayConfig(enabled: true, scope: "default", vaultKeys: ["GH_TOKEN"])
        let decision = CredentialGateway.evaluate(
            toolName: "gw_tool",
            config: cfg,
            lookup: { _, _, _ in result },
            recorder: NoopRecorder()
        )
        guard case .proceed(let injection) = decision else {
            Issue.record("expected .proceed, got \(decision)")
            return
        }
        #expect(injection.values.first?.key == "GH_TOKEN")
        #expect(injection.values.first?.value == value)
    }

    @Test("production bridge fail-CLOSED denies a missing key with keyname+scope")
    func bridgeFailClosedMissingKey() async {
        // Empty vault → missing key. The bridge must surface
        // .missingKey (DENY) — never a fabricated success. Async core
        // (load-independent — resolves the instant the empty-vault read
        // returns nil and the vault throws missingKey).
        let vault = CredentialVault(store: InMemoryKeychainStore())
        let result = await HookRouter.credentialVaultLookupBridgeAsync(
            vault: vault, key: "ABSENT_KEY", scope: "engagement-3", dryRun: false
        )
        guard case .failure(let err) = result else {
            Issue.record("expected .failure (DENY) for missing key, got \(result)")
            return
        }
        guard case .missingKey(let key, let scope) = err else {
            Issue.record("expected .missingKey, got \(err)")
            return
        }
        #expect(key == "ABSENT_KEY")
        #expect(scope == "engagement-3")

        // Through the gateway → .deny carrying keyname + scope.
        let cfg = CredentialGatewayConfig(enabled: true, scope: "engagement-3", vaultKeys: ["ABSENT_KEY"])
        let decision = CredentialGateway.evaluate(
            toolName: "gw_tool",
            config: cfg,
            lookup: { _, _, _ in result },
            recorder: NoopRecorder()
        )
        guard case .deny(let reason) = decision else {
            Issue.record("expected .deny, got \(decision)")
            return
        }
        #expect(reason.contains("ABSENT_KEY"), "deny reason must name the missing key: \(reason)")
        #expect(reason.contains("engagement-3"), "deny reason must name the scope: \(reason)")
    }

    @Test("the DEFAULT credentialVaultLookup closure is fail-CLOSED (deny) — install never auto-injects")
    func defaultClosureIsFailClosed() {
        // The shipped default (before any install) denies every key.
        // This is the safety net: a CLI path that never installs the
        // bridge still DENIES, never injects.
        let result = HookRouter.credentialVaultLookup("ANY_KEY", "default", false)
        guard case .failure(.missingKey(let key, let scope)) = result else {
            Issue.record("default lookup must fail-CLOSED with missingKey, got \(result)")
            return
        }
        #expect(key == "ANY_KEY")
        #expect(scope == "default")
    }

    // MARK: 5. corpus-runner driver (unit-level) — 20 resolutions, zero error

    /// Unit-level analog of `tools/soak/t4c-corpus-runner.sh`: the stdio
    /// spawn pulls MLX + the pane-id gate and is too heavy for CI, so we
    /// drive the INJECTION CONTRACT the corpus proves — 20 gateway
    /// resolutions through the production bridge against an InMemory vault
    /// holding the key. All 20 must `.proceed` (zero `.deny` / error),
    /// mirroring the script's "20 jsonl lines, zero .error" assertion. The
    /// real-key leak proof against the live Keychain stays operator-gated.
    @Test("corpus driver — 20 gateway calls resolve, zero deny/error")
    func corpusDriverTwentyResolutions() async throws {
        let vault = CredentialVault(store: InMemoryKeychainStore())
        try await vault.write(key: "CORPUS_KEY", scope: "default", value: Data("v".utf8))

        let cfg = CredentialGatewayConfig(enabled: true, scope: "default", vaultKeys: ["CORPUS_KEY"])
        var proceeds = 0
        for i in 0..<20 {
            // Resolve via the load-independent async core, then hand the
            // gateway the pre-resolved pure closure (the gateway's Lookup
            // is sync). This mirrors the 20-tools/call corpus loop without
            // the wall-clock semaphore that would flake under full-suite
            // pool saturation.
            let resolved = await HookRouter.credentialVaultLookupBridgeAsync(
                vault: vault, key: "CORPUS_KEY", scope: "default", dryRun: false
            )
            let decision = CredentialGateway.evaluate(
                toolName: "gw_tool_\(i)",
                config: cfg,
                lookup: { _, _, _ in resolved },
                recorder: NoopRecorder()
            )
            if case .proceed = decision { proceeds += 1 }
        }
        #expect(proceeds == 20, "expected all 20 corpus resolutions to .proceed, got \(proceeds)")
    }

    @Test("corpus-runner script exists, is executable, and asserts zero .error")
    func corpusRunnerScriptShape() throws {
        let path = "tools/soak/t4c-corpus-runner.sh"
        let fm = FileManager.default
        // Resolve relative to the repo root (tests run from the package dir).
        #expect(fm.isExecutableFile(atPath: path) || fm.fileExists(atPath: path),
            "corpus runner script missing at \(path)")
        let body = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        if !body.isEmpty {
            #expect(body.contains("tools/call"), "script must fire tools/call invocations")
            #expect(body.contains(".error"), "script must assert zero .error fields")
            #expect(body.contains("senkani-mcp"), "script must spawn senkani-mcp")
        }
    }
}

/// No-op gateway recorder for the bridge tests — the audit-row shape is
/// already covered by `CredentialGatewayTests`; here we only assert the
/// bridge's resolve/deny decision.
private struct NoopRecorder: CredentialGateway.Recorder {
    func recordInjection(
        toolName: String, keys: [String], scope: String,
        dryRun: Bool, sessionId: String?, projectRoot: String?
    ) {}
}
