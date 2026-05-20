import Testing
import Foundation
import CryptoKit
@testable import Core

/// T.2c-1 — AnonymizationProxy + SurrogateVault + EngagementContext
/// core. Acceptance-driven coverage:
///   - outboundScrubReplacesPIIWithSurrogates
///   - surrogateReuseWithinEngagement
///   - inboundRewriteBackRestoresOriginal (JSON-quoted + code-fenced)
///   - engagementIsolation (two disjoint vaults, counter independence)
@Suite("AnonymizationProxy")
struct AnonymizationProxyTests {

    /// Deterministic span emitter: maps a known fixture sentence to
    /// the spans the real PIIClassifier would surface. Decouples
    /// the proxy from the T.2b backend gate.
    private struct StubEmitter: PIISpanEmitter {
        /// Each entry: (literal substring, category). The stub
        /// scans the input top-to-bottom, emitting spans in source
        /// order. Reuse of the same literal within the input
        /// produces multiple spans (one per occurrence) so the
        /// proxy's reuse-by-original-value path is exercised.
        let fixtures: [(String, String)]

        func spans(in text: String, threshold: Double) async throws -> [AnonymizationSpan] {
            var spans: [AnonymizationSpan] = []
            for (needle, category) in fixtures {
                var searchStart = text.startIndex
                while searchStart < text.endIndex,
                      let r = text.range(of: needle, range: searchStart..<text.endIndex) {
                    spans.append(AnonymizationSpan(range: r, category: category, text: needle))
                    searchStart = r.upperBound
                }
            }
            // Source-order — sort by lowerBound.
            spans.sort { $0.range.lowerBound < $1.range.lowerBound }
            return spans
        }
    }

    /// Hermetic engagement: tmp dir for vault, random fallback key
    /// (no Keychain hit). Returns the context + vault both wired.
    private func makeEngagement(
        id: String = UUID().uuidString,
        root: URL = uniqueTmpDir(),
        threshold: Double = 0.85
    ) async throws -> (EngagementContext, SurrogateVault, URL) {
        // Force fallback path by using a CredentialVault backed by
        // an empty store — `read` throws missingKey, provider falls
        // back to the random keystore at <root>/.keys.
        let vault = CredentialVault(store: InMemoryKeychainStore())
        let provider = EngagementContextProvider(
            credentialVault: vault,
            root: root
        )
        let (context, source) = try await provider.makeContext(
            id: id,
            sensitivityThreshold: threshold
        )
        let surrogateVault = try SurrogateVault(context: context, keySource: source)
        return (context, surrogateVault, root)
    }

    private static func uniqueTmpDir() -> URL {
        let url = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("senkani-anon-\(UUID().uuidString)", isDirectory: true)
        return url
    }

    @Test("outboundScrubReplacesPIIWithSurrogates")
    func outboundScrubReplacesPIIWithSurrogates() async throws {
        let (ctx, vault, _) = try await makeEngagement()
        let emitter = StubEmitter(fixtures: [
            ("Harry Potter", "PRIVATE_PERSON"),
            ("harry@hogwarts.edu", "PRIVATE_EMAIL"),
        ])
        let proxy = AnonymizationProxy(engagement: ctx, vault: vault, emitter: emitter)
        let result = try await proxy.scrubOutbound("Harry Potter, harry@hogwarts.edu")
        #expect(result.scrubbed == "PRIVATE_PERSON_001, PRIVATE_EMAIL_001")
        // Allocations enumerate first-seen order.
        #expect(result.surrogates.count == 2)
        #expect(result.surrogates[0].surrogateID == "PRIVATE_PERSON_001")
        #expect(result.surrogates[0].originalValue == "Harry Potter")
        #expect(result.surrogates[1].surrogateID == "PRIVATE_EMAIL_001")
        #expect(result.surrogates[1].originalValue == "harry@hogwarts.edu")
    }

    @Test("surrogateReuseWithinEngagement")
    func surrogateReuseWithinEngagement() async throws {
        let (ctx, vault, _) = try await makeEngagement()
        let emitter = StubEmitter(fixtures: [
            ("Harry Potter", "PRIVATE_PERSON"),
        ])
        let proxy = AnonymizationProxy(engagement: ctx, vault: vault, emitter: emitter)
        let first = try await proxy.scrubOutbound("Hello, Harry Potter.")
        #expect(first.scrubbed == "Hello, PRIVATE_PERSON_001.")
        let second = try await proxy.scrubOutbound("Harry Potter is here.")
        #expect(second.scrubbed == "PRIVATE_PERSON_001 is here.")
        // Second call's allocation list has the SAME surrogate id —
        // reuse, not a new allocation. Acceptance: second mention
        // returns `_001`, not `_002`.
        #expect(second.surrogates.count == 1)
        #expect(second.surrogates[0].surrogateID == "PRIVATE_PERSON_001")
        // Counter has NOT advanced — the next fresh allocation in
        // this category would still be `_002`.
        #expect(await vault.peekNextCounter(category: "PRIVATE_PERSON") == 2)
        // Total rows on disk == 1.
        #expect(try await vault.count() == 1)
    }

    @Test("inboundRewriteBackRestoresOriginal — bare, JSON-quoted, code-fenced")
    func inboundRewriteBackRestoresOriginal() async throws {
        let (ctx, vault, _) = try await makeEngagement()
        let emitter = StubEmitter(fixtures: [
            ("Harry Potter", "PRIVATE_PERSON"),
            ("harry@hogwarts.edu", "PRIVATE_EMAIL"),
        ])
        let proxy = AnonymizationProxy(engagement: ctx, vault: vault, emitter: emitter)

        // Prime the vault by scrubbing once so both surrogate ids
        // are registered.
        _ = try await proxy.scrubOutbound("Harry Potter, harry@hogwarts.edu")

        // Bare token.
        let bare = try await proxy.rewriteInbound("Reply to PRIVATE_PERSON_001 soon.")
        #expect(bare == "Reply to Harry Potter soon.")

        // JSON-quoted token — the surrogate id is wrapped in
        // double-quotes. Word-boundary anchoring must restore the
        // original inside the quotes without mangling them.
        let jsonPayload = "{\"to\": \"PRIVATE_PERSON_001\", \"email\": \"PRIVATE_EMAIL_001\"}"
        let jsonRestored = try await proxy.rewriteInbound(jsonPayload)
        #expect(jsonRestored == "{\"to\": \"Harry Potter\", \"email\": \"harry@hogwarts.edu\"}")

        // Code-fenced token — backtick wrapping. Word-boundary
        // matches the alphanumeric/underscore boundary on either
        // side of the surrogate id.
        let codeFenced = "Try `PRIVATE_PERSON_001` for the test fixture."
        let codeRestored = try await proxy.rewriteInbound(codeFenced)
        #expect(codeRestored == "Try `Harry Potter` for the test fixture.")
    }

    @Test("engagementIsolation — two engagements, disjoint vaults, independent counters, disjoint keys")
    func engagementIsolation() async throws {
        let (ctxA, vaultA, rootA) = try await makeEngagement(id: "engagement-A")
        let (ctxB, vaultB, rootB) = try await makeEngagement(id: "engagement-B")

        // The roots are disjoint by construction (each tmp dir is
        // unique); the vault paths must therefore be disjoint too.
        #expect(rootA != rootB)
        #expect(ctxA.vaultPath != ctxB.vaultPath)

        let emitter = StubEmitter(fixtures: [
            ("Harry Potter", "PRIVATE_PERSON"),
        ])
        let proxyA = AnonymizationProxy(engagement: ctxA, vault: vaultA, emitter: emitter)
        let proxyB = AnonymizationProxy(engagement: ctxB, vault: vaultB, emitter: emitter)

        let resultA = try await proxyA.scrubOutbound("Harry Potter sends his regards.")
        let resultB = try await proxyB.scrubOutbound("Harry Potter again.")

        // Both engagements independently allocate `_001`. Per
        // Schneier (Notes): a leak of vault A cannot deanonymize
        // vault B because the per-engagement keys differ.
        #expect(resultA.scrubbed == "PRIVATE_PERSON_001 sends his regards.")
        #expect(resultB.scrubbed == "PRIVATE_PERSON_001 again.")

        // Keys differ — comparing the raw bytes proves random-
        // fallback minted independent keys per engagement.
        let keyABytes = ctxA.key.withUnsafeBytes { Data($0) }
        let keyBBytes = ctxB.key.withUnsafeBytes { Data($0) }
        #expect(keyABytes != keyBBytes)

        // Vault files are mode 0600.
        let attrsA = try FileManager.default.attributesOfItem(atPath: ctxA.vaultPath.path)
        let attrsB = try FileManager.default.attributesOfItem(atPath: ctxB.vaultPath.path)
        let modeA = (attrsA[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let modeB = (attrsB[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(modeA == 0o600)
        #expect(modeB == 0o600)

        // At-rest encryption: the literal "Harry Potter" must NOT
        // appear anywhere in vault A's raw SQLite file bytes.
        let rawA = try Data(contentsOf: ctxA.vaultPath)
        #expect(rawA.range(of: Data("Harry Potter".utf8)) == nil)

        // meta.key_source recorded the provenance accurately. Both
        // engagements used the random-fallback path (no Keychain
        // entry seeded in the test fixture).
        #expect(try await vaultA.getMeta("key_source") == "fallback_random")
        #expect(try await vaultB.getMeta("key_source") == "fallback_random")
        #expect(try await vaultA.getMeta("engagement_id") == "engagement-A")
        #expect(try await vaultB.getMeta("engagement_id") == "engagement-B")
    }

    @Test("EngagementContextProvider records credential_vault provenance when key is seeded")
    func keySourceFromCredentialVault() async throws {
        let store = InMemoryKeychainStore()
        // Seed a 32-byte vault key under engagement scope.
        let seeded = Data((0..<32).map { UInt8($0) })
        try await store.write(
            key: EngagementContextProvider.credentialVaultKey,
            scope: "engagement-seeded",
            value: seeded
        )
        let credentialVault = CredentialVault(store: store)
        let root = Self.uniqueTmpDir()
        let provider = EngagementContextProvider(credentialVault: credentialVault, root: root)
        let (ctx, source) = try await provider.makeContext(
            id: "seeded",
            sensitivityThreshold: 0.85
        )
        #expect(source == .credentialVault)
        let key = ctx.key.withUnsafeBytes { Data($0) }
        #expect(key == seeded)
        let vault = try SurrogateVault(context: ctx, keySource: source)
        #expect(try await vault.getMeta("key_source") == "credential_vault")
    }
}
