import Testing
import Foundation
import CryptoKit
@testable import Core

@Suite("ChainHasher canonical bytes + entry hash")
struct ChainHasherTests {

    // MARK: - Canonical bytes

    @Test("Canonical bytes sort columns alphabetically")
    func canonicalBytesSortsColumns() {
        let aFirst = ChainHasher.canonicalBytes(
            table: "token_events",
            columns: [
                "a": .integer(1),
                "b": .integer(2),
                "c": .integer(3),
            ]
        )
        let scrambled = ChainHasher.canonicalBytes(
            table: "token_events",
            columns: [
                "c": .integer(3),
                "a": .integer(1),
                "b": .integer(2),
            ]
        )
        #expect(aFirst == scrambled)
    }

    @Test("Canonical bytes excludes the three chain columns")
    func canonicalBytesExcludesChainColumns() {
        let withChain = ChainHasher.canonicalBytes(
            table: "token_events",
            columns: [
                "id": .integer(1),
                "prev_hash": .text("aaa"),
                "entry_hash": .text("bbb"),
                "chain_anchor_id": .integer(7),
            ]
        )
        let withoutChain = ChainHasher.canonicalBytes(
            table: "token_events",
            columns: [
                "id": .integer(1),
            ]
        )
        #expect(withChain == withoutChain)
    }

    @Test("Canonical bytes encodes NULL as the literal four bytes")
    func canonicalBytesNull() {
        let bytes = ChainHasher.canonicalBytes(
            table: "t",
            columns: ["k": .null]
        )
        let asString = String(decoding: bytes, as: UTF8.self)
        // table || \0 || k=NULL || \0
        #expect(asString.contains("k=NULL"))
        #expect(asString.unicodeScalars.filter { $0.value == 0 }.count == 2)
    }

    @Test("Canonical bytes uses 0x3D for separator and 0x00 for terminator")
    func canonicalBytesSeparators() {
        let bytes = ChainHasher.canonicalBytes(
            table: "tab",
            columns: ["k": .integer(42)]
        )
        // Expected: "tab" || \0 || "k=42" || \0
        let expected: [UInt8] = [
            0x74, 0x61, 0x62, 0x00,                     // "tab\0"
            0x6B, 0x3D, 0x34, 0x32, 0x00,               // "k=42\0"
        ]
        #expect(Array(bytes) == expected)
    }

    @Test("Canonical bytes round-trips integers")
    func canonicalBytesIntegers() {
        let bytes = ChainHasher.canonicalBytes(
            table: "t",
            columns: ["x": .integer(-12345)]
        )
        let s = String(decoding: bytes, as: UTF8.self)
        #expect(s.contains("x=-12345"))
    }

    @Test("Canonical bytes uses 17 significant digits for REAL")
    func canonicalBytesRealRoundTrip() {
        // Pick a value whose default %g rendering would lose precision but
        // %.17g preserves it.
        let v = 0.1 + 0.2
        let bytes = ChainHasher.canonicalBytes(
            table: "t",
            columns: ["x": .real(v)]
        )
        let s = String(decoding: bytes, as: UTF8.self)
        // %.17g for 0.1+0.2 renders as 0.30000000000000004
        #expect(s.contains("x=0.30000000000000004"))
    }

    @Test("Canonical bytes is order-stable across two distinct dictionaries")
    func canonicalBytesDeterministic() {
        let cols1: [String: ChainHasher.CanonicalValue] = [
            "session_id": .text("abc"),
            "input_tokens": .integer(100),
            "command": .null,
        ]
        let cols2: [String: ChainHasher.CanonicalValue] = [
            "command": .null,
            "input_tokens": .integer(100),
            "session_id": .text("abc"),
        ]
        #expect(
            ChainHasher.canonicalBytes(table: "token_events", columns: cols1)
            == ChainHasher.canonicalBytes(table: "token_events", columns: cols2)
        )
    }

    // MARK: - Entry hash

    @Test("Entry hash with nil prev hashes only the canonical bytes")
    func entryHashNilPrev() {
        let cols: [String: ChainHasher.CanonicalValue] = ["x": .integer(1)]
        let canonical = ChainHasher.canonicalBytes(table: "t", columns: cols)

        let viaConvenience = ChainHasher.entryHash(
            table: "t", columns: cols, prev: nil
        )
        let viaPrimitive = ChainHasher.entryHash(
            prev: nil, canonicalBytes: canonical
        )
        let manual = SHA256.hash(data: canonical)
            .map { String(format: "%02x", $0) }
            .joined()

        #expect(viaConvenience == viaPrimitive)
        #expect(viaConvenience == manual)
    }

    @Test("Entry hash with non-nil prev concatenates the prev's UTF-8 bytes")
    func entryHashNonNilPrev() {
        let cols: [String: ChainHasher.CanonicalValue] = ["x": .integer(1)]
        let canonical = ChainHasher.canonicalBytes(table: "t", columns: cols)
        let prev = "deadbeef"

        let computed = ChainHasher.entryHash(
            table: "t", columns: cols, prev: prev
        )

        var hasher = SHA256()
        hasher.update(data: Data(prev.utf8))
        hasher.update(data: canonical)
        let manual = hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()

        #expect(computed == manual)
    }

    @Test("Entry hash returns 64 hex chars and only [0-9a-f]")
    func entryHashShape() {
        let h = ChainHasher.entryHash(
            table: "t",
            columns: ["x": .text("hello")],
            prev: nil
        )
        #expect(h.count == 64)
        #expect(h.allSatisfy { c in
            ("0"..."9").contains(c) || ("a"..."f").contains(c)
        })
    }

    @Test("Single-byte tamper changes the hash")
    func entryHashSingleByteTamper() {
        let h1 = ChainHasher.entryHash(
            table: "t",
            columns: ["x": .text("hello")],
            prev: nil
        )
        let h2 = ChainHasher.entryHash(
            table: "t",
            columns: ["x": .text("hellp")],
            prev: nil
        )
        #expect(h1 != h2)
    }

    @Test("Chained hashes propagate: tamper at N invalidates N+1 too")
    func chainedTamperPropagates() {
        let cols: [String: ChainHasher.CanonicalValue] = ["x": .integer(1)]
        let h1 = ChainHasher.entryHash(table: "t", columns: cols, prev: nil)
        let h2 = ChainHasher.entryHash(table: "t", columns: cols, prev: h1)

        // Tampered: h1 now has a different canonical row → different prev for h2.
        let tamperedCols: [String: ChainHasher.CanonicalValue] = ["x": .integer(2)]
        let h1Tampered = ChainHasher.entryHash(
            table: "t", columns: tamperedCols, prev: nil
        )
        let h2WithTamperedPrev = ChainHasher.entryHash(
            table: "t", columns: cols, prev: h1Tampered
        )

        #expect(h1Tampered != h1)
        #expect(h2WithTamperedPrev != h2)
    }
}
