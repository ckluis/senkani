import Foundation
import CryptoKit

/// Tamper-evident audit-chain primitives for SessionDatabase rows.
///
/// `entry_hash = SHA-256(prev_hash || canonicalRowBytes)` — every row carries
/// a hash chained off the previous row in the same `chain_anchor_id`. A single
/// byte tamper at row N invalidates `entry_hash` at row N AND every later row,
/// so `ChainVerifier` (round-2) names the first broken `(table, rowid)`.
///
/// This file is round-1 of Phase T.5 (`spec/roadmap.md` → "Phase T — Security
/// Floor"). Round-1 ships pure helpers + tests; round-2 wires them into the
/// `TokenEventStore` insert path; round-3 widens to the other three tables;
/// round-4 closes the `--repair-chain` UX. See
/// `spec/architecture.md` → "Tamper-Evident Audit Chain (Phase T.5)" for the
/// full design.
public enum ChainHasher {

    /// Column names that are excluded from canonical bytes — otherwise
    /// `entry_hash` would depend on itself. Future stores that participate in
    /// the chain MUST exclude exactly these three columns.
    public static let excludedColumns: Set<String> = [
        "prev_hash", "entry_hash", "chain_anchor_id",
    ]

    /// A single column value, normalized to a deterministic UTF-8 representation.
    public enum CanonicalValue: Sendable {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
    }

    /// Build the deterministic canonical-byte sequence for a single row.
    ///
    /// Format (UTF-8):
    ///
    ///     table_name || 0x00 ||
    ///     column_1_name || "=" || column_1_value || 0x00 ||
    ///     column_2_name || "=" || column_2_value || 0x00 ||
    ///     …
    ///
    /// - Columns are sorted alphabetically by name to make ordering stable
    ///   regardless of how callers built the dictionary.
    /// - Columns named `prev_hash`, `entry_hash`, `chain_anchor_id` are
    ///   excluded (see `excludedColumns`) so the hash never inputs itself.
    /// - NULL is the literal four bytes `NULL`.
    /// - INTEGER is base-10 with no leading sign for non-negative values.
    /// - REAL uses 17 significant digits (`%.17g`) — round-trip-stable across
    ///   IEEE-754 doubles, which is the bar for "if you read the row back,
    ///   you get the same bytes."
    /// - TEXT is the raw UTF-8 bytes of the string.
    /// - BLOB is the raw bytes (callers don't need to base64-encode; this is
    ///   used inside the hasher only).
    public static func canonicalBytes(
        table: String,
        columns: [String: CanonicalValue]
    ) -> Data {
        var out = Data()
        out.append(contentsOf: table.utf8)
        out.append(0x00)

        let names = columns.keys
            .filter { !excludedColumns.contains($0) }
            .sorted()

        for name in names {
            // Safe — `name` came from `columns.keys`.
            let value = columns[name]!
            out.append(contentsOf: name.utf8)
            out.append(0x3D)  // '='
            out.append(encode(value))
            out.append(0x00)
        }

        return out
    }

    /// SHA-256 of `(prev_hash bytes || canonicalRowBytes)`. `prev_hash` may be
    /// nil for the first row in a chain — in that case the hash inputs only
    /// the canonical row bytes.
    ///
    /// The previous hash is interpreted as raw UTF-8 bytes of the hex string,
    /// not decoded back to bytes. This keeps the chain re-derivable from the
    /// stored TEXT column without ambiguity, and makes
    /// `senkani doctor --verify-chain` straightforwardly equal to "for each
    /// row, recompute and compare."
    public static func entryHash(
        prev: String?,
        canonicalBytes: Data
    ) -> String {
        var hasher = SHA256()
        if let prev {
            hasher.update(data: Data(prev.utf8))
        }
        hasher.update(data: canonicalBytes)
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Convenience: compute `entry_hash` directly from `(table, columns, prev)`.
    public static func entryHash(
        table: String,
        columns: [String: CanonicalValue],
        prev: String?
    ) -> String {
        entryHash(
            prev: prev,
            canonicalBytes: canonicalBytes(table: table, columns: columns)
        )
    }

    // MARK: - Private value encoding

    private static func encode(_ value: CanonicalValue) -> Data {
        switch value {
        case .null:
            return Data("NULL".utf8)
        case .integer(let i):
            return Data(String(i).utf8)
        case .real(let d):
            // 17-significant-digit `%.17g` is the IEEE-754 round-trip floor for
            // a 64-bit double. Anything fewer digits and a future read could
            // bind a different bit pattern and break verification.
            return Data(String(format: "%.17g", d).utf8)
        case .text(let s):
            return Data(s.utf8)
        case .blob(let b):
            return b
        }
    }
}
