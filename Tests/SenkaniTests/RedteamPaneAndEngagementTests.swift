import Testing
import Foundation
import SQLite3
@testable import Core

/// T.2c-2 — redteam pane wiring + outbound-egress block + audit-chain
/// surrogate_writes row + engagement-end rewrite-back-disable.
/// Acceptance-driven coverage:
///   - redteamModeDropsThreshold
///   - redteamModeBlocksRemoteEgress
///   - engagementEndDisablesRewriteBack
///   - auditChainIntegrityAcross1kSurrogateWrites
@Suite("T.2c-2 redteam pane + engagement CLI + audit chain")
struct RedteamPaneAndEngagementTests {

    // MARK: - Stubs and fixtures

    /// Deterministic L3 inference seam: emits a "Tom Riddle" span if
    /// and only if the per-pane threshold is at or below the
    /// configured `confidence` floor. Models the real classifier's
    /// behavior: lower threshold → catches lower-confidence spans.
    private struct ConfidenceBasedLayer3 {
        let confidence: Float

        func makeSeam() -> Layer3Inference {
            let conf = self.confidence
            return Layer3Inference { text, threshold in
                guard Double(conf) >= threshold else { return [] }
                guard let range = text.range(of: "Tom Riddle") else { return [] }
                let charStart = text.distance(from: text.startIndex, to: range.lowerBound)
                let charEnd = text.distance(from: text.startIndex, to: range.upperBound)
                return [PIISpan(
                    category: .privatePerson,
                    score: conf,
                    charStart: charStart,
                    charEnd: charEnd,
                    text: "Tom Riddle"
                )]
            }
        }
    }

    /// Hermetic engagement: tmp dir for vault, random fallback key
    /// (no Keychain hit).
    private func makeEngagement(
        id: String = UUID().uuidString
    ) async throws -> (EngagementContext, SurrogateVault, URL) {
        let root = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("senkani-t2c2-\(UUID().uuidString)", isDirectory: true)
        let credentialVault = CredentialVault(store: InMemoryKeychainStore())
        let provider = EngagementContextProvider(
            credentialVault: credentialVault,
            root: root
        )
        let (context, source) = try await provider.makeContext(
            id: id,
            sensitivityThreshold: 0.85
        )
        let vault = try SurrogateVault(context: context, keySource: source)
        return (context, vault, root)
    }

    private static func makeDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-t2c2-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        return (db, path)
    }

    // MARK: - Test 1 — threshold drop

    @Test("redteamModeDropsThreshold — span scoring 0.75 caught at redteam, missed at default")
    func redteamModeDropsThreshold() async throws {
        let seam = ConfidenceBasedLayer3(confidence: 0.75).makeSeam()
        let pipeline = FilterPipeline(
            config: FeatureConfig(filter: false, secrets: true, terse: false, injectionGuard: false),
            layer3: seam,
            layer3StatusProvider: { .verified }
        )
        Layer3GateState.shared._resetForTests()

        // Default pane (threshold 0.85): the 0.75-confidence span is
        // BELOW the floor → no Layer 3 redaction → "Tom Riddle"
        // stays in the output.
        let defaultResult = pipeline.process(
            command: "echo",
            output: "Tom Riddle whispered.",
            paneMode: .default
        )
        #expect(defaultResult.output.contains("Tom Riddle"))

        // Redteam pane (threshold 0.70): the 0.75-confidence span
        // CLEARS the floor → Layer 3 redacts → "Tom Riddle" is
        // replaced with the category sentinel.
        Layer3GateState.shared._resetForTests()
        let redteamResult = pipeline.process(
            command: "echo",
            output: "Tom Riddle whispered.",
            paneMode: .redteam
        )
        #expect(!redteamResult.output.contains("Tom Riddle"))
        #expect(redteamResult.secretsFound.contains { $0.contains("PRIVATE_PERSON") })
        #expect(redteamResult.output.contains("[REDACTED:PII_PRIVATE_PERSON]"))
    }

    // MARK: - Test 2 — outbound-egress block

    @Test("redteamModeBlocksRemoteEgress — non-local tier dispatch raises RedteamPaneEgressBlocked")
    func redteamModeBlocksRemoteEgress() throws {
        // Remote tiers (quick/balanced/frontier) all raise under .redteam.
        for tier in [ModelTier.quick, .balanced, .frontier] {
            do {
                try RedteamEgressGuard.enforce(paneMode: .redteam, tier: tier)
                Issue.record("expected RedteamPaneEgressBlocked for tier \(tier.rawValue)")
            } catch let err as RedteamPaneEgressBlocked {
                #expect(err.tier == tier)
            } catch {
                Issue.record("expected RedteamPaneEgressBlocked, got \(error)")
            }
        }

        // .local tier is permitted (on-device, no egress).
        try RedteamEgressGuard.enforce(paneMode: .redteam, tier: .local)

        // Non-redteam panes are permitted on every tier.
        for pane in [PaneMode.general, .research, .write] {
            for tier in [ModelTier.local, .quick, .balanced, .frontier] {
                try RedteamEgressGuard.enforce(paneMode: pane, tier: tier)
            }
        }
    }

    // MARK: - Test 3 — engagement-end disables rewrite-back

    @Test("engagementEndDisablesRewriteBack — closed engagement renders surrogates literally")
    func engagementEndDisablesRewriteBack() async throws {
        let (ctx, vault, _) = try await makeEngagement(id: "engagement-end-test")
        let emitter = SimpleStubEmitter(needle: "Voldemort", category: "PRIVATE_PERSON")
        let proxy = AnonymizationProxy(engagement: ctx, vault: vault, emitter: emitter)

        // Outbound: scrubs to PRIVATE_PERSON_001.
        let scrubbed = try await proxy.scrubOutbound("Voldemort is here.")
        #expect(scrubbed.scrubbed == "PRIVATE_PERSON_001 is here.")

        // Pre-close: inbound rewrite restores the original.
        let restored = try await proxy.rewriteInbound("PRIVATE_PERSON_001 is here.")
        #expect(restored == "Voldemort is here.")

        // Close the engagement.
        let stamp = try await vault.markClosed()
        #expect(!stamp.isEmpty)
        #expect(try await vault.isClosed() == true)

        // Post-close: rewrite-back is disabled — the model output
        // containing PRIVATE_PERSON_001 surfaces to the operator
        // literally (audit-trail boundary per Cavoukian).
        let literalRender = try await proxy.rewriteInbound("Response from model: PRIVATE_PERSON_001 lives here.")
        #expect(literalRender == "Response from model: PRIVATE_PERSON_001 lives here.")
    }

    // MARK: - Test 4 — chain integrity across 1k allocations

    @Test("auditChainIntegrityAcross1kSurrogateWrites — 1000-row chain verifies green")
    func auditChainIntegrityAcross1kSurrogateWrites() {
        let (db, path) = Self.makeDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let engagementID = "chain-stress-engagement"
        for i in 0..<1000 {
            let category = (i % 2 == 0) ? "PRIVATE_PERSON" : "PRIVATE_EMAIL"
            let surrogateID = String(format: "\(category)_%03d", (i / 2) + 1)
            let ok = db.surrogateWritesStore.record(
                engagementID: engagementID,
                surrogateID: surrogateID,
                category: category,
                at: Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
            )
            #expect(ok)
        }
        db.flushWrites()

        // Verify the chain end-to-end.
        let result = ChainVerifier.verifySurrogateWrites(db)
        guard case .ok = result else {
            Issue.record("expected .ok, got \(result)")
            return
        }

        // Confirm row count matches what we recorded.
        #expect(db.surrogateWritesStore.count() == 1000)

        // Sanity: the table participates in `verifyAll`.
        let allResults = ChainVerifier.verifyAll(db)
        #expect(allResults["surrogate_writes"] != nil)
    }
}

/// Minimal stub emitter: emits one span per occurrence of `needle`.
/// Local to this suite — keeps the test file self-contained without
/// reaching into `AnonymizationProxyTests`'s internal helper.
private struct SimpleStubEmitter: PIISpanEmitter {
    let needle: String
    let category: String
    func spans(in text: String, threshold: Double) async throws -> [AnonymizationSpan] {
        var out: [AnonymizationSpan] = []
        var search = text.startIndex
        while search < text.endIndex,
              let r = text.range(of: needle, range: search..<text.endIndex) {
            out.append(AnonymizationSpan(range: r, category: category, text: needle))
            search = r.upperBound
        }
        return out
    }
}
