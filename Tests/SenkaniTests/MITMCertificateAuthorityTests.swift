import Foundation
import Testing
import Security
@testable import Core

/// T.1d-1 — MITM root CA + per-host leaf minting tests.
///
/// Every test uses a TEST-generated CA written to a fresh temp dir (NEVER
/// `~/.senkani`), and trust is validated with a custom `SecTrust`
/// evaluator anchored on the test CA (`SecTrustSetAnchorCertificates` +
/// `SecTrustEvaluateWithError`). No System/login Keychain mutation, no
/// `SecTrustSettings`, no default-keychain `SecItemAdd`.
@Suite struct MITMCertificateAuthorityTests {

    /// Fresh temp paths for an isolated CA — caller deletes the dir.
    private func tempPaths() -> (MITMCertificateAuthority.Paths, String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("senkani-mitm-test-\(UUID().uuidString)", isDirectory: true)
        let paths = MITMCertificateAuthority.Paths(
            publicCertPEM: dir.appendingPathComponent("egress-ca.pem").path,
            privateKeyPEM: dir.appendingPathComponent("egress-ca.key").path
        )
        return (paths, dir.path)
    }

    private func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: - 1. CA generation

    @Test func generatesRootCAThatDecodesAsX509() async throws {
        let (paths, dir) = tempPaths()
        defer { cleanup(dir) }
        let ca = MITMCertificateAuthority(paths: paths, keyBits: 2048)

        let root = try await ca.generateRoot()

        // Hand-rolled DER must decode as a real X.509 certificate.
        let cert = try #require(SecCertificateCreateWithData(nil, root.certificateDER as CFData))
        // Public cert PEM is on disk and re-decodes.
        #expect(FileManager.default.fileExists(atPath: paths.publicCertPEM))
        let pem = try String(contentsOfFile: paths.publicCertPEM, encoding: .utf8)
        #expect(pem.contains("-----BEGIN CERTIFICATE-----"))
        // CA subject summary contains the CN we asked for.
        let summary = SecCertificateCopySubjectSummary(cert) as String?
        #expect(summary?.contains("senkani") == true)
    }

    // MARK: - 2. 0600 key perms (separate file)

    @Test func caPrivateKeyIsSeparateFileMode0600() async throws {
        let (paths, dir) = tempPaths()
        defer { cleanup(dir) }
        let ca = MITMCertificateAuthority(paths: paths, keyBits: 2048)
        _ = try await ca.generateRoot()

        // Private key is a SEPARATE file from the public cert.
        #expect(paths.privateKeyPEM != paths.publicCertPEM)
        #expect(FileManager.default.fileExists(atPath: paths.privateKeyPEM))

        let attrs = try FileManager.default.attributesOfItem(atPath: paths.privateKeyPEM)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        #expect(perms == 0o600)

        // The public cert is NOT 0600 (it is public) — proves they are
        // genuinely distinct artifacts with distinct perms.
        let pubAttrs = try FileManager.default.attributesOfItem(atPath: paths.publicCertPEM)
        let pubPerms = (pubAttrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        #expect(pubPerms != 0o600)
    }

    // MARK: - 3. Leaf minting + cache hit

    @Test func mintsLeafForHostWithCorrectCNAndSANAndCaches() async throws {
        let (paths, dir) = tempPaths()
        defer { cleanup(dir) }
        let ca = MITMCertificateAuthority(paths: paths, keyBits: 2048)
        _ = try await ca.generateRoot()

        let host = "api.example.com"
        let leaf1 = try await ca.leaf(forHost: host)

        // Leaf decodes as X.509 and CN == host.
        let leafCert = try #require(SecCertificateCreateWithData(nil, leaf1.certificateDER as CFData))
        let cn = SecCertificateCopySubjectSummary(leafCert) as String?
        #expect(cn == host)

        // Cache: second mint of same host returns identical DER + count==1.
        let countAfterFirst = await ca.cachedLeafCount
        #expect(countAfterFirst == 1)
        let leaf2 = try await ca.leaf(forHost: host)
        #expect(leaf2.certificateDER == leaf1.certificateDER)
        let countAfterSecond = await ca.cachedLeafCount
        #expect(countAfterSecond == 1)

        // A different host mints a distinct leaf.
        let other = try await ca.leaf(forHost: "other.example.org")
        #expect(other.certificateDER != leaf1.certificateDER)
        let countAfterOther = await ca.cachedLeafCount
        #expect(countAfterOther == 2)
    }

    // MARK: - 4. Leaf chains to CA under a CUSTOM SecTrust evaluator

    @Test func leafChainsToTestCAUnderCustomTrustAnchor() async throws {
        let (paths, dir) = tempPaths()
        defer { cleanup(dir) }
        let ca = MITMCertificateAuthority(paths: paths, keyBits: 2048)
        _ = try await ca.generateRoot()

        let host = "trust.example.com"
        let leaf = try await ca.leaf(forHost: host)
        let caCert = try await ca.caCertificate()
        let leafCert = try #require(SecCertificateCreateWithData(nil, leaf.certificateDER as CFData))

        // Build a SecTrust over [leaf, ca] with an SSL policy for `host`.
        let policy = SecPolicyCreateSSL(true, host as CFString)
        var trust: SecTrust?
        let createStatus = SecTrustCreateWithCertificates([leafCert, caCert] as CFArray, policy, &trust)
        #expect(createStatus == errSecSuccess)
        let t = try #require(trust)

        // Anchor ONLY on our test CA (custom evaluator) — never the System
        // trust store. SecTrustSetAnchorCertificatesOnly seals it.
        #expect(SecTrustSetAnchorCertificates(t, [caCert] as CFArray) == errSecSuccess)
        #expect(SecTrustSetAnchorCertificatesOnly(t, true) == errSecSuccess)

        var error: CFError?
        let ok = SecTrustEvaluateWithError(t, &error)
        if !ok {
            Issue.record("trust eval failed: \(String(describing: error))")
        }
        #expect(ok)
    }

    // MARK: - 5. SecIdentity load round-trip (ephemeral keychain only)

    @Test func leafPKCS12LoadsAsSecIdentity() async throws {
        let (paths, dir) = tempPaths()
        defer { cleanup(dir) }
        let ca = MITMCertificateAuthority(paths: paths, keyBits: 2048)
        _ = try await ca.generateRoot()

        let leaf = try await ca.leaf(forHost: "identity.example.com")
        #expect(!leaf.pkcs12.isEmpty)

        // Load the PKCS#12 into an ephemeral keychain → SecIdentity.
        let identity = try MITMCertificateAuthority.loadIdentity(from: leaf.pkcs12)

        // The identity yields both a private key and the leaf certificate.
        var privKey: SecKey?
        #expect(SecIdentityCopyPrivateKey(identity, &privKey) == errSecSuccess)
        #expect(privKey != nil)

        var certOut: SecCertificate?
        #expect(SecIdentityCopyCertificate(identity, &certOut) == errSecSuccess)
        let idCert = try #require(certOut)
        let cn = SecCertificateCopySubjectSummary(idCert) as String?
        #expect(cn == "identity.example.com")
    }

    // MARK: - 6. ensureRoot persists once, reloads from disk

    @Test func ensureRootReloadsExistingCAFromDisk() async throws {
        let (paths, dir) = tempPaths()
        defer { cleanup(dir) }

        // First authority generates + persists.
        let ca1 = MITMCertificateAuthority(paths: paths, keyBits: 2048)
        let root1 = try await ca1.ensureRoot()

        // Second authority (fresh actor) loads the SAME bytes from disk.
        let ca2 = MITMCertificateAuthority(paths: paths, keyBits: 2048)
        let root2 = try await ca2.ensureRoot()
        #expect(root1.certificateDER == root2.certificateDER)

        // And a leaf minted by the reloaded CA still chains to it.
        let leaf = try await ca2.leaf(forHost: "reload.example.com")
        let caCert = try await ca2.caCertificate()
        let leafCert = try #require(SecCertificateCreateWithData(nil, leaf.certificateDER as CFData))
        let policy = SecPolicyCreateSSL(true, "reload.example.com" as CFString)
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates([leafCert, caCert] as CFArray, policy, &trust) == errSecSuccess)
        let t = try #require(trust)
        #expect(SecTrustSetAnchorCertificates(t, [caCert] as CFArray) == errSecSuccess)
        #expect(SecTrustSetAnchorCertificatesOnly(t, true) == errSecSuccess)
        var error: CFError?
        let ok = SecTrustEvaluateWithError(t, &error)
        if !ok { Issue.record("reloaded-CA trust eval failed: \(String(describing: error))") }
        #expect(ok)
    }

    // MARK: - DER encoder unit checks (deterministic, no Security calls)

    @Test func derLengthEncodingShortAndLong() {
        #expect(DEREncoder.encodeLength(0) == [0x00])
        #expect(DEREncoder.encodeLength(127) == [0x7F])
        #expect(DEREncoder.encodeLength(128) == [0x81, 0x80])
        #expect(DEREncoder.encodeLength(256) == [0x82, 0x01, 0x00])
    }

    @Test func derIntegerAddsLeadingZeroForHighBit() {
        // 0x80 must become 02 02 00 80 (positive INTEGER).
        let enc = DEREncoder.integer(Data([0x80]))
        #expect([UInt8](enc) == [0x02, 0x02, 0x00, 0x80])
    }

    @Test func derOIDEncodesSha256WithRSA() {
        // sha256WithRSAEncryption OID 1.2.840.113549.1.1.11 inner bytes.
        let oid = DEREncoder.oid([1, 2, 840, 113549, 1, 1, 11])
        #expect([UInt8](oid) == [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B])
    }
}
