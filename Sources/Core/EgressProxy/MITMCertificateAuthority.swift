import Foundation
import CryptoKit

#if canImport(Darwin)
import Darwin
#endif
#if canImport(Security)
import Security
#endif

/// T.1d-1 — workstation-local MITM root CA + on-demand per-host leaf-cert
/// minting. This is the crypto foundation the TLS-termination spike
/// (t1d-2a) consumes: when the EgressProxy terminates an outbound TLS
/// connection it must present a leaf certificate for the requested host
/// that chains to a CA the client trusts.
///
/// We hand-roll the X.509 DER/ASN.1 against `Security.framework`
/// (`SecKeyCreateRandomKey`, `SecKeyCreateSignature`,
/// `SecCertificateCreateWithData`) rather than pulling in
/// swift-crypto/swift-certificates/swift-asn1. Adding a SwiftPM
/// dependency mutates `Package.resolved` — a categorically-blocked
/// operator supply-chain decision — so the certificate machinery here is
/// built from `DEREncoder` (below) plus RSA keys + PKCS#1 v1.5 SHA-256
/// signatures.
///
/// Trust model. NOTHING here ever touches the System/login Keychain:
///   • the CA public cert persists to a configurable PEM path (real
///     default `~/.senkani/egress-ca.pem`),
///   • the CA private key persists to a SEPARATE `0600` owner-only file,
///   • leaf SecIdentity artifacts are emitted as in-memory PKCS#12 blobs
///     that the consumer loads with `SecPKCS12Import` — memory-only on
///     macOS 15+, or into an EPHEMERAL keychain it creates and deletes on
///     the macOS-14 floor (see `loadIdentity`).
/// The real trust install (adding the CA to the System trust store) is a
/// separate gui-human item (t1d-7); doing it here would be the wrong
/// blast radius for an autonomous round.
///
/// Concurrency: the proxy is concurrent, so the authority is an actor.
/// The per-host leaf cache lives inside the actor's isolation domain.
public actor MITMCertificateAuthority {

    public enum CAError: Error, Equatable, CustomStringConvertible {
        case keyGeneration(String)
        case publicKeyExport(String)
        case signing(String)
        case certificateDecode
        case pkcs12Export(OSStatus)
        case pkcs12Import(OSStatus)
        case identityMissing
        case persistFailed(String)
        case loadFailed(String)

        public var description: String {
            switch self {
            case .keyGeneration(let m):  return "RSA key generation failed: \(m)"
            case .publicKeyExport(let m): return "public-key export failed: \(m)"
            case .signing(let m):        return "TBS signing failed: \(m)"
            case .certificateDecode:     return "SecCertificateCreateWithData rejected the hand-rolled DER"
            case .pkcs12Export(let s):   return "SecPKCS12... export failed (OSStatus \(s))"
            case .pkcs12Import(let s):   return "SecPKCS12Import failed (OSStatus \(s))"
            case .identityMissing:       return "PKCS#12 import returned no SecIdentity"
            case .persistFailed(let m):  return "persist failed: \(m)"
            case .loadFailed(let m):     return "load failed: \(m)"
            }
        }
    }

    /// Where the CA materials live. The public cert is a PEM the operator
    /// can inspect / hand to t1d-7; the private key is a SEPARATE 0600
    /// file (never co-located with the public cert).
    public struct Paths: Sendable, Equatable {
        public let publicCertPEM: String
        public let privateKeyPEM: String

        public init(publicCertPEM: String, privateKeyPEM: String) {
            self.publicCertPEM = publicCertPEM
            self.privateKeyPEM = privateKeyPEM
        }

        /// Real default: `~/.senkani/egress-ca.pem` for the public cert and
        /// `~/.senkani/egress-ca.key` (0600) for the private key.
        public static func defaultPaths() -> Paths {
            let home = NSHomeDirectory()
            let dir = (home as NSString).appendingPathComponent(".senkani")
            return Paths(
                publicCertPEM: (dir as NSString).appendingPathComponent("egress-ca.pem"),
                privateKeyPEM: (dir as NSString).appendingPathComponent("egress-ca.key")
            )
        }
    }

    /// The minted CA root, kept in-process for signing leaves.
    public struct Root: @unchecked Sendable {
        public let certificateDER: Data
        public let privateKey: SecKey
        public let subject: String
    }

    private let paths: Paths
    private let keyBits: Int
    private var root: Root?
    /// Per-host leaf cache. Key = lowercased host. Mints once, reuses.
    private var leafCache: [String: LeafBundle] = [:]

    /// A minted leaf: the DER, its private key, and the PKCS#12 export that
    /// `SecPKCS12Import` loads as a `SecIdentity`.
    public struct LeafBundle: @unchecked Sendable {
        public let host: String
        public let certificateDER: Data
        public let privateKey: SecKey
        public let pkcs12: Data
    }

    public init(paths: Paths = .defaultPaths(), keyBits: Int = 2048) {
        self.paths = paths
        self.keyBits = keyBits
    }

    // MARK: - CA lifecycle

    /// Generate the root CA in-process (SecKey + hand-rolled DER) and
    /// persist: public cert to `paths.publicCertPEM`, private key to the
    /// SEPARATE `paths.privateKeyPEM` at mode 0600. Returns the in-process
    /// `Root` for immediate leaf minting.
    @discardableResult
    public func generateRoot(
        commonName: String = "senkani Egress MITM Root CA",
        validityDays: Int = 3650
    ) throws -> Root {
        let key = try Self.makeRSAKey(bits: keyBits)
        guard let pub = SecKeyCopyPublicKey(key) else {
            throw CAError.publicKeyExport("SecKeyCopyPublicKey returned nil")
        }
        let spki = try Self.subjectPublicKeyInfo(from: pub)

        let issuerName = DEREncoder.distinguishedName(commonName: commonName, organization: "senkani")
        let now = Date()
        let notBefore = now.addingTimeInterval(-300) // small backdate for clock skew
        let notAfter = now.addingTimeInterval(TimeInterval(validityDays) * 86_400)
        let serial = Self.randomSerial()

        // Subject Key Identifier = SHA-1 of the BIT STRING contents
        // (RFC 5280 §4.2.1.2 method (1)), over the raw public-key bytes
        // (the PKCS#1 RSAPublicKey DER). Same helper the leaf's AKI uses.
        let ski = try Self.keyIdentifier(forPublicKey: pub)

        let extensions = DEREncoder.extensions([
            DEREncoder.basicConstraintsCA(critical: true, isCA: true),
            DEREncoder.keyUsage(bits: [.keyCertSign, .cRLSign, .digitalSignature], critical: true),
            DEREncoder.subjectKeyIdentifier(ski),
        ])

        let tbs = DEREncoder.tbsCertificate(
            serial: serial,
            issuer: issuerName,
            subject: issuerName, // self-signed: subject == issuer
            notBefore: notBefore,
            notAfter: notAfter,
            spki: spki,
            extensions: extensions
        )
        let certDER = try Self.signCertificate(tbs: tbs, with: key)

        // Smoke-test: the hand-rolled DER must round-trip through
        // SecCertificateCreateWithData or it is not a valid X.509 cert.
        guard SecCertificateCreateWithData(nil, certDER as CFData) != nil else {
            throw CAError.certificateDecode
        }

        let root = Root(certificateDER: certDER, privateKey: key, subject: commonName)
        self.root = root
        try persist(root: root)
        return root
    }

    /// Load a previously-generated root from disk (public PEM + 0600 key
    /// PEM). Returns the `Root` and caches it for minting.
    @discardableResult
    public func loadRoot() throws -> Root {
        guard let certData = FileManager.default.contents(atPath: paths.publicCertPEM) else {
            throw CAError.loadFailed("no CA cert at \(paths.publicCertPEM)")
        }
        guard let keyData = FileManager.default.contents(atPath: paths.privateKeyPEM) else {
            throw CAError.loadFailed("no CA key at \(paths.privateKeyPEM)")
        }
        guard let certDER = Self.pemDecode(String(decoding: certData, as: UTF8.self), label: "CERTIFICATE") else {
            throw CAError.loadFailed("malformed CA cert PEM")
        }
        guard let keyDER = Self.pemDecode(String(decoding: keyData, as: UTF8.self), label: "RSA PRIVATE KEY") else {
            throw CAError.loadFailed("malformed CA key PEM")
        }
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: keyBits,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(keyDER as CFData, attrs as CFDictionary, &error) else {
            throw CAError.loadFailed("SecKeyCreateWithData: \(Self.cfErrorString(error))")
        }
        let root = Root(certificateDER: certDER, privateKey: key, subject: "loaded")
        self.root = root
        return root
    }

    /// Ensure a root exists: generate if missing on disk, otherwise load.
    @discardableResult
    public func ensureRoot() throws -> Root {
        if let root { return root }
        if FileManager.default.fileExists(atPath: paths.publicCertPEM),
           FileManager.default.fileExists(atPath: paths.privateKeyPEM) {
            return try loadRoot()
        }
        return try generateRoot()
    }

    // MARK: - Leaf minting

    /// Mint (or return a cached) per-host leaf certificate signed by the
    /// local CA. CN and a dNSName SAN both equal `host`. The result
    /// carries the PKCS#12 export the TLS-termination layer loads as a
    /// `SecIdentity`.
    public func leaf(forHost host: String, validityDays: Int = 825) throws -> LeafBundle {
        let key = host.lowercased()
        if let cached = leafCache[key] { return cached }

        let root = try ensureRoot()

        let leafKey = try Self.makeRSAKey(bits: keyBits)
        guard let leafPub = SecKeyCopyPublicKey(leafKey) else {
            throw CAError.publicKeyExport("leaf SecKeyCopyPublicKey returned nil")
        }
        let spki = try Self.subjectPublicKeyInfo(from: leafPub)

        // Issuer DN must byte-match the CA's subject DN. We reconstruct it
        // from the CA cert so a loaded-from-disk root chains correctly.
        let issuerName = try Self.subjectName(ofCertificateDER: root.certificateDER)
        let subjectName = DEREncoder.distinguishedName(commonName: host, organization: "senkani")

        let now = Date()
        let notBefore = now.addingTimeInterval(-300)
        let notAfter = now.addingTimeInterval(TimeInterval(validityDays) * 86_400)
        let serial = Self.randomSerial()

        // RFC 5280 §4.2.1.1/§4.2.1.2 completeness (t1d-1 follow-up): the leaf
        // carries its own Subject Key Identifier AND an Authority Key
        // Identifier equal to the CA's SKI. Without the AKI, strict verifiers
        // (`openssl verify -x509_strict`, BoringSSL) reject the chain
        // (OpenSSL error 85). The CA's SKI is recomputed from the CA public
        // key via the same helper that minted it, so the two match byte-for-
        // byte even when the root was loaded from disk.
        let leafSKI = try Self.keyIdentifier(forPublicKey: leafPub)
        guard let caPub = SecKeyCopyPublicKey(root.privateKey) else {
            throw CAError.publicKeyExport("CA SecKeyCopyPublicKey returned nil")
        }
        let caSKI = try Self.keyIdentifier(forPublicKey: caPub)

        let extensions = DEREncoder.extensions([
            DEREncoder.basicConstraintsCA(critical: false, isCA: false),
            DEREncoder.keyUsage(bits: [.digitalSignature, .keyEncipherment], critical: true),
            DEREncoder.extendedKeyUsageServerAuth(),
            DEREncoder.subjectAltNameDNS(host),
            DEREncoder.subjectKeyIdentifier(leafSKI),
            DEREncoder.authorityKeyIdentifier(caSKI),
        ])

        let tbs = DEREncoder.tbsCertificate(
            serial: serial,
            issuer: issuerName,
            subject: subjectName,
            notBefore: notBefore,
            notAfter: notAfter,
            spki: spki,
            extensions: extensions
        )
        // Signed by the CA key (NOT the leaf key) — that is what chains.
        let leafDER = try Self.signCertificate(tbs: tbs, with: root.privateKey)

        guard SecCertificateCreateWithData(nil, leafDER as CFData) != nil else {
            throw CAError.certificateDecode
        }

        let p12 = try Self.exportPKCS12(certDER: leafDER, privateKey: leafKey, passphrase: Self.p12Passphrase)
        let bundle = LeafBundle(host: host, certificateDER: leafDER, privateKey: leafKey, pkcs12: p12)
        leafCache[key] = bundle
        return bundle
    }

    /// Number of cached leaves (test introspection).
    public var cachedLeafCount: Int { leafCache.count }

    /// The CA certificate as a `SecCertificate` (anchor for a custom
    /// `SecTrust` evaluator — see tests). Never installed to any keychain.
    public func caCertificate() throws -> SecCertificate {
        let root = try ensureRoot()
        guard let cert = SecCertificateCreateWithData(nil, root.certificateDER as CFData) else {
            throw CAError.certificateDecode
        }
        return cert
    }

    // MARK: - SecIdentity load (ephemeral, never the System Keychain)

    /// Load a minted leaf's PKCS#12 and return the resulting `SecIdentity`.
    /// The System/login Keychain is NEVER touched on any macOS version. The
    /// consumer (TLS-termination) calls this to obtain the identity it hands
    /// to `sec_protocol_options_set_local_identity`.
    ///
    /// macOS 15+ (`if #available`): a MEMORY-ONLY import
    /// (`kSecImportToMemoryOnly: true`, NO `kSecImportExportKeychain`). No
    /// keychain is created or deleted — there is nothing to clean up, and
    /// `SecPKCS12Import` cannot fall back to the default login keychain
    /// because the memory-only flag is set. The returned `SecIdentity`'s key
    /// is held in memory and survives the call return. On the local build
    /// machine (macOS ≥ 15) THIS branch is the one exercised at runtime.
    ///
    /// macOS 14 floor (`else`): the pre-migration behavior, verbatim — an
    /// explicit throwaway file-backed `SecKeychain` is passed via
    /// `kSecImportExportKeychain` so `SecPKCS12Import` cannot fall back to
    /// the user's default keychain, and it is deleted before returning. The
    /// `SecIdentity` stays valid because it retains its key reference
    /// independently.
    public static func loadIdentity(from p12: Data) throws -> SecIdentity {
        // Thin dispatcher: `#available` selects the branch by OS version, so
        // on a macOS-15+ host the floor (`loadIdentityViaEphemeralKeychain`)
        // can NEVER run through here. The two branches are extracted into
        // directly-callable named helpers so the floor path can be
        // runtime-exercised by tests on a 15+ host (it calls the helper
        // directly). Behavior here is unchanged — purely dispatch.
        if #available(macOS 15.0, *) {
            return try loadIdentityMemoryOnly(from: p12)
        } else {
            return try loadIdentityViaEphemeralKeychain(from: p12)
        }
    }

    /// macOS 15+ memory-only PKCS#12 import path (the `loadIdentity`
    /// `if #available(macOS 15.0)` branch, verbatim). Annotated
    /// `@available(macOS 15.0, *)` because `kSecImportToMemoryOnly` is a
    /// macOS-15+ symbol; the macOS-14 floor cannot see it.
    ///
    /// Memory-only: no keychain is created, so nothing is created in,
    /// written to, or deleted from any keychain. `kSecImportToMemoryOnly`
    /// is referenced ONLY inside this availability-guarded function. With
    /// this flag set and NO `kSecImportExportKeychain`, the import stays
    /// entirely in process memory and CANNOT fall back to the login keychain.
    @available(macOS 15.0, *)
    static func loadIdentityMemoryOnly(from p12: Data) throws -> SecIdentity {
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: p12Passphrase,
            kSecImportToMemoryOnly as String: true,
        ]
        var items: CFArray?
        let status = SecPKCS12Import(p12 as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else { throw CAError.pkcs12Import(status) }
        return try identity(fromImportedItems: items)
    }

    /// macOS-14 floor PKCS#12 import path (the `loadIdentity` `else` branch,
    /// verbatim). NOT annotated `@available` — `SecKeychainCreate`/`Delete`
    /// are deprecated-but-still-available on all supported macOS versions, so
    /// this is callable directly on a macOS-15+ host. That makes the floor
    /// logic runtime-exercisable by tests on the local build machine rather
    /// than only type-checked.
    ///
    /// The deprecated `SecKeychainCreate`/`SecKeychainDelete` pair is retained
    /// here (item phase-t1d-1-seckeychain-deprecation-migration-2026-05-31)
    /// because `kSecImportToMemoryOnly` is macOS 15+ and there is NO
    /// non-deprecated, no-keychain `SecPKCS12Import` path on the macOS-14
    /// floor. The keychain is a throwaway: UUID-unique per call, defer-cleaned
    /// on BOTH success and error, and never the login/System keychain.
    static func loadIdentityViaEphemeralKeychain(from p12: Data) throws -> SecIdentity {
        let (keychain, path) = try makeEphemeralKeychain()
        defer {
            SecKeychainDelete(keychain) // deprecated since 10.10; see makeEphemeralKeychain
            unlink(path)
        }
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: p12Passphrase,
            kSecImportExportKeychain as String: keychain,
        ]
        var items: CFArray?
        let status = SecPKCS12Import(p12 as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else { throw CAError.pkcs12Import(status) }
        return try identity(fromImportedItems: items)
    }

    /// Extract the first `SecIdentity` from a `SecPKCS12Import` result array.
    /// Shared by both the memory-only (macOS 15+) and ephemeral-keychain
    /// (macOS 14 floor) branches of `loadIdentity`.
    private static func identity(fromImportedItems items: CFArray?) throws -> SecIdentity {
        guard let array = items as? [[String: Any]],
              let first = array.first,
              let identityAny = first[kSecImportItemIdentity as String]
        else { throw CAError.identityMissing }
        // The value is a SecIdentity (CFTypeRef bridged through Any).
        let identity = identityAny as! SecIdentity
        return identity
    }

    // MARK: - Persistence

    private func persist(root: Root) throws {
        let certPEM = Self.pemEncode(root.certificateDER, label: "CERTIFICATE")
        try Self.write(string: certPEM, to: paths.publicCertPEM, mode: 0o644)

        // Private key: SEPARATE file, mode 0600.
        let keyDER = try Self.exportPrivateKeyDER(root.privateKey)
        let keyPEM = Self.pemEncode(keyDER, label: "RSA PRIVATE KEY")
        try Self.write(string: keyPEM, to: paths.privateKeyPEM, mode: 0o600)
    }

    // MARK: - Key helpers

    static func makeRSAKey(bits: Int) throws -> SecKey {
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: bits,
            // NO kSecAttrIsPermanent / kSecUseKeychain — the key lives only
            // in process memory + the PEM file we write ourselves.
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
            throw CAError.keyGeneration(cfErrorString(error))
        }
        return key
    }

    /// Raw public-key bytes: for RSA this is the PKCS#1 `RSAPublicKey` DER
    /// (`SEQUENCE { modulus, publicExponent }`).
    static func exportPublicKeyBits(_ pub: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(pub, &error) as Data? else {
            throw CAError.publicKeyExport(cfErrorString(error))
        }
        return data
    }

    /// RFC 5280 §4.2.1.2 method (1): key identifier = SHA-1 of the
    /// subjectPublicKey BIT STRING contents. For RSA that is the PKCS#1
    /// `RSAPublicKey` DER from `SecKeyCopyExternalRepresentation`. This one
    /// helper backs BOTH the CA Subject Key Identifier and the leaf's
    /// Authority Key Identifier (= the CA's SKI, per §4.2.1.1), so the two
    /// are byte-identical by construction and cannot drift.
    static func keyIdentifier(forPublicKey pub: SecKey) throws -> Data {
        let rawPub = try exportPublicKeyBits(pub)
        return Data(Insecure.SHA1.hash(data: rawPub))
    }

    /// Private-key DER. For RSA this is the PKCS#1 `RSAPrivateKey` DER,
    /// which round-trips back through `SecKeyCreateWithData`.
    static func exportPrivateKeyDER(_ key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw CAError.publicKeyExport(cfErrorString(error))
        }
        return data
    }

    /// Build the X.509 SubjectPublicKeyInfo for an RSA public key:
    ///   SEQUENCE { AlgorithmIdentifier { rsaEncryption, NULL }, BIT STRING { RSAPublicKey } }
    static func subjectPublicKeyInfo(from pub: SecKey) throws -> Data {
        let rawPub = try exportPublicKeyBits(pub)
        return DEREncoder.rsaSubjectPublicKeyInfo(pkcs1PublicKey: rawPub)
    }

    /// Sign a TBSCertificate DER with PKCS#1 v1.5 SHA-256 and assemble the
    /// outer Certificate: SEQUENCE { tbs, AlgorithmIdentifier, BIT STRING(sig) }.
    static func signCertificate(tbs: Data, with key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            tbs as CFData,
            &error
        ) as Data? else {
            throw CAError.signing(cfErrorString(error))
        }
        return DEREncoder.certificate(
            tbs: tbs,
            signatureAlgorithm: DEREncoder.sha256WithRSAEncryption(),
            signature: sig
        )
    }

    /// Extract the subject DN (the raw `Name` DER) from a certificate DER.
    /// Used so a leaf's issuer field byte-matches the CA subject even when
    /// the CA was loaded from disk.
    static func subjectName(ofCertificateDER der: Data) throws -> Data {
        // Certificate ::= SEQUENCE { tbsCertificate, sigAlg, sig }
        var p = DERParser(der)
        let cert = try p.expectSequence()
        var tp = DERParser(cert)
        let tbs = try tp.expectSequence()
        var fields = DERParser(tbs)
        // Optional [0] version
        try fields.skipIfContextTag(0)
        try fields.skipOne() // serialNumber INTEGER
        try fields.skipOne() // signature AlgorithmIdentifier
        try fields.skipOne() // issuer Name
        try fields.skipOne() // validity
        let subject = try fields.readRawElement() // subject Name (full TLV)
        return subject
    }

    // MARK: - PKCS#12 export

    static let p12Passphrase = "senkani-mitm-leaf"

    /// Export a (leaf cert, private key) pair as a PKCS#12 blob that
    /// `SecPKCS12Import` loads as a `SecIdentity`. We assemble a transient
    /// `SecIdentity` via an EPHEMERAL keychain, then export it, then
    /// delete the keychain — the System/login Keychain is never touched.
    static func exportPKCS12(certDER: Data, privateKey: SecKey, passphrase: String) throws -> Data {
        guard let cert = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw CAError.certificateDecode
        }
        let (keychain, path) = try makeEphemeralKeychain()
        defer {
            SecKeychainDelete(keychain) // deprecated since 10.10; see makeEphemeralKeychain
            unlink(path)
        }
        // Import the private key into the ephemeral keychain so we can
        // assemble a SecIdentity, then export it.
        var importedKey: CFArray?
        let keyDER = try exportPrivateKeyDER(privateKey)
        var inputFormat: SecExternalFormat = .formatOpenSSL
        var itemType: SecExternalItemType = .itemTypePrivateKey
        let keyImportStatus = SecItemImport(
            keyDER as CFData, nil, &inputFormat, &itemType, [], nil, keychain, &importedKey
        )
        guard keyImportStatus == errSecSuccess else { throw CAError.pkcs12Export(keyImportStatus) }

        // Add the cert to the same keychain.
        let addCert: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecValueRef: cert,
            kSecUseKeychain: keychain,
        ]
        let certAddStatus = SecItemAdd(addCert as CFDictionary, nil)
        guard certAddStatus == errSecSuccess || certAddStatus == errSecDuplicateItem else {
            throw CAError.pkcs12Export(certAddStatus)
        }

        // Pull the assembled identity back out of the ephemeral keychain.
        var copied: CFTypeRef?
        let idQuery: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnRef: true,
            kSecMatchSearchList: [keychain] as CFArray,
        ]
        let idStatus = SecItemCopyMatching(idQuery as CFDictionary, &copied)
        guard idStatus == errSecSuccess, let identityRef = copied else {
            throw CAError.pkcs12Export(idStatus)
        }
        let identity = identityRef as! SecIdentity

        // Export the identity as PKCS#12.
        var exported: CFData?
        var expParams = SecItemImportExportKeyParameters()
        let cfPass = passphrase as CFString
        expParams.passphrase = Unmanaged.passUnretained(cfPass as CFTypeRef)
        let expStatus = SecItemExport(
            identity, .formatPKCS12, [], &expParams, &exported
        )
        guard expStatus == errSecSuccess, let blob = exported as Data? else {
            throw CAError.pkcs12Export(expStatus)
        }
        return blob
    }

    /// Create a throwaway file-backed keychain with a random path + unique
    /// password. Caller deletes it (see `defer` in `exportPKCS12`).
    private static func makeEphemeralKeychain() throws -> (SecKeychain, String) {
        let dir = NSTemporaryDirectory()
        let name = "senkani-mitm-\(UUID().uuidString).keychain"
        let path = (dir as NSString).appendingPathComponent(name)
        let password = UUID().uuidString
        var keychain: SecKeychain?
        let status = password.withCString { pw -> OSStatus in
            // `SecKeychainCreate` is deprecated since macOS 10.10, but the
            // file-backed `SecKeychain` API is still the only floor-safe way
            // to ASSEMBLE a `SecIdentity` from a separate cert + key for
            // PKCS#12 export (`exportPKCS12`): there is no public no-keychain
            // SecIdentity assembly/export path — the data-protection keychain
            // has no SecIdentity assembly or export route on any macOS
            // version. (Item phase-t1d-1-seckeychain-deprecation-migration-2026-05-31:
            // the LOAD path migrated to a macOS-15 memory-only import, but
            // this EXPORT helper deliberately retains the throwaway keychain.)
            // This keychain is contained, UUID-unique per call, and
            // defer-cleaned on both success and error by every caller — it
            // never touches the System/login keychain. The deprecation is a
            // deliberate, contained choice retained until a no-keychain
            // SecIdentity-assembly API exists.
            SecKeychainCreate(path, UInt32(strlen(pw)), pw, false, nil, &keychain)
        }
        guard status == errSecSuccess, let kc = keychain else {
            throw CAError.pkcs12Export(status)
        }
        return (kc, path)
    }

    // MARK: - PEM + file helpers

    static func pemEncode(_ der: Data, label: String) -> String {
        let b64 = der.base64EncodedString()
        var lines: [String] = []
        var idx = b64.startIndex
        while idx < b64.endIndex {
            let end = b64.index(idx, offsetBy: 64, limitedBy: b64.endIndex) ?? b64.endIndex
            lines.append(String(b64[idx..<end]))
            idx = end
        }
        return "-----BEGIN \(label)-----\n" + lines.joined(separator: "\n") + "\n-----END \(label)-----\n"
    }

    static func pemDecode(_ pem: String, label: String) -> Data? {
        let begin = "-----BEGIN \(label)-----"
        let end = "-----END \(label)-----"
        guard let bRange = pem.range(of: begin), let eRange = pem.range(of: end) else { return nil }
        let body = pem[bRange.upperBound..<eRange.lowerBound]
        let b64 = body.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).joined()
        return Data(base64Encoded: b64)
    }

    /// 0600/0644 atomic write: temp file with explicit mode + fchmod
    /// (bypass umask) + rename. Mirrors `JSONFileKeychainStore`'s F6
    /// discipline so the file never exists with wider-than-intended perms.
    static func write(string: String, to path: String, mode: mode_t) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let out = Data(string.utf8)
        #if canImport(Darwin)
        let temp = path + ".tmp.\(ProcessInfo.processInfo.processIdentifier)"
        let fd = Darwin.open(temp, O_CREAT | O_WRONLY | O_TRUNC, mode)
        guard fd >= 0 else {
            throw CAError.persistFailed("open(\(temp)) failed: \(String(cString: strerror(errno)))")
        }
        _ = Darwin.fchmod(fd, mode)
        let written = out.withUnsafeBytes { buf -> Int in
            Darwin.write(fd, buf.baseAddress!, out.count)
        }
        Darwin.close(fd)
        guard written == out.count else {
            Darwin.unlink(temp)
            throw CAError.persistFailed("write truncated: \(written) of \(out.count) bytes")
        }
        guard Darwin.rename(temp, path) == 0 else {
            Darwin.unlink(temp)
            throw CAError.persistFailed("rename(\(temp) → \(path)) failed: \(String(cString: strerror(errno)))")
        }
        #else
        try out.write(to: URL(fileURLWithPath: path), options: [.atomic])
        #endif
    }

    // MARK: - misc

    static func randomSerial() -> Data {
        // 16-byte positive serial. High bit cleared so the INTEGER stays
        // positive without a leading 0x00 pad (DEREncoder also guards).
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
        bytes[0] &= 0x7F
        if bytes[0] == 0 { bytes[0] = 0x01 }
        return Data(bytes)
    }

    static func cfErrorString(_ error: Unmanaged<CFError>?) -> String {
        guard let error else { return "unknown" }
        let e = error.takeRetainedValue()
        return CFErrorCopyDescription(e) as String? ?? "unknown CFError"
    }
}
