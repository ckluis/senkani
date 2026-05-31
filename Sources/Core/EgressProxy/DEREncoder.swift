import Foundation

/// T.1d-1 — minimal DER (Distinguished Encoding Rules) encoder for the
/// X.509 subset the MITM CA needs: SEQUENCE / SET / INTEGER / OID /
/// UTCTime / GeneralizedTime / BIT STRING / OCTET STRING / BOOLEAN /
/// PrintableString / UTF8String / context tags, plus the assembled
/// TBSCertificate + Certificate + the BasicConstraints / KeyUsage /
/// ExtKeyUsage / SubjectAltName / SubjectKeyIdentifier extensions.
///
/// We hand-roll this (rather than pull in swift-asn1) because adding a
/// SwiftPM dependency mutates `Package.resolved`. DER is canonical (one
/// encoding per value) so the output is deterministic, which is exactly
/// what a signer needs.
///
/// Scope: this encoder only emits the structures the CA uses; it is NOT a
/// general ASN.1 library. RSA keys + PKCS#1 v1.5 SHA-256 signatures only.
enum DEREncoder {

    // MARK: - Primitive length / TLV

    /// DER definite-length encoding of `length`.
    static func encodeLength(_ length: Int) -> [UInt8] {
        if length < 0x80 {
            return [UInt8(length)]
        }
        var bytes: [UInt8] = []
        var value = length
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [UInt8(0x80 | bytes.count)] + bytes
    }

    /// Wrap a tag byte + content into a full TLV.
    static func tlv(tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        out.append(contentsOf: encodeLength(content.count))
        out.append(content)
        return out
    }

    static func tlv(tag: UInt8, _ content: [UInt8]) -> Data {
        tlv(tag: tag, Data(content))
    }

    // MARK: - Constructed types

    static func sequence(_ elements: [Data]) -> Data {
        var body = Data()
        for e in elements { body.append(e) }
        return tlv(tag: 0x30, body)
    }

    static func set(_ elements: [Data]) -> Data {
        var body = Data()
        for e in elements { body.append(e) }
        return tlv(tag: 0x31, body)
    }

    /// Context-specific constructed tag [n] (0xA0 | n).
    static func contextConstructed(_ n: UInt8, _ content: Data) -> Data {
        tlv(tag: 0xA0 | n, content)
    }

    /// Context-specific primitive tag [n] (0x80 | n).
    static func contextPrimitive(_ n: UInt8, _ content: Data) -> Data {
        tlv(tag: 0x80 | n, content)
    }

    // MARK: - Primitives

    /// INTEGER from big-endian magnitude bytes. Adds a leading 0x00 if the
    /// high bit is set (so the value stays positive) and strips redundant
    /// leading zeroes (DER minimal encoding).
    static func integer(_ magnitude: Data) -> Data {
        var bytes = [UInt8](magnitude)
        // Strip leading zeroes but keep at least one byte.
        while bytes.count > 1 && bytes[0] == 0x00 && (bytes[1] & 0x80) == 0 {
            bytes.removeFirst()
        }
        if bytes.isEmpty { bytes = [0x00] }
        if bytes[0] & 0x80 != 0 {
            bytes.insert(0x00, at: 0)
        }
        return tlv(tag: 0x02, bytes)
    }

    static func integer(_ value: Int) -> Data {
        if value == 0 { return tlv(tag: 0x02, [0x00]) }
        var bytes: [UInt8] = []
        var v = value
        while v > 0 {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        }
        if bytes[0] & 0x80 != 0 { bytes.insert(0x00, at: 0) }
        return tlv(tag: 0x02, bytes)
    }

    static func boolean(_ value: Bool) -> Data {
        tlv(tag: 0x01, [value ? 0xFF : 0x00])
    }

    static func null() -> Data {
        Data([0x05, 0x00])
    }

    /// OID from its dotted arc components.
    static func oid(_ arcs: [UInt]) -> Data {
        precondition(arcs.count >= 2)
        var bytes: [UInt8] = []
        bytes.append(UInt8(arcs[0] * 40 + arcs[1]))
        for arc in arcs[2...] {
            bytes.append(contentsOf: base128(arc))
        }
        return tlv(tag: 0x06, bytes)
    }

    /// Base-128 (big-endian, high bit = continuation) for OID arcs.
    private static func base128(_ value: UInt) -> [UInt8] {
        if value == 0 { return [0x00] }
        var v = value
        var stack: [UInt8] = []
        while v > 0 {
            stack.insert(UInt8(v & 0x7F), at: 0)
            v >>= 7
        }
        for i in 0..<(stack.count - 1) {
            stack[i] |= 0x80
        }
        return stack
    }

    /// BIT STRING with zero unused bits.
    static func bitString(_ content: Data) -> Data {
        var body = Data([0x00]) // unused-bits count
        body.append(content)
        return tlv(tag: 0x03, body)
    }

    static func octetString(_ content: Data) -> Data {
        tlv(tag: 0x04, content)
    }

    static func printableString(_ s: String) -> Data {
        tlv(tag: 0x13, Data(s.utf8))
    }

    static func utf8String(_ s: String) -> Data {
        tlv(tag: 0x0C, Data(s.utf8))
    }

    /// IA5String (used for dNSName SAN entries — context-tagged below).
    static func ia5String(_ s: String) -> Data {
        tlv(tag: 0x16, Data(s.utf8))
    }

    /// UTCTime (YYMMDDHHMMSSZ) for dates < 2050; GeneralizedTime otherwise
    /// (RFC 5280 §4.1.2.5).
    static func time(_ date: Date) -> Data {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = c.year ?? 1970
        func pad(_ v: Int) -> String { String(format: "%02d", v) }
        let mmddhhmmss = "\(pad(c.month ?? 1))\(pad(c.day ?? 1))\(pad(c.hour ?? 0))\(pad(c.minute ?? 0))\(pad(c.second ?? 0))"
        if year < 2050 {
            let yy = pad(year % 100)
            return tlv(tag: 0x17, Data("\(yy)\(mmddhhmmss)Z".utf8))
        } else {
            return tlv(tag: 0x18, Data("\(year)\(mmddhhmmss)Z".utf8))
        }
    }

    // MARK: - OIDs

    static func sha256WithRSAEncryption() -> Data {
        // 1.2.840.113549.1.1.11, params NULL.
        sequence([oid([1, 2, 840, 113549, 1, 1, 11]), null()])
    }

    static func rsaEncryptionAlgorithm() -> Data {
        // 1.2.840.113549.1.1.1, params NULL.
        sequence([oid([1, 2, 840, 113549, 1, 1, 1]), null()])
    }

    // MARK: - Name (Distinguished Name)

    /// Build a minimal RDNSequence with CN and O attributes.
    ///   Name ::= SEQUENCE OF RelativeDistinguishedName
    ///   RDN  ::= SET OF AttributeTypeAndValue
    static func distinguishedName(commonName: String, organization: String?) -> Data {
        var rdns: [Data] = []
        if let organization {
            // O = 2.5.4.10
            rdns.append(set([sequence([oid([2, 5, 4, 10]), utf8String(organization)])]))
        }
        // CN = 2.5.4.3
        rdns.append(set([sequence([oid([2, 5, 4, 3]), utf8String(commonName)])]))
        return sequence(rdns)
    }

    // MARK: - SubjectPublicKeyInfo

    /// RSA SPKI:
    ///   SEQUENCE { AlgorithmIdentifier(rsaEncryption,NULL), BIT STRING { RSAPublicKey } }
    /// `pkcs1PublicKey` is the PKCS#1 `RSAPublicKey` DER returned by
    /// `SecKeyCopyExternalRepresentation` for an RSA public key.
    static func rsaSubjectPublicKeyInfo(pkcs1PublicKey: Data) -> Data {
        sequence([
            rsaEncryptionAlgorithm(),
            bitString(pkcs1PublicKey),
        ])
    }

    // MARK: - Extensions

    /// KeyUsage bit positions (RFC 5280 §4.2.1.3). The BIT STRING is
    /// big-endian: bit 0 is the most-significant bit of the first byte.
    enum KeyUsageBit: Int {
        case digitalSignature = 0
        case nonRepudiation = 1
        case keyEncipherment = 2
        case dataEncipherment = 3
        case keyAgreement = 4
        case keyCertSign = 5
        case cRLSign = 6
    }

    /// extension ::= SEQUENCE { extnID OID, critical BOOLEAN DEFAULT FALSE,
    ///                          extnValue OCTET STRING }
    static func makeExtension(oidArcs: [UInt], critical: Bool, value: Data) -> Data {
        var elements: [Data] = [oid(oidArcs)]
        if critical { elements.append(boolean(true)) }
        elements.append(octetString(value))
        return sequence(elements)
    }

    /// Extensions block, wrapped in the explicit [3] context tag the
    /// TBSCertificate uses.
    static func extensions(_ exts: [Data]) -> Data {
        let seq = sequence(exts)
        return contextConstructed(3, seq)
    }

    /// BasicConstraints (2.5.4 → actually 2.5.29.19). CA:TRUE for the root.
    static func basicConstraintsCA(critical: Bool, isCA: Bool) -> Data {
        let inner: Data = isCA ? sequence([boolean(true)]) : sequence([])
        return makeExtension(oidArcs: [2, 5, 29, 19], critical: critical, value: inner)
    }

    /// KeyUsage (2.5.29.15). Encodes the named bits into a minimal
    /// BIT STRING with the correct unused-bit count.
    static func keyUsage(bits: [KeyUsageBit], critical: Bool) -> Data {
        let positions = bits.map { $0.rawValue }
        let maxBit = positions.max() ?? 0
        let byteCount = (maxBit / 8) + 1
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for pos in positions {
            let byteIndex = pos / 8
            let bitIndex = 7 - (pos % 8) // bit 0 == MSB
            bytes[byteIndex] |= UInt8(1 << bitIndex)
        }
        // Trim trailing zero bytes (DER minimal) but keep at least one.
        while bytes.count > 1 && bytes.last == 0 { bytes.removeLast() }
        // unused bits = number of low zero bits in the final byte that are
        // beyond the highest set position.
        let lastBytePos = (bytes.count - 1) * 8
        var unused = 0
        if let last = bytes.last, last != 0 {
            var b = last
            while (b & 0x01) == 0 { unused += 1; b >>= 1 }
        }
        _ = lastBytePos
        var body = Data([UInt8(unused)])
        body.append(contentsOf: bytes)
        let bitStr = tlv(tag: 0x03, body)
        return makeExtension(oidArcs: [2, 5, 29, 15], critical: critical, value: bitStr)
    }

    /// ExtendedKeyUsage (2.5.29.37) = { serverAuth 1.3.6.1.5.5.7.3.1 }.
    static func extendedKeyUsageServerAuth() -> Data {
        let eku = sequence([oid([1, 3, 6, 1, 5, 5, 7, 3, 1])])
        return makeExtension(oidArcs: [2, 5, 29, 37], critical: false, value: eku)
    }

    /// SubjectAltName (2.5.29.17) with a single dNSName [2] entry.
    ///   GeneralName dNSName is [2] IA5String (context primitive 0x82).
    static func subjectAltNameDNS(_ host: String) -> Data {
        let dnsName = tlv(tag: 0x82, Data(host.utf8))
        let san = sequence([dnsName])
        return makeExtension(oidArcs: [2, 5, 29, 17], critical: false, value: san)
    }

    /// SubjectKeyIdentifier (2.5.29.14) = OCTET STRING of the key id.
    static func subjectKeyIdentifier(_ keyID: Data) -> Data {
        makeExtension(oidArcs: [2, 5, 29, 14], critical: false, value: octetString(keyID))
    }

    // MARK: - TBSCertificate + Certificate

    /// TBSCertificate ::= SEQUENCE {
    ///   [0] version (v3 = 2),
    ///   serialNumber INTEGER,
    ///   signature AlgorithmIdentifier,
    ///   issuer Name,
    ///   validity SEQUENCE { notBefore, notAfter },
    ///   subject Name,
    ///   subjectPublicKeyInfo,
    ///   [3] extensions
    /// }
    static func tbsCertificate(
        serial: Data,
        issuer: Data,
        subject: Data,
        notBefore: Date,
        notAfter: Date,
        spki: Data,
        extensions: Data
    ) -> Data {
        let version = contextConstructed(0, integer(2)) // v3
        let validity = sequence([time(notBefore), time(notAfter)])
        return sequence([
            version,
            integer(serial),
            sha256WithRSAEncryption(),
            issuer,
            validity,
            subject,
            spki,
            extensions,
        ])
    }

    /// Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue BIT STRING }
    static func certificate(tbs: Data, signatureAlgorithm: Data, signature: Data) -> Data {
        sequence([
            tbs,
            signatureAlgorithm,
            bitString(signature),
        ])
    }
}

/// A tiny DER walker used to re-extract the subject `Name` TLV from a
/// signed certificate (so a leaf's issuer field byte-matches the CA's
/// subject even when the CA was loaded from disk). NOT a validator —
/// it only walks definite-length TLVs.
struct DERParser {
    private let bytes: [UInt8]
    private var pos: Int

    enum ParseError: Error { case truncated, badLength, notSequence, unexpectedTag }

    init(_ data: Data) {
        self.bytes = [UInt8](data)
        self.pos = 0
    }

    private mutating func readTag() throws -> UInt8 {
        guard pos < bytes.count else { throw ParseError.truncated }
        let t = bytes[pos]; pos += 1
        return t
    }

    private mutating func readLength() throws -> Int {
        guard pos < bytes.count else { throw ParseError.truncated }
        let first = bytes[pos]; pos += 1
        if first < 0x80 { return Int(first) }
        let count = Int(first & 0x7F)
        guard count > 0, count <= 4, pos + count <= bytes.count else { throw ParseError.badLength }
        var len = 0
        for _ in 0..<count {
            len = (len << 8) | Int(bytes[pos]); pos += 1
        }
        return len
    }

    /// Expect a SEQUENCE and return its content bytes (the V of the TLV).
    mutating func expectSequence() throws -> Data {
        let tag = try readTag()
        guard tag == 0x30 else { throw ParseError.notSequence }
        let len = try readLength()
        guard pos + len <= bytes.count else { throw ParseError.truncated }
        let content = Data(bytes[pos..<(pos + len)])
        pos += len
        return content
    }

    /// Skip one full TLV element.
    mutating func skipOne() throws {
        _ = try readTag()
        let len = try readLength()
        guard pos + len <= bytes.count else { throw ParseError.truncated }
        pos += len
    }

    /// Skip a single element only if it carries the given context tag
    /// (0xA0 | n). Used for the optional [0] version field.
    mutating func skipIfContextTag(_ n: UInt8) throws {
        guard pos < bytes.count else { return }
        if bytes[pos] == (0xA0 | n) {
            try skipOne()
        }
    }

    /// Read one full TLV element (tag + length + value) and return its
    /// raw bytes.
    mutating func readRawElement() throws -> Data {
        let start = pos
        _ = try readTag()
        let len = try readLength()
        guard pos + len <= bytes.count else { throw ParseError.truncated }
        pos += len
        return Data(bytes[start..<pos])
    }
}
