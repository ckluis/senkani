import Foundation

/// Minimal SNI extractor for TLS ClientHello bytes. Schneier audit
/// 2026-05-06: a CONNECT line carries operator-controlled bytes, but
/// the SNI is what most TLS stacks actually use for routing — the
/// proxy MUST validate the SNI matches the CONNECT host before opening
/// the upstream tunnel.
///
/// We parse just enough to find the `server_name` extension and pull
/// the `host_name` value. We do NOT verify the certificate, decrypt
/// any traffic, or modify the bytes. The caller is responsible for
/// feeding in the first record off the wire after CONNECT 200.
///
/// Wire layout (RFC 8446 / RFC 6066):
///
///     // TLS record:
///     uint8  content_type    // 0x16 (handshake)
///     uint16 version         // 0x0301..0x0304
///     uint16 length
///     // Handshake:
///     uint8  msg_type        // 0x01 (ClientHello)
///     uint24 length
///     uint16 client_version
///     uint8[32] random
///     opaque session_id<0..32>
///     opaque cipher_suites<2..2^16-2>
///     opaque compression_methods<1..2^8-1>
///     opaque extensions<0..2^16-1>
///       // Extension:
///       uint16 type
///       opaque data<0..2^16-1>
///         // server_name (type=0x0000) data:
///         opaque server_name_list<2..2^16-1>
///           uint8 name_type   // 0x00 = host_name
///           opaque host_name<1..2^16-1>
public enum TLSClientHelloSNI {

    public enum ParseError: Error, Equatable {
        case truncated
        case notHandshake
        case notClientHello
        case noSNI
    }

    /// Extract the host_name value from a ClientHello. Returns the host
    /// as ASCII (the SNI field is restricted to ASCII per RFC 6066).
    public static func extract(_ bytes: Data) throws -> String {
        var cursor = Cursor(bytes: bytes)

        // TLS record header.
        guard try cursor.readU8() == 0x16 else { throw ParseError.notHandshake }
        _ = try cursor.readU16() // legacy version
        _ = try cursor.readU16() // record length

        // Handshake header.
        guard try cursor.readU8() == 0x01 else { throw ParseError.notClientHello }
        _ = try cursor.readU24() // handshake length

        // ClientHello body.
        _ = try cursor.readU16() // client_version
        try cursor.skip(32)      // random
        let sessionIdLen = Int(try cursor.readU8())
        try cursor.skip(sessionIdLen)
        let cipherSuitesLen = Int(try cursor.readU16())
        try cursor.skip(cipherSuitesLen)
        let compMethodsLen = Int(try cursor.readU8())
        try cursor.skip(compMethodsLen)

        let extensionsLen = Int(try cursor.readU16())
        let extensionsEnd = cursor.position + extensionsLen
        guard extensionsEnd <= bytes.count else { throw ParseError.truncated }

        while cursor.position < extensionsEnd {
            let extType = try cursor.readU16()
            let extLen = Int(try cursor.readU16())
            let extEnd = cursor.position + extLen
            guard extEnd <= bytes.count else { throw ParseError.truncated }
            if extType == 0x0000 {
                // server_name extension.
                _ = try cursor.readU16() // server_name_list length
                let nameType = try cursor.readU8()
                guard nameType == 0x00 else {
                    cursor.position = extEnd
                    continue
                }
                let nameLen = Int(try cursor.readU16())
                guard cursor.position + nameLen <= bytes.count else { throw ParseError.truncated }
                let nameBytes = bytes.subdata(in: cursor.position..<(cursor.position + nameLen))
                guard let host = String(data: nameBytes, encoding: .utf8), !host.isEmpty else {
                    throw ParseError.noSNI
                }
                return host
            }
            cursor.position = extEnd
        }
        throw ParseError.noSNI
    }

    private struct Cursor {
        let bytes: Data
        var position: Int = 0

        mutating func readU8() throws -> UInt8 {
            guard position < bytes.count else { throw ParseError.truncated }
            defer { position += 1 }
            return bytes[bytes.startIndex + position]
        }
        mutating func readU16() throws -> UInt16 {
            let hi = UInt16(try readU8())
            let lo = UInt16(try readU8())
            return (hi << 8) | lo
        }
        mutating func readU24() throws -> UInt32 {
            let a = UInt32(try readU8())
            let b = UInt32(try readU8())
            let c = UInt32(try readU8())
            return (a << 16) | (b << 8) | c
        }
        mutating func skip(_ n: Int) throws {
            guard position + n <= bytes.count else { throw ParseError.truncated }
            position += n
        }
    }
}
