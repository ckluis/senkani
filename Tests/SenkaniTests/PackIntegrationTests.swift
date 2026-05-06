import Testing
import Foundation
@testable import Core

/// V.11b — cross-pack integration test. Installs the three bundled
/// packs (`code-quality` / `security` / `devops`) from `spec/packs/`
/// into a temp install root, asserts SkillScanner surfaces them with
/// `source: "pack"`, fires representative deny rules through the
/// HookRouter, fires non-matching tool calls to assert pass-through,
/// uninstalls each pack, asserts the registry drops the rules and
/// SkillScanner stops surfacing the skills, and confirms
/// `senkani doctor verify-chain` covers `pack_audits` clean across
/// the round-trip.
///
/// The shape mirrors `PackInstallTests` (V.11a) — temp install root +
/// temp DB-backed audit store + isolation via a per-test
/// `PackPolicyRegistry`. Tests do NOT touch the shared
/// `~/.senkani/packs/` install root.
@Suite("Phase V.11b — three-pack integration: install, fire, uninstall, verify",
       .serialized)
struct PackIntegrationTests {

    // MARK: - Helpers

    private static func tempBase() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("senkani-pack-int-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makeDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-pack-int-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        return (db, path)
    }

    /// Repo-relative path to a bundled pack source dir.
    private static func sourcePackDir(_ name: String) -> URL {
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd)
            .appendingPathComponent("spec/packs/\(name)", isDirectory: true)
    }

    /// Build a HookRouter event JSON for a tool call.
    private static func hookEvent(toolName: String, toolInput: [String: Any]) -> Data {
        let event: [String: Any] = [
            "hook_event_name": "PreToolUse",
            "tool_name": toolName,
            "tool_input": toolInput,
            "session_id": UUID().uuidString,
            "cwd": FileManager.default.currentDirectoryPath,
        ]
        return try! JSONSerialization.data(withJSONObject: event)
    }

    /// Decode a HookRouter response and pull out the deny reason
    /// (nil if the response is a passthrough).
    private static func denyReason(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hookOut = obj["hookSpecificOutput"] as? [String: Any],
              hookOut["permissionDecision"] as? String == "deny",
              let reason = hookOut["permissionDecisionReason"] as? String
        else { return nil }
        return reason
    }

    /// Install a pack from `spec/packs/<name>/` into the temp install
    /// root, refresh the per-test registry, and return the resulting
    /// `InstalledPack` for assertions.
    private static func install(
        _ name: String,
        installer: PackInstaller,
        registry: PackPolicyRegistry
    ) throws -> PackInstaller.InstalledPack {
        // Match the same-process refresh that production wires through
        // `HookRouter.refreshInstalledPacks()`. Tests inject a private
        // registry so we refresh that one explicitly rather than the
        // shared singleton.
        let pack = try installer.install(sourceDir: sourcePackDir(name))
        registry.refresh()
        return pack
    }

    /// Wrap `HookRouter.handle()` with the per-test registry seam so
    /// the shared `~/.senkani/packs/` install root is never read.
    /// Restores the previous registry on teardown.
    private static func withTestRegistry<T>(
        _ registry: PackPolicyRegistry,
        body: () throws -> T
    ) rethrows -> T {
        let prev = HookRouter.packPolicyRegistry
        HookRouter.packPolicyRegistry = registry
        defer { HookRouter.packPolicyRegistry = prev }
        return try body()
    }

    // MARK: - Tests

    @Test("Three bundled packs install side-by-side without collision")
    func threePacksInstallClean() throws {
        let base = Self.tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let installRoot = base.appendingPathComponent("packs", isDirectory: true)

        let (db, dbPath) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: dbPath) }
        let installer = PackInstaller(installRoot: installRoot, auditStore: db.packAuditStore)
        let registry = PackPolicyRegistry(installRoot: installRoot)

        let installed = try Self.withTestRegistry(registry) {
            let cq = try Self.install("code-quality", installer: installer, registry: registry)
            let sec = try Self.install("security", installer: installer, registry: registry)
            let dev = try Self.install("devops", installer: installer, registry: registry)
            return [cq, sec, dev]
        }

        #expect(installed.map(\.manifest.name).sorted() == ["code-quality", "devops", "security"])
        #expect(installer.list().count == 3)
        #expect(registry.loadedCount() == 3)
        let scopes = Set(registry.snapshot().map(\.scopeKey))
        #expect(scopes == ["code-quality", "security", "devops"])
    }

    @Test("After installing all three, SkillScanner surfaces each as source: pack")
    func scannerSurfacesPackSkills() throws {
        let base = Self.tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let installRoot = base.appendingPathComponent(".senkani/packs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: installRoot, withIntermediateDirectories: true)

        let (db, dbPath) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: dbPath) }
        let installer = PackInstaller(installRoot: installRoot, auditStore: db.packAuditStore)
        let registry = PackPolicyRegistry(installRoot: installRoot)
        try Self.withTestRegistry(registry) {
            _ = try Self.install("code-quality", installer: installer, registry: registry)
            _ = try Self.install("security", installer: installer, registry: registry)
            _ = try Self.install("devops", installer: installer, registry: registry)
        }

        // SkillScanner walks <home>/.senkani/packs/<pack>/skills/...,
        // so pointing homeDir at `base` (which contains .senkani/packs)
        // routes its sixth scan root onto our temp install.
        let skills = SkillScanner.scan(homeDir: base.path, cwd: base.path)
        let packSkills = skills.filter { $0.source == "pack" }
        let names = Set(packSkills.map(\.name))
        #expect(names == ["code-quality", "security", "devops"])
        #expect(packSkills.allSatisfy { $0.type == .skill })
    }

    @Test("code-quality deny fixture: eslint-disable-next-line is blocked at the hook")
    func codeQualityDeniesEslintSuppression() throws {
        let base = Self.tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let installRoot = base.appendingPathComponent("packs", isDirectory: true)
        let (db, dbPath) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: dbPath) }
        let installer = PackInstaller(installRoot: installRoot, auditStore: db.packAuditStore)
        let registry = PackPolicyRegistry(installRoot: installRoot)

        try Self.withTestRegistry(registry) {
            _ = try Self.install("code-quality", installer: installer, registry: registry)

            // An Edit that adds an eslint-disable-next-line comment.
            let event = Self.hookEvent(toolName: "Edit", toolInput: [
                "file_path": "/tmp/foo.js",
                "new_string": "// eslint-disable-next-line no-undef\nfoo();",
            ])
            let resp = HookRouter.handle(eventJSON: event)
            let reason = Self.denyReason(resp)
            #expect(reason != nil)
            #expect(reason?.contains("code-quality pack") == true)
            let r = reason ?? ""
            #expect(r.contains("eslint") || r.contains("ESLint"))
        }
    }

    @Test("security deny fixture: hard-coded API_KEY= is blocked at the hook")
    func securityDeniesHardCodedApiKey() throws {
        let base = Self.tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let installRoot = base.appendingPathComponent("packs", isDirectory: true)
        let (db, dbPath) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: dbPath) }
        let installer = PackInstaller(installRoot: installRoot, auditStore: db.packAuditStore)
        let registry = PackPolicyRegistry(installRoot: installRoot)

        try Self.withTestRegistry(registry) {
            _ = try Self.install("security", installer: installer, registry: registry)
            let event = Self.hookEvent(toolName: "Write", toolInput: [
                "file_path": "/tmp/cfg.env",
                "content": "API_KEY=hardcoded-bad-value\n",
            ])
            let resp = HookRouter.handle(eventJSON: event)
            let reason = Self.denyReason(resp)
            #expect(reason != nil)
            #expect(reason?.contains("security pack") == true)
        }
    }

    @Test("devops deny fixture: kubectl delete is blocked at the hook")
    func devopsDeniesKubectlDelete() throws {
        let base = Self.tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let installRoot = base.appendingPathComponent("packs", isDirectory: true)
        let (db, dbPath) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: dbPath) }
        let installer = PackInstaller(installRoot: installRoot, auditStore: db.packAuditStore)
        let registry = PackPolicyRegistry(installRoot: installRoot)

        try Self.withTestRegistry(registry) {
            _ = try Self.install("devops", installer: installer, registry: registry)
            let event = Self.hookEvent(toolName: "Bash", toolInput: [
                "command": "kubectl delete pod nginx-7d8c9",
            ])
            let resp = HookRouter.handle(eventJSON: event)
            let reason = Self.denyReason(resp)
            #expect(reason != nil)
            #expect(reason?.contains("devops pack") == true)
        }
    }

    @Test("devops deny fixture: --context=prod is blocked even on read verbs")
    func devopsDeniesProdContext() throws {
        let base = Self.tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let installRoot = base.appendingPathComponent("packs", isDirectory: true)
        let (db, dbPath) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: dbPath) }
        let installer = PackInstaller(installRoot: installRoot, auditStore: db.packAuditStore)
        let registry = PackPolicyRegistry(installRoot: installRoot)

        try Self.withTestRegistry(registry) {
            _ = try Self.install("devops", installer: installer, registry: registry)
            // Read-only verb but with the prod-context selector — the
            // pack denies because the selector itself triggers the
            // confirmation contract from the prod-namespace-guard phase.
            let event = Self.hookEvent(toolName: "Bash", toolInput: [
                "command": "kubectl --context=prod get pods",
            ])
            let resp = HookRouter.handle(eventJSON: event)
            let reason = Self.denyReason(resp)
            #expect(reason != nil)
            #expect(reason?.contains("devops pack") == true)
        }
    }

    @Test("Non-matching tool calls pass through pack policy without deny")
    func nonMatchingCallsPassThrough() throws {
        let base = Self.tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let installRoot = base.appendingPathComponent("packs", isDirectory: true)
        let (db, dbPath) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: dbPath) }
        let installer = PackInstaller(installRoot: installRoot, auditStore: db.packAuditStore)
        let registry = PackPolicyRegistry(installRoot: installRoot)

        try Self.withTestRegistry(registry) {
            _ = try Self.install("code-quality", installer: installer, registry: registry)
            _ = try Self.install("security", installer: installer, registry: registry)
            _ = try Self.install("devops", installer: installer, registry: registry)

            // Read-only kubectl get against staging — devops pack must
            // NOT deny. (The HookRouter still routes Bash to its
            // existing redirect, so we expect either passthrough or
            // a Bash-level redirect — but never a "devops pack" deny.)
            let event = Self.hookEvent(toolName: "Bash", toolInput: [
                "command": "kubectl --context=staging get pods",
            ])
            let resp = HookRouter.handle(eventJSON: event)
            let reason = Self.denyReason(resp)
            // Reason may or may not be nil (Bash redirect path can
            // emit one); the assertion is that NO pack-source reason
            // fires. All three pack reasons start with "<name> pack:".
            if let r = reason {
                #expect(!r.contains("devops pack:"))
                #expect(!r.contains("security pack:"))
                #expect(!r.contains("code-quality pack:"))
            }
        }
    }

    @Test("Uninstalling all three drops every rule and clears the SkillScanner pack source")
    func uninstallRoundTripIsClean() throws {
        let base = Self.tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let installRoot = base.appendingPathComponent(".senkani/packs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: installRoot, withIntermediateDirectories: true)

        let (db, dbPath) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: dbPath) }
        let installer = PackInstaller(installRoot: installRoot, auditStore: db.packAuditStore)
        let registry = PackPolicyRegistry(installRoot: installRoot)

        try Self.withTestRegistry(registry) {
            _ = try Self.install("code-quality", installer: installer, registry: registry)
            _ = try Self.install("security", installer: installer, registry: registry)
            _ = try Self.install("devops", installer: installer, registry: registry)
            #expect(registry.loadedCount() == 3)

            for name in ["code-quality", "security", "devops"] {
                _ = try installer.uninstall(name: name)
                registry.refresh()
            }
            #expect(registry.loadedCount() == 0)
            #expect(installer.list().isEmpty)

            // SkillScanner now surfaces zero pack-source skills.
            let skills = SkillScanner.scan(homeDir: base.path, cwd: base.path)
            #expect(skills.filter { $0.source == "pack" }.isEmpty)

            // Previously-denied tool calls now pass the pack-policy gate.
            // (Bash routing may still redirect, but no "devops pack:"
            // / "code-quality pack:" / "security pack:" reason should
            // fire from the pack-policy step.)
            let events: [(String, [String: Any])] = [
                ("Bash", ["command": "kubectl delete pod foo"]),
                ("Edit", [
                    "file_path": "/tmp/x.js",
                    "new_string": "// eslint-disable-next-line\n",
                ]),
                ("Write", [
                    "file_path": "/tmp/x.env",
                    "content": "API_KEY=abc\n",
                ]),
            ]
            for (tool, input) in events {
                let resp = HookRouter.handle(eventJSON: Self.hookEvent(
                    toolName: tool, toolInput: input))
                if let r = Self.denyReason(resp) {
                    #expect(!r.contains("pack:"))
                }
            }
        }
    }

    @Test("pack_audits chain stays clean across full install/uninstall round-trip")
    func chainStaysCleanThroughRoundTrip() throws {
        let base = Self.tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let installRoot = base.appendingPathComponent("packs", isDirectory: true)
        let (db, dbPath) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: dbPath) }
        let installer = PackInstaller(installRoot: installRoot, auditStore: db.packAuditStore)
        let registry = PackPolicyRegistry(installRoot: installRoot)

        try Self.withTestRegistry(registry) {
            for name in ["code-quality", "security", "devops"] {
                _ = try Self.install(name, installer: installer, registry: registry)
            }
            for name in ["code-quality", "security", "devops"] {
                _ = try installer.uninstall(name: name)
            }
        }

        let result = ChainVerifier.verifyPackAudits(db)
        guard case .ok = result else {
            Issue.record("pack_audits chain not OK after install/uninstall round-trip: \(result)")
            return
        }

        // verifyAll must include pack_audits and report it ok.
        let all = ChainVerifier.verifyAll(db)
        guard case .ok = all["pack_audits"] else {
            Issue.record("verifyAll missing or non-ok pack_audits: \(String(describing: all["pack_audits"]))")
            return
        }

        // 3 install + 3 uninstall = 6 chained rows in the audit store.
        #expect(db.packAuditStore.count() >= Int64(6))
    }

    @Test("Refresh after install and uninstall flips evaluate() between deny and pass")
    func refreshFlipsEvaluateInBothDirections() throws {
        let base = Self.tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let installRoot = base.appendingPathComponent("packs", isDirectory: true)
        let (db, dbPath) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: dbPath) }
        let installer = PackInstaller(installRoot: installRoot, auditStore: db.packAuditStore)
        let registry = PackPolicyRegistry(installRoot: installRoot)

        // Before any install, evaluate against a Bash command that
        // will eventually match returns nil.
        #expect(registry.evaluate(
            toolName: "Bash",
            toolInput: ["command": "kubectl delete pod foo"]) == nil)

        // Install + refresh → match.
        try Self.withTestRegistry(registry) {
            _ = try Self.install("devops", installer: installer, registry: registry)
            let m = registry.evaluate(
                toolName: "Bash",
                toolInput: ["command": "kubectl delete pod foo"])
            #expect(m != nil)
            #expect(m?.packName == "devops")
            #expect(m?.scopeKey == "devops")

            // Uninstall + refresh → no match again.
            _ = try installer.uninstall(name: "devops")
            registry.refresh()
            #expect(registry.evaluate(
                toolName: "Bash",
                toolInput: ["command": "kubectl delete pod foo"]) == nil)
        }
    }

    @Test("HookRouter.refreshInstalledPacks() is idempotent and safe to call repeatedly")
    func refreshInstalledPacksIsIdempotent() throws {
        let base = Self.tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let installRoot = base.appendingPathComponent("packs", isDirectory: true)
        let (db, dbPath) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: dbPath) }
        let installer = PackInstaller(installRoot: installRoot, auditStore: db.packAuditStore)
        let registry = PackPolicyRegistry(installRoot: installRoot)

        try Self.withTestRegistry(registry) {
            _ = try installer.install(sourceDir: Self.sourcePackDir("devops"))
            // PackInstaller.apply() called HookRouter.refreshInstalledPacks(),
            // which refreshed the seam-injected registry.
            #expect(registry.loadedCount() == 1)

            // Calling refresh repeatedly is a no-op for the count.
            for _ in 0 ..< 3 {
                HookRouter.refreshInstalledPacks()
            }
            #expect(registry.loadedCount() == 1)
        }
    }

    // MARK: - Per-pack content lints

    @Test("All three bundled pack manifests lint clean via HandManifestLinter")
    func bundledPackManifestsLintClean() throws {
        for name in ["code-quality", "security", "devops"] {
            let manifestPath = Self.sourcePackDir(name)
                .appendingPathComponent("skills/\(name)/manifest.json")
            let data = try Data(contentsOf: manifestPath)
            let issues = HandManifestLinter.lintJSON(data)
            #expect(!HandManifestLinter.hasErrors(issues),
                "manifest for pack '\(name)' has lint errors: \(issues)")
        }
    }

    @Test("Each bundled pack policy fragment carries ≥3 deny rules")
    func bundledPackPolicyHasThreeRules() throws {
        for name in ["code-quality", "security", "devops"] {
            let policyURL = Self.sourcePackDir(name)
                .appendingPathComponent("policy/hook_router.json")
            let fragment = try HookRouterFragmentParser.load(from: policyURL)
            #expect(fragment.scopeKey == name)
            #expect(fragment.rules.count >= 3,
                "pack '\(name)' policy has only \(fragment.rules.count) rule(s); acceptance requires ≥3")
            #expect(fragment.rules.allSatisfy { $0.kind == "deny" })
        }
    }

    @Test("Bundled pack scope keys are distinct so all three install side-by-side")
    func bundledPackScopeKeysAreDistinct() throws {
        var keys: [String] = []
        for name in ["code-quality", "security", "devops"] {
            let policyURL = Self.sourcePackDir(name)
                .appendingPathComponent("policy/hook_router.json")
            let fragment = try HookRouterFragmentParser.load(from: policyURL)
            keys.append(fragment.scopeKey)
        }
        #expect(Set(keys).count == keys.count, "pack scope keys collide: \(keys)")
    }

    @Test("Each pack's skill manifest carries two phases per the operator's V.11b decisions")
    func bundledPackManifestsHaveTwoPhases() throws {
        for name in ["code-quality", "security", "devops"] {
            let manifestPath = Self.sourcePackDir(name)
                .appendingPathComponent("skills/\(name)/manifest.json")
            let data = try Data(contentsOf: manifestPath)
            let manifest = try JSONDecoder().decode(HandManifest.self, from: data)
            #expect(manifest.systemPrompt.phases.count == 2,
                "pack '\(name)' should ship two phases (operator Q1+Q2/Q3/Q4 outcome)")
            #expect(manifest.systemPrompt.phases.allSatisfy {
                !$0.body.trimmingCharacters(in: .whitespaces).isEmpty
            })
        }
    }
}
