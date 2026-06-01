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

    // MARK: - 7. Leaf carries SKI + AKI; AKI matches the CA's SKI

    /// Find `needle` in `der` and return the `count` bytes immediately
    /// following it (nil if absent / truncated). The SKI/AKI extension DER
    /// prefix is fixed-width for a 20-byte SHA-1 key id, so this pulls the
    /// key id out without a full ASN.1 parser.
    private func bytesFollowing(_ needle: [UInt8], in der: Data, count: Int) -> Data? {
        let hay = [UInt8](der)
        guard needle.count > 0, needle.count <= hay.count else { return nil }
        var i = 0
        while i + needle.count <= hay.count {
            if Array(hay[i..<(i + needle.count)]) == needle {
                let s = i + needle.count
                guard s + count <= hay.count else { return nil }
                return Data(hay[s..<(s + count)])
            }
            i += 1
        }
        return nil
    }

    @Test func leafCarriesSKIAndAKIMatchingCASubjectKeyId() async throws {
        let (paths, dir) = tempPaths()
        defer { cleanup(dir) }
        let ca = MITMCertificateAuthority(paths: paths, keyBits: 2048)
        _ = try await ca.generateRoot()

        let host = "strict.example.com"
        let leaf = try await ca.leaf(forHost: host)
        let caCert = try await ca.caCertificate()
        let caDER = SecCertificateCopyData(caCert) as Data

        // SHA-1 key id is 20 bytes, so the extension DER prefixes are fixed.
        //   SKI ext: 06 03 55 1D 0E  04 16  04 14  <20-byte keyID>
        //   AKI ext: 06 03 55 1D 23  04 18  30 16  80 14  <20-byte keyID>
        let skiPrefix: [UInt8] = [0x06, 0x03, 0x55, 0x1D, 0x0E, 0x04, 0x16, 0x04, 0x14]
        let akiPrefix: [UInt8] = [0x06, 0x03, 0x55, 0x1D, 0x23, 0x04, 0x18, 0x30, 0x16, 0x80, 0x14]

        // CA root has an SKI (shipped with the cert-minting round).
        let caSKI = try #require(
            bytesFollowing(skiPrefix, in: caDER, count: 20),
            "CA root cert is missing a Subject Key Identifier extension"
        )
        // Leaf has its OWN SKI...
        let leafSKI = try #require(
            bytesFollowing(skiPrefix, in: leaf.certificateDER, count: 20),
            "leaf cert is missing a Subject Key Identifier extension"
        )
        // ...and an AKI whose keyIdentifier equals the CA's SKI (RFC 5280
        // §4.2.1.1) — this is what fixes OpenSSL strict error 85.
        let leafAKI = try #require(
            bytesFollowing(akiPrefix, in: leaf.certificateDER, count: 20),
            "leaf cert is missing an Authority Key Identifier extension"
        )
        #expect(leafAKI == caSKI, "leaf AKI must point at the CA's SKI")
        #expect(leafSKI != caSKI, "leaf SKI is its own key id, distinct from the CA's")

        // No regression: the leaf still decodes as a real X.509 cert.
        #expect(SecCertificateCreateWithData(nil, leaf.certificateDER as CFData) != nil)

        // Best-effort cross-check: if a REAL OpenSSL (>= 3, not LibreSSL) is
        // on the box, `openssl verify -x509_strict` must ACCEPT the leaf with
        // the test CA as -CAfile (no error 85). LibreSSL / absence → skipped;
        // the in-process DER assertions above are the authoritative check.
        if let openssl = Self.realOpenSSLPath() {
            let leafPEM = MITMCertificateAuthority.pemEncode(leaf.certificateDER, label: "CERTIFICATE")
            let leafPath = (dir as NSString).appendingPathComponent("leaf.pem")
            try leafPEM.write(toFile: leafPath, atomically: true, encoding: .utf8)

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: openssl)
            proc.arguments = ["verify", "-x509_strict", "-CAfile", paths.publicCertPEM, leafPath]
            let out = Pipe(); let err = Pipe()
            proc.standardOutput = out
            proc.standardError = err
            try proc.run()
            proc.waitUntilExit()
            let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if proc.terminationStatus != 0 {
                Issue.record("openssl -x509_strict rejected the leaf: status=\(proc.terminationStatus) stdout=\(stdout) stderr=\(stderr)")
            }
            #expect(proc.terminationStatus == 0)
            #expect(stdout.contains("OK") || stdout.contains("\(leafPath): OK"))
        }
    }

    /// Locate a genuine OpenSSL (>= 3) on PATH-ish candidate locations. macOS
    /// ships LibreSSL as `/usr/bin/openssl`, whose `-x509_strict` semantics
    /// differ and do NOT emit error 85, so we deliberately skip it. Returns
    /// nil if no real OpenSSL is found (test then relies on DER assertions).
    private static func realOpenSSLPath() -> String? {
        let candidates = [
            "/opt/homebrew/opt/openssl@3/bin/openssl",
            "/opt/homebrew/bin/openssl",
            "/usr/local/opt/openssl@3/bin/openssl",
            "/usr/local/bin/openssl",
        ]
        for path in candidates {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = ["version"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            guard (try? proc.run()) != nil else { continue }
            proc.waitUntilExit()
            let version = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if version.hasPrefix("OpenSSL ") { return path } // not "LibreSSL "
        }
        return nil
    }

    // MARK: - DER encoder unit checks (deterministic, no Security calls)

    @Test func derAuthorityKeyIdentifierEncodesKeyIdForm() {
        // 20-byte stand-in key id → exact AKI extension DER:
        //   SEQUENCE { OID 2.5.29.35, OCTET STRING { SEQUENCE { [0] keyID } } }
        // outer content = OID(5) + OCTET STRING(2 + 24) = 31 bytes (0x1F):
        //   30 1F 06 03 55 1D 23 04 18 30 16 80 14 <20 bytes>
        let keyID = Data(repeating: 0xAB, count: 20)
        let enc = [UInt8](DEREncoder.authorityKeyIdentifier(keyID))
        let expected: [UInt8] =
            [0x30, 0x1F, 0x06, 0x03, 0x55, 0x1D, 0x23, 0x04, 0x18, 0x30, 0x16, 0x80, 0x14]
            + [UInt8](repeating: 0xAB, count: 20)
        #expect(enc == expected)
    }

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
