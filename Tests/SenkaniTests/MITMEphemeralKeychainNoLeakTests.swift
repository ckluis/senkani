import Testing
import Foundation
@testable import Core

/// Non-racy no-leak coverage for `MITMCertificateAuthority.makeEphemeralKeychain`'s
/// `defer { unlink }` guarantee (process-gap-ephemeral-keychain-noleak-test-race-2026-05-31).
///
/// The racy `strayEphemeralKeychainCount()` global-count assertion was
/// removed during the phase-t1d-2a round because it read the SHARED
/// `NSTemporaryDirectory()` and any concurrent test minting a leaf
/// polluted the count. This restores no-leak coverage via PER-CALL
/// DIRECTORY ISOLATION: each test points its mint at its own unique
/// temp directory, so the dir's `senkani-mitm-*.keychain` count is a
/// proof-of-cleanup with zero cross-test interference — structurally
/// race-free (the production `NSTemporaryDirectory()` default path is
/// what concurrent tests still use; this isolated dir is unique to this
/// test's calls). Single-run green is sufficient: per-dir isolation
/// makes the `≥5 consecutive parallel runs` flake-verification of the
/// removed approach moot.
///
/// Default-callable (no-arg) production sites — `loadIdentity`,
/// `mintLeaf` → `exportPKCS12`, `loadIdentityViaEphemeralKeychain` — are
/// unchanged: the new `keychainDir:` parameter defaults to nil, which
/// falls back to `NSTemporaryDirectory()` inside `makeEphemeralKeychain`.
@Suite("MITM ephemeral-keychain no-leak (per-dir isolation)")
struct MITMEphemeralKeychainNoLeakTests {

    private static func uniqueTempDir() throws -> String {
        let base = NSTemporaryDirectory() as NSString
        let dir = base.appendingPathComponent("senkani-mitm-noleak-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        return dir
    }

    /// Count `senkani-mitm-*.keychain` files in `dir`. Non-recursive.
    private static func strayCount(in dir: String) throws -> Int {
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir)
        return entries.filter { $0.hasPrefix("senkani-mitm-") && $0.hasSuffix(".keychain") }.count
    }

    /// Drive `makeEphemeralKeychain` directly against an isolated dir,
    /// then mirror the caller contract (`SecKeychainDelete` +
    /// `unlink(path)`) — the same defer that `exportPKCS12` and
    /// `loadIdentityViaEphemeralKeychain` run. After the cleanup, the
    /// isolated dir must contain ZERO stray keychain files. This is the
    /// structural proof of the unlink contract; per-dir isolation makes
    /// it race-free regardless of how many parallel tests are also
    /// minting into the shared `NSTemporaryDirectory()`.
    @Test("makeEphemeralKeychain + caller-contract cleanup leaves no stray keychain file")
    func ephemeralKeychainCleanupLeavesNoStrayInIsolatedDir() throws {
        let dir = try Self.uniqueTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // Mint N keychains into the isolated dir; mirror the caller's
        // defer block for each one.
        for _ in 0..<3 {
            let (keychain, path) = try MITMCertificateAuthority.makeEphemeralKeychain(directory: dir)
            SecKeychainDelete(keychain)
            unlink(path)
        }
        #expect(try Self.strayCount(in: dir) == 0)
    }

    /// `exportPKCS12` end-to-end against the isolated dir: drive the
    /// public PKCS#12 export path with `keychainDir:` set, and confirm
    /// the dir is empty afterwards. Uses a CA-actor-minted leaf so we
    /// pass a real (issuer-signed) certificate to the exporter.
    @Test("exportPKCS12 with keychainDir leaves no stray in the isolated dir")
    func exportPKCS12WithIsolatedDirLeavesNoStray() async throws {
        let dir = try Self.uniqueTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // Mint a CA + leaf using the same actor production uses; this
        // gives us a properly chained certificate without rebuilding the
        // X.509 hand-encoding inside the test.
        let ca = MITMCertificateAuthority()
        let leaf = try await ca.leaf(forHost: "test-noleak.example.invalid")

        _ = try MITMCertificateAuthority.exportPKCS12(
            certDER: leaf.certificateDER,
            privateKey: leaf.privateKey,
            passphrase: MITMCertificateAuthority.p12Passphrase,
            keychainDir: dir
        )
        #expect(try Self.strayCount(in: dir) == 0)
    }

    /// The macOS-14-floor `loadIdentityViaEphemeralKeychain` path with
    /// `keychainDir:` set leaves no stray in the isolated dir. Tests run
    /// on the macOS-15+ toolchain (which would normally take the
    /// memory-only branch via `loadIdentity` dispatch), so we call the
    /// named floor helper directly — it's runtime-exercisable on 15+
    /// per the helper's own docstring.
    @Test("loadIdentityViaEphemeralKeychain with keychainDir leaves no stray in the isolated dir")
    func loadIdentityViaEphemeralKeychainWithIsolatedDirLeavesNoStray() async throws {
        let dir = try Self.uniqueTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let ca = MITMCertificateAuthority()
        let leaf = try await ca.leaf(forHost: "test-noleak-load.example.invalid")

        _ = try MITMCertificateAuthority.loadIdentityViaEphemeralKeychain(
            from: leaf.pkcs12,
            keychainDir: dir
        )
        // Note: leaf.pkcs12 was constructed via the no-arg exportPKCS12
        // path (NSTemporaryDirectory()) — its keychain landed in the
        // SHARED temp dir and was cleaned by its OWN defer; that mint
        // does NOT touch our isolated `dir`. The only call here that
        // writes into `dir` is loadIdentityViaEphemeralKeychain above.
        #expect(try Self.strayCount(in: dir) == 0)
    }
}
