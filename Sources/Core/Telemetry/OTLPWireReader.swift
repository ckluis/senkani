import Foundation

/// V.18a-3 — minimal protobuf wire-format reader, scoped to the
/// fields the OTLP receiver lifts out of `ExportTraceServiceRequest`
/// and `ExportLogsServiceRequest`.
///
/// The senkani build does not depend on `swift-protobuf`. The proto
/// files for OTLP define hundreds of messages; we only need to walk
/// the nesting (`ResourceSpans` → `ScopeSpans` → `Span`) and pull
/// five fields per span (trace_id, span_id, parent_span_id, name,
/// start_time_unix_nano, end_time_unix_nano), and the analogous
/// minimum for `LogRecord`. Hand-walking the wire format keeps the
/// dependency footprint small and the parser auditable.
///
/// Wire types per the protobuf spec:
///   0 = VARINT          (int32, int64, uint32, uint64, bool, enum)
///   1 = I64             (fixed64, sfixed64, double)
///   2 = LEN             (bytes, string, embedded message, packed repeated)
///   5 = I32             (fixed32, sfixed32, float)
///
/// All unknown fields are skipped via the wire type — forward
/// compatibility comes for free.
public struct OTLPWireReader {
    public enum WireType: Int {
        case varint = 0
        case i64 = 1
        case length = 2
        case i32 = 5

        static func from(_ raw: UInt64) -> WireType? {
            return WireType(rawValue: Int(raw & 0x7))
        }
    }

    public enum ReadError: Error, Equatable {
        case truncated
        case overflow
        case unknownWireType(UInt64)
    }

    private let bytes: Data
    private var offset: Int

    public init(_ bytes: Data, offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    public var isAtEnd: Bool { offset >= bytes.count }
    public var position: Int { offset }

    /// Read a single base-128 varint. Up to 10 bytes for a uint64.
    public mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var count = 0
        while count < 10 {
            guard offset < bytes.count else { throw ReadError.truncated }
            let b = bytes[bytes.startIndex + offset]
            offset += 1
            result |= UInt64(b & 0x7F) << shift
            if (b & 0x80) == 0 {
                return result
            }
            shift += 7
            count += 1
        }
        throw ReadError.overflow
    }

    /// Read tag: returns (field_number, wire_type).
    public mutating func readTag() throws -> (Int, WireType) {
        let raw = try readVarint()
        guard let wt = WireType.from(raw) else { throw ReadError.unknownWireType(raw) }
        let field = Int(raw >> 3)
        return (field, wt)
    }

    /// Read a length-delimited field (LEN wire type). Returns the
    /// payload bytes (a slice — no copy).
    public mutating func readLengthDelimited() throws -> Data {
        let len = try readVarint()
        guard offset + Int(len) <= bytes.count else { throw ReadError.truncated }
        let start = bytes.startIndex + offset
        let end = start + Int(len)
        offset += Int(len)
        return bytes.subdata(in: start..<end)
    }

    /// Read a fixed 64-bit value (little-endian).
    public mutating func readFixed64() throws -> UInt64 {
        guard offset + 8 <= bytes.count else { throw ReadError.truncated }
        var v: UInt64 = 0
        for i in 0..<8 {
            v |= UInt64(bytes[bytes.startIndex + offset + i]) << (UInt64(i) * 8)
        }
        offset += 8
        return v
    }

    /// Read a fixed 32-bit value (little-endian).
    public mutating func readFixed32() throws -> UInt32 {
        guard offset + 4 <= bytes.count else { throw ReadError.truncated }
        var v: UInt32 = 0
        for i in 0..<4 {
            v |= UInt32(bytes[bytes.startIndex + offset + i]) << (UInt32(i) * 8)
        }
        offset += 4
        return v
    }

    /// Skip a value matching `wt`. Used to step past unknown fields.
    public mutating func skipValue(wireType wt: WireType) throws {
        switch wt {
        case .varint:
            _ = try readVarint()
        case .i64:
            _ = try readFixed64()
        case .length:
            _ = try readLengthDelimited()
        case .i32:
            _ = try readFixed32()
        }
    }
}

/// Hex-encode raw bytes for storage in the V.18a-2 `TEXT NOT NULL`
/// `trace_id`/`span_id` columns. OTLP transmits IDs as 16-byte
/// (trace) and 8-byte (span) opaque values; senkani's existing rows
/// store them as hex strings, matching the canonical OpenTelemetry
/// presentation in tooling.
public enum OTLPHex {
    private static let table: [UInt8] = Array("0123456789abcdef".utf8)

    public static func encode(_ data: Data) -> String {
        var out = [UInt8]()
        out.reserveCapacity(data.count * 2)
        for b in data {
            out.append(table[Int(b >> 4)])
            out.append(table[Int(b & 0x0f)])
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }
}
