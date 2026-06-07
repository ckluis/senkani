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

        // Load the PKCS#12 → SecIdentity (memory-only on macOS 15+,
        // ephemeral keychain on the macOS-14 floor).
        // NOTE: a stray-`senkani-mitm-*.keychain` no-leak assertion was removed
        // here — it counted files in the SHARED temp dir, which races against
        // concurrent tests minting leaves in parallel (Swift Testing runs tests
        // concurrently). The no-leak guarantee is makeEphemeralKeychain's
        // `defer { unlink }`; a non-racy scoped check is tracked by
        // process-gap-ephemeral-keychain-noleak-test-race-2026-05-31.
        let identity = try MITMCertificateAuthority.loadIdentity(from: leaf.pkcs12)

        // The identity yields both a private key and the leaf certificate.
        var privKey: SecKey?
        #expect(SecIdentityCopyPrivateKey(identity, &privKey) == errSecSuccess)
        let key = try #require(privKey)

        var certOut: SecCertificate?
        #expect(SecIdentityCopyCertificate(identity, &certOut) == errSecSuccess)
        let idCert = try #require(certOut)
        let cn = SecCertificateCopySubjectSummary(idCert) as String?
        #expect(cn == "identity.example.com")

        // Central migration guarantee: the identity's private key must be
        // LIVE after `loadIdentity` returns — i.e. it survives the call with
        // no retaining keychain. Prove it by actually USING the key to sign,
        // not merely by checking it is non-nil.
        let message = Data("senkani-mitm-key-liveness-probe".utf8)
        var signErr: Unmanaged<CFError>?
        let signature = SecKeyCreateSignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            message as CFData,
            &signErr
        ) as Data?
        if signature == nil {
            Issue.record("private key signing failed: \(MITMCertificateAuthority.cfErrorString(signErr))")
        }
        let sig = try #require(signature, "imported identity's private key must sign after loadIdentity returns")
        #expect(!sig.isEmpty)
    }

    // MARK: - 5b. RUNTIME-exercise the macOS-14 floor (ephemeral keychain)

    /// `loadIdentity`'s `#available(macOS 15.0)` dispatcher means the
    /// macOS-14 `else` branch can NEVER run on this 15+ build host through
    /// the public entry point. This test calls the extracted floor helper
    /// `loadIdentityViaEphemeralKeychain` DIRECTLY (it is NOT
    /// `@available`-gated, since `SecKeychainCreate/Delete` are
    /// deprecated-but-available on macOS 15+), so the exact v14-floor logic
    /// is RUNTIME-exercised here — not merely type-checked. It proves the
    /// floor path yields a usable, signing identity and leaks no keychain.
    @Test func leafPKCS12LoadsViaEphemeralKeychainPathDirectly() async throws {
        let (paths, dir) = tempPaths()
        defer { cleanup(dir) }
        let ca = MITMCertificateAuthority(paths: paths, keyBits: 2048)
        _ = try await ca.generateRoot()

        let host = "floor.example.com"
        let leaf = try await ca.leaf(forHost: host)
        #expect(!leaf.pkcs12.isEmpty)

        // Call the macOS-14-floor helper DIRECTLY (not `loadIdentity`).
        // (A racy stray-keychain-file no-leak assertion was removed here; see
        // the note in leafPKCS12LoadsAsSecIdentity + the filed follow-up.)
        let identity = try MITMCertificateAuthority.loadIdentityViaEphemeralKeychain(from: leaf.pkcs12)

        // The floor path yields a live private key...
        var privKey: SecKey?
        #expect(SecIdentityCopyPrivateKey(identity, &privKey) == errSecSuccess)
        let key = try #require(privKey)

        // ...that actually SIGNS after the helper returns (no retaining
        // keychain) — proving the floor identity is usable, not merely present.
        let message = Data("senkani-mitm-floor-liveness-probe".utf8)
        var signErr: Unmanaged<CFError>?
        let signature = SecKeyCreateSignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            message as CFData,
            &signErr
        ) as Data?
        if signature == nil {
            Issue.record("floor-path private key signing failed: \(MITMCertificateAuthority.cfErrorString(signErr))")
        }
        let sig = try #require(signature, "floor-path identity's private key must sign after the helper returns")
        #expect(!sig.isEmpty)

        // The identity carries the leaf certificate (CN == host).
        var certOut: SecCertificate?
        #expect(SecIdentityCopyCertificate(identity, &certOut) == errSecSuccess)
        let idCert = try #require(certOut)
        let cn = SecCertificateCopySubjectSummary(idCert) as String?
        #expect(cn == host)
    }

    // MARK: - 5c. Source guard: no UNGUARDED macOS-15+ Security symbol

    /// Lexically scan the MITMCertificateAuthority source and assert every
    /// occurrence of each macOS-15+-gated Security symbol in the SEED LIST
    /// sits inside an availability-guarded region: either within a function
    /// whose declaration carries `@available(macOS 15.0`, or inside an
    /// `if #available(macOS 15.0` brace scope. This FAILS the build's tests
    /// if someone later adds an unguarded `kSecImportToMemoryOnly` (or any
    /// future seed symbol) at top level / in an ungated function.
    @Test func macOS15SecuritySymbolsAreAvailabilityGuarded() throws {
        // Adding a newly-gated symbol is a one-line array edit.
        let seedSymbols = ["kSecImportToMemoryOnly"]

        let source = try Self.mitmSourceText()
        let lines = source.components(separatedBy: "\n")

        // Track two nested guard contexts as we scan:
        //  1. brace depth of any `if #available(macOS 15.0` block we entered,
        //  2. whether the enclosing func decl was `@available(macOS 15.0`.
        // We approximate brace scope with a running brace-balance stack of
        // markers. A symbol occurrence is "guarded" iff it is inside an
        // available-15 func OR inside an available-15 `if` block.
        var braceDepth = 0
        // brace depth at which the current `if #available(15)` block opened,
        // or nil if not inside one. (Single-level is sufficient for this file;
        // we re-arm on each such `if`.)
        var availableIfDepth: Int? = nil
        // brace depth at which the current @available(15) func body opened.
        var availableFuncDepth: Int? = nil
        // Set when the previous non-blank line carried @available(macOS 15.0
        // (the annotation precedes the func/decl it guards).
        var pendingAvailableAnnotation = false

        func stripComment(_ line: String) -> String {
            // Drop // line comments so a symbol named only in a comment does
            // not count as an unguarded occurrence (and cannot false-positive
            // on doc comments). Good enough for this source (no "//" appears
            // inside string literals on symbol-bearing lines here).
            if let r = line.range(of: "//") { return String(line[line.startIndex..<r.lowerBound]) }
            return line
        }

        for rawLine in lines {
            let code = stripComment(rawLine)
            let trimmed = code.trimmingCharacters(in: .whitespaces)

            let isAvailableAnnotationLine = trimmed.contains("@available(macOS 15.0")
            let hasAvailableIf = code.contains("if #available(macOS 15.0")

            // Count braces on this (comment-stripped) line.
            let opens = code.filter { $0 == "{" }.count
            let closes = code.filter { $0 == "}" }.count

            // A symbol is guarded on this line if we're already inside an
            // available-15 region OR this very line opens one.
            let insideGuardedRegion =
                availableFuncDepth != nil || availableIfDepth != nil || hasAvailableIf

            // Check seed symbols on the comment-stripped code.
            for symbol in seedSymbols where code.contains(symbol) {
                #expect(insideGuardedRegion,
                        "macOS-15+ symbol `\(symbol)` appears OUTSIDE an availability guard: \(trimmed)")
            }

            // --- update scopes for subsequent lines ---

            // If the previous line was an @available(15) annotation and this
            // line opens a brace, that's the guarded func/decl body.
            if pendingAvailableAnnotation && opens > 0 && availableFuncDepth == nil {
                availableFuncDepth = braceDepth // depth BEFORE this line's opens
            }
            // The annotation applies to the next declaration; clear it once a
            // real (non-annotation, non-blank) line is seen.
            if isAvailableAnnotationLine {
                pendingAvailableAnnotation = true
            } else if !trimmed.isEmpty {
                pendingAvailableAnnotation = false
            }

            // Entering an `if #available(15)` block: arm at the depth its body
            // opens (depth BEFORE this line's opens).
            if hasAvailableIf && availableIfDepth == nil {
                availableIfDepth = braceDepth
            }

            // Apply brace deltas.
            braceDepth += opens
            braceDepth -= closes
            if braceDepth < 0 { braceDepth = 0 }

            // Closing back out of an armed region disarms it.
            if let d = availableIfDepth, braceDepth <= d { availableIfDepth = nil }
            if let d = availableFuncDepth, braceDepth <= d { availableFuncDepth = nil }
        }
    }

    /// Robustly resolve + read the MITMCertificateAuthority source. Walks up
    /// from this test file's `#filePath` to the repo root (the dir holding
    /// `Package.swift`), then reads `Sources/Core/EgressProxy/...`. No
    /// hardcoded absolute machine path.
    private static func mitmSourceText(file: StaticString = #filePath) throws -> String {
        let rel = "Sources/Core/EgressProxy/MITMCertificateAuthority.swift"
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        // Walk upward looking for Package.swift (repo root marker).
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            let pkg = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: pkg.path) {
                let atRoot = dir.appendingPathComponent(rel)
                return try String(contentsOf: atRoot, encoding: .utf8)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw NSError(domain: "MITMSourceGuard", code: 1,
                      userInfo: [NSLocalizedDescriptionKey:
                        "could not locate \(rel) walking up from \(file)"])
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

    // MARK: - 6b. Persist failure must NOT cache an in-memory root (regression)

    /// Regression lock for the stale-cache bug fixed in phase-t1d-6: the
    /// instance `generateRoot()` assigns `self.root` ONLY AFTER
    /// `Self.generateRootCore(...)` (which mints + persists) returns. The OLD
    /// code assigned `self.root` BEFORE `persist(...)`, so a persist failure
    /// left the actor caching an in-memory `Root` whose disk files were never
    /// written — and a later `ensureRoot()` would hand back that cached,
    /// disk-less root WITHOUT throwing.
    ///
    /// We can't read the private `self.root` directly, so we observe it
    /// INDIRECTLY through `ensureRoot()`'s `if let root { return root }`
    /// short-circuit:
    ///   1. `generateRoot()` must THROW (persist fails before any cache write).
    ///   2. `ensureRoot()` must THROW AGAIN — with the fix, `self.root` is nil,
    ///      so ensureRoot re-runs generate (persist fails again → throws). With
    ///      the OLD bug, `self.root` would be the cached disk-less root and
    ///      ensureRoot would return it with NO throw. So "throws the SECOND
    ///      time too" is the discriminating assertion.
    ///
    /// Persist-failure mechanism: we point the public-cert path at a child of
    /// an existing REGULAR FILE (`<tempfile>/egress-ca.pem`). `write(...)`'s
    /// first step is `FileManager.createDirectory(atPath: dir,
    /// withIntermediateDirectories: true)`, which fails when `dir`'s own parent
    /// is a non-directory (the OS returns ENOTDIR for a path component that is a
    /// regular file). That makes `persist` — and therefore `generateRootCore`
    /// — throw deterministically, with no filesystem race and without touching
    /// `~/.senkani` or any real path.
    @Test func persistFailureDoesNotCacheInMemoryRoot() async throws {
        // A real temp directory we own + clean up; inside it, a REGULAR FILE
        // that we then (illegally) treat as a directory parent.
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("senkani-mitm-persistfail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let regularFile = baseDir.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: regularFile)

        // `write`'s createDirectory(atPath: <regularFile>/sub) fails ENOTDIR
        // because `regularFile` is a file, not a directory → persist throws.
        let badParent = regularFile.appendingPathComponent("sub")
        let paths = MITMCertificateAuthority.Paths(
            publicCertPEM: badParent.appendingPathComponent("egress-ca.pem").path,
            privateKeyPEM: badParent.appendingPathComponent("egress-ca.key").path
        )
        let ca = MITMCertificateAuthority(paths: paths, keyBits: 2048)

        // 1. generateRoot() throws (persist fails inside generateRootCore,
        //    BEFORE any `self.root = root` cache write).
        await #expect(throws: (any Error).self) {
            try await ca.generateRoot()
        }

        // 2. ensureRoot() throws AGAIN — proving NO disk-less root was cached.
        //    With the OLD pre-persist cache write this would return the stale
        //    cached root and NOT throw, failing this assertion.
        await #expect(throws: (any Error).self) {
            try await ca.ensureRoot()
        }

        // And nothing was written to disk (persist failed before any file).
        #expect(!FileManager.default.fileExists(atPath: paths.publicCertPEM))
        #expect(!FileManager.default.fileExists(atPath: paths.privateKeyPEM))

        // Positive control: with GOOD writable temp paths, generateRoot()
        // succeeds and both files land on disk — confirms the throw above is
        // the persist failure, not some unrelated breakage of the happy path.
        let (goodPaths, goodDir) = tempPaths()
        defer { cleanup(goodDir) }
        let goodCA = MITMCertificateAuthority(paths: goodPaths, keyBits: 2048)
        _ = try await goodCA.generateRoot()
        #expect(FileManager.default.fileExists(atPath: goodPaths.publicCertPEM))
        #expect(FileManager.default.fileExists(atPath: goodPaths.privateKeyPEM))
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
