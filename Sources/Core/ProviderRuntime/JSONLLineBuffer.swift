import Foundation
import CryptoKit

/// Phase V.17a-7 — shared JSONL line-buffer + SHA-256 helper for
/// V.17a adapter implementations.
///
/// Lifts the line-buffer + CRLF + SHA-256 quintet that previously
/// existed verbatim in four V.17a adapter files
/// (`CodexCLIRuntimeAdapter`, `ClaudeCodeRuntimeAdapter`,
/// `GeminiCLIRuntimeAdapter`, `OpenCodeRuntimeAdapter`) into the
/// V.17a-1 spine. Pre-authorized by the V.17 parent's operator
/// interview Q3 (2026-05-23): "shared utility surfaces ... inline
/// into the spine for now; if they grow past trivial, file a 7th
/// sub-item." Filed during the V.17a-4 close-round close hook
/// (2026-05-23); ships today now that all four adapters have
/// landed.
///
/// **Behavior is API-shape-preserving** vs. the per-adapter inlines:
/// the same input bytes produce the same complete-line set and the
/// same `raw_payload_hash` values. The four V.17a adapter test
/// suites (18 tests total) stay green verbatim after the refactor
/// — no `raw_payload_hash` drift, no partial-buffer carryover
/// contract change.
///
/// **Empty-line filtering.** The helper drops empty lines because
/// JSONL streams sometimes emit a blank terminator after the final
/// row; an empty buffer slice has no JSON decode shape. This
/// matches the dominant inline behavior across V.17a-2/V.17a-4/
/// V.17a-5; V.17a-3 (Claude Code) historically deferred the empty
/// check to `parseLine`, which becomes a redundant guard after the
/// refactor — preserved for defense-in-depth.
public final class JSONLLineBuffer: @unchecked Sendable {
    private var pending: Data = Data()
    private let lock = NSLock()

    public init() {}

    /// Append `raw` to the internal buffer, split on `\n`, strip
    /// trailing `\r` (CRLF normalization), drop empty lines, and
    /// return the complete CR-stripped lines. Any trailing bytes
    /// past the last newline stay in the buffer for the next call
    /// — partial-buffer carryover is independent of chunk
    /// boundaries.
    public func append(_ raw: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        pending.append(raw)
        var lines: [Data] = []
        var lineStart = pending.startIndex
        var idx = pending.startIndex
        while idx < pending.endIndex {
            if pending[idx] == 0x0A {  // '\n'
                let line = pending.subdata(in: lineStart..<idx)
                lines.append(Self.stripCR(line))
                lineStart = pending.index(after: idx)
            }
            idx = pending.index(after: idx)
        }
        if lineStart < pending.endIndex {
            pending = pending.subdata(in: lineStart..<pending.endIndex)
        } else {
            pending.removeAll(keepingCapacity: true)
        }
        return lines.filter { !$0.isEmpty }
    }

    /// Strip a single trailing `\r` if present. The hash is
    /// computed on CR-stripped bytes so streams crossing a CRLF-
    /// translating tty produce identical hashes.
    private static func stripCR(_ data: Data) -> Data {
        if let last = data.last, last == 0x0D {
            return data.subdata(in: data.startIndex..<data.index(before: data.endIndex))
        }
        return data
    }
}

/// Hex-encoded SHA-256 helper for `raw_payload_hash` derivation.
/// Stateless namespace — separate from `JSONLLineBuffer` because
/// hashing is a pure function over bytes (no buffer state, no
/// reuse concerns).
public enum ProviderRuntimeHash {
    /// Hex-encoded SHA-256 of `data`. Stable across Apple
    /// platforms; matches what `provider_runtime_event.raw_payload_hash`
    /// UNIQUE constraint dedupes on.
    public static func sha256Hex(of data: Data) -> String {
        var digest = SHA256()
        digest.update(data: data)
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
