import Testing
import Foundation
import SQLite3
@testable import Core

// MARK: - Test helpers

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-credential-gateway-test-\(UUID().uuidString).sqlite"
    let db = SessionDatabase(path: path)
    return (db, path)
}

/// Build a HookRouter event JSON the way the production binary
/// constructs them. Mirrors `HookRouterTests.makeEvent`.
private func makeEvent(
    toolName: String,
    toolInput: [String: Any] = [:],
    eventName: String = "PreToolUse",
    sessionId: String? = nil,
    cwd: String? = nil
) -> Data {
    var event: [String: Any] = [
        "tool_name": toolName,
        "hook_event_name": eventName,
    ]
    if !toolInput.isEmpty { event["tool_input"] = toolInput }
    if let sid = sessionId { event["session_id"] = sid }
    if let cwd = cwd { event["cwd"] = cwd }
    return try! JSONSerialization.data(withJSONObject: event)
}

@Suite("T.4b — CredentialGateway", .serialized)
struct CredentialGatewayTests {

    // MARK: 1. Schema (Codable round-trip)

    @Test("CredentialGatewayConfig round-trips through JSON unchanged")
    func configCodableRoundTrip() throws {
        let original = CredentialGatewayConfig(
            enabled: true,
            scope: "engagement-42",
            vaultKeys: ["OPENAI_API_KEY", "PUSHOVER_TOKEN"],
            dryRun: true,
            injectionTarget: .args
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CredentialGatewayConfig.self, from: data)
        #expect(decoded == original)

        // Defaults must round-trip too — exercises the optional/init
        // defaults path.
        let minimal = CredentialGatewayConfig(enabled: false, vaultKeys: [])
        let minData = try JSONEncoder().encode(minimal)
        let minDecoded = try JSONDecoder().decode(CredentialGatewayConfig.self, from: minData)
        #expect(minDecoded == minimal)
        #expect(minDecoded.scope == CredentialVault.defaultScope)
        #expect(minDecoded.dryRun == false)
        #expect(minDecoded.injectionTarget == .env)
    }

    // MARK: 2. Default catalog ships gateway disabled everywhere

    @Test("No tool in MCPToolCatalog.defaults ships credentialGateway enabled")
    func defaultCatalogHasNoEnabledGateway() {
        for entry in MCPToolCatalog.defaults {
            if let gw = entry.credentialGateway {
                #expect(
                    gw.enabled == false,
                    "Default catalog tool '\(entry.name)' ships with credential gateway enabled"
                )
            }
        }
        // The accessor must surface the gateway config alongside the
        // existing tag/override metadata.
        let cat = MCPToolCatalog(entries: [
            MCPToolConfig(
                name: "test_tool",
                tags: [.exec],
                credentialGateway: CredentialGatewayConfig(
                    enabled: true,
                    vaultKeys: ["KEY"]
                )
            )
        ])
        let row = cat.config(for: "test_tool")
        #expect(row?.tags == [.exec])
        #expect(row?.credentialGateway?.enabled == true)
        #expect(row?.credentialGateway?.vaultKeys == ["KEY"])
    }

    // MARK: 3. Success path — values resolved, audit row written, NEVER the value

    @Test("Successful gateway evaluation records keyname+scope but never the credential value")
    func successPathInjectsAndRecordsRow() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }
        let recorder = CredentialGateway.DatabaseRecorder(database: db)

        // The credential value is a high-entropy random string. If the
        // gateway ever serialized it into `command`, this test would
        // catch it via substring scan after the row lands.
        let secretValue = Data("supersecret-bytes-DEADBEEFCAFE-9d2f0c1a8b".utf8)
        let lookup: CredentialGateway.Lookup = { _, _, _ in .success(secretValue) }

        let cfg = CredentialGatewayConfig(
            enabled: true,
            scope: "default",
            vaultKeys: ["api_token", "session_key"],
            dryRun: false
        )

        let decision = CredentialGateway.evaluate(
            toolName: "test_tool",
            config: cfg,
            lookup: lookup,
            recorder: recorder,
            sessionId: "sid-1",
            projectRoot: "/tmp/senkani-test-project"
        )

        guard case .proceed(let injection) = decision else {
            Issue.record("expected .proceed, got \(decision)")
            return
        }
        #expect(injection.values.count == 2)
        #expect(injection.values.map(\.key) == ["api_token", "session_key"])
        #expect(injection.values.map(\.value) == [secretValue, secretValue])
        #expect(injection.scope == "default")
        #expect(injection.dryRun == false)

        // Drain the parent.queue.async write before reading back. The
        // recorder dispatches to SessionDatabase.queue, which is the
        // same serial queue used for reads — `recentTokenEvents`'s
        // `queue.sync` will block until the write finishes.
        let rows = db.recentTokenEvents(projectRoot: "/tmp/senkani-test-project", limit: 10)
        let matching = rows.filter { $0.feature == "credential_gateway" }
        #expect(matching.count == 1, "expected one credential_gateway row, got \(matching.count)")

        guard let row = matching.first else { return }
        #expect(row.toolName == "test_tool")

        let cmd = row.command ?? ""
        // Keyname + scope must be present.
        #expect(cmd.contains("api_token"), "command must record keyname")
        #expect(cmd.contains("session_key"), "command must record keyname")
        #expect(cmd.contains("default"), "command must record scope")
        #expect(cmd.contains("dry_run=false"), "command must record dry-run flag")
        // The credential value must NOT be present.
        let secretString = String(data: secretValue, encoding: .utf8)!
        #expect(
            !cmd.contains(secretString),
            "credential value leaked into token_events.command: \(cmd)"
        )
        // Defense-in-depth: a high-entropy substring of the value
        // shouldn't appear either.
        #expect(!cmd.contains("DEADBEEFCAFE"))
    }

    // MARK: 4. Missing key, no dry-run → fail closed with keyname AND scope

    @Test("Missing key with dryRun:false denies with keyname+scope in the reason")
    func missingKeyFailsClosedWithKeyAndScope() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }
        let recorder = CredentialGateway.DatabaseRecorder(database: db)

        // Lookup returns missingKey verbatim — production
        // `CredentialVault.read` would do the same.
        let lookup: CredentialGateway.Lookup = { key, scope, _ in
            .failure(.missingKey(key: key, scope: scope))
        }

        let cfg = CredentialGatewayConfig(
            enabled: true,
            scope: "engagement-7",
            vaultKeys: ["GH_TOKEN"],
            dryRun: false
        )

        let decision = CredentialGateway.evaluate(
            toolName: "test_tool",
            config: cfg,
            lookup: lookup,
            recorder: recorder,
            sessionId: "sid-2",
            projectRoot: "/tmp/senkani-test-project-deny"
        )

        guard case .deny(let reason) = decision else {
            Issue.record("expected .deny, got \(decision)")
            return
        }
        #expect(reason.contains("GH_TOKEN"), "reason must name the missing key")
        #expect(reason.contains("engagement-7"), "reason must name the scope")
        #expect(reason.contains("senkani vault add"), "reason must include the operator action hint")

        // No audit row on deny — the chain is reserved for successful
        // injections.
        let rows = db.recentTokenEvents(projectRoot: "/tmp/senkani-test-project-deny", limit: 10)
        #expect(rows.allSatisfy { $0.feature != "credential_gateway" })
    }

    // MARK: 5. Missing key, dry-run → FAKE_KEY sentinel

    @Test("Missing key with dryRun:true returns FAKE_KEY sentinel and proceeds")
    func missingKeyDryRunYieldsFakeKey() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }
        let recorder = CredentialGateway.DatabaseRecorder(database: db)

        // Bridge to a real CredentialVault so the FAKE_KEY shape is the
        // production contract verbatim — not a hand-rolled fake.
        let vault = CredentialVault(store: InMemoryKeychainStore())
        final class Box: @unchecked Sendable {
            var result: Result<Data, CredentialVaultError> = .failure(.missingKey(key: "", scope: ""))
        }
        let lookup: CredentialGateway.Lookup = { key, scope, dryRun in
            let semaphore = DispatchSemaphore(value: 0)
            let box = Box()
            box.result = .failure(.missingKey(key: key, scope: scope))
            Task { @Sendable in
                do {
                    let value = try await vault.read(key: key, scope: scope, dryRun: dryRun)
                    box.result = .success(value)
                } catch let err as CredentialVaultError {
                    box.result = .failure(err)
                } catch {
                    box.result = .failure(.missingKey(key: key, scope: scope))
                }
                semaphore.signal()
            }
            semaphore.wait()
            return box.result
        }

        let cfg = CredentialGatewayConfig(
            enabled: true,
            scope: "default",
            vaultKeys: ["MISSING_KEY"],
            dryRun: true
        )

        let decision = CredentialGateway.evaluate(
            toolName: "test_tool",
            config: cfg,
            lookup: lookup,
            recorder: recorder,
            sessionId: "sid-3",
            projectRoot: "/tmp/senkani-test-project-fake"
        )

        guard case .proceed(let injection) = decision else {
            Issue.record("expected .proceed in dry-run, got \(decision)")
            return
        }
        #expect(injection.values.count == 1)
        #expect(injection.values.first?.key == "MISSING_KEY")
        let expectedFake = Data("FAKE_KEY_default_MISSING_KEY".utf8)
        #expect(injection.values.first?.value == expectedFake)
        #expect(injection.dryRun == true)

        // Audit row marks dry-run so an operator scrubbing the chain
        // can tell which rows were sentinels vs. real injections.
        let rows = db.recentTokenEvents(projectRoot: "/tmp/senkani-test-project-fake", limit: 10)
        let matching = rows.filter { $0.feature == "credential_gateway" }
        #expect(matching.count == 1)
        #expect(matching.first?.command?.contains("dry_run=true") == true)
    }

    // MARK: 6. ConfirmationGate deny short-circuits BEFORE any vault read

    @Test("ConfirmationGate.deny short-circuits HookRouter before the gateway lookup fires")
    func confirmationGateDenyShortCircuitsVaultRead() {
        HookSeamLock.withLock {
            let (db, path) = makeTempDB()
            defer { TempSessionDatabase.cleanup(path: path) }

            // Catalog: a single tool that has BOTH (a) confirmation
            // required (so the gate fires) AND (b) credential gateway
            // enabled (so the gateway would also fire if reached).
            let catalog = MCPToolCatalog(entries: [
                MCPToolConfig(
                    name: "Bash",
                    tags: [.exec],
                    credentialGateway: CredentialGatewayConfig(
                        enabled: true,
                        vaultKeys: ["WOULD_BE_FETCHED"]
                    )
                )
            ])

            // Resolver that always denies.
            ConfirmationGate.database = db
            ConfirmationGate.catalog = catalog
            ConfirmationGate.resolver = { _, _ in
                (.deny, .operator, "denied for test")
            }
            defer { ConfirmationGate.resetToDefaults() }

            // Track whether the lookup was called.
            final class CallTracker: @unchecked Sendable {
                var called = false
            }
            let tracker = CallTracker()

            // Save and restore the HookRouter seams.
            let savedLookup = HookRouter.credentialVaultLookup
            let savedRecorder = HookRouter.credentialGatewayRecorder
            let savedCatalog = HookRouter.credentialGatewayCatalog
            defer {
                HookRouter.credentialVaultLookup = savedLookup
                HookRouter.credentialGatewayRecorder = savedRecorder
                HookRouter.credentialGatewayCatalog = savedCatalog
            }
            HookRouter.credentialVaultLookup = { key, scope, _ in
                tracker.called = true
                return .failure(.missingKey(key: key, scope: scope))
            }
            HookRouter.credentialGatewayRecorder = CredentialGateway.DatabaseRecorder(database: db)
            HookRouter.credentialGatewayCatalog = catalog

            // Drive a Bash event through HookRouter. The confirmation gate
            // denies; the gateway must NEVER call the lookup.
            let response = HookRouter.handle(eventJSON: makeEvent(
                toolName: "Bash",
                toolInput: ["command": "git status"]
            ))

            // Response is a deny carrying the gate's reason.
            guard let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
                  let hookOutput = json["hookSpecificOutput"] as? [String: Any]
            else {
                Issue.record("expected hookSpecificOutput in response")
                return
            }
            #expect(hookOutput["permissionDecision"] as? String == "deny")
            let reason = hookOutput["permissionDecisionReason"] as? String ?? ""
            #expect(reason.contains("Confirmation denied"), "must surface the gate's reason, not the gateway's")

            // The lookup must not have been called — gateway short-
            // circuits before any vault read.
            #expect(tracker.called == false, "vault lookup fired despite ConfirmationGate.deny")

            // No credential_gateway row in the audit chain.
            let rows = db.recentTokenEventsAllProjects(limit: 50)
            #expect(rows.allSatisfy { $0.feature != "credential_gateway" })
        }
    }
}
