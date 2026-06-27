// Sources/HookRelay/HookRelayDropSummary.swift
//
// READ-SIDE summarizer of the hook-relay drop log written by
// `HookRelay.recordDrop`. The writer appends one TSV line per
// deadline-driven passthrough — `<iso8601>\t<reason>\t<hook_event_name>` —
// to `~/.senkani/hook-relay-drops.log`. This file parses that log into a
// pure, testable rollup the `senkani doctor` surface can render.
//
// MUST have ZERO dependencies beyond Foundation (Lesson #12): this stays in
// the HookRelay target so it can NEVER import Core, exactly like the writer.
// It ADDS nothing to the writer's behavior — it only reads.

import Foundation

/// A pure rollup of the hook-relay drop log.
///
/// `byReason` / `byHookEvent` count over ALL well-formed lines (within the
/// loaded tail — see `load`); `recentByReason` / `recentTotal` count only the
/// subset whose timestamp parses AND is in the `[now - recentWindow, now]`
/// window (a future-dated row never counts as recent). The two convenience
/// fields surface the two signals an operator actually acts on:
/// `preToolUseReadTimeouts` (a `read_timeout` on a `PreToolUse` hook — the
/// deny-capable gate that may have been bypassed) and `failClosedFires`
/// (the `read_timeout_failclosed_ask` escalation rate).
public struct HookRelayDropSummary: Equatable, Sendable {
    /// All well-formed lines (a row whose timestamp does not parse still
    /// counts here — it just never counts in the recent window).
    public var total: Int
    /// All-time count keyed by the reason field (field 1).
    public var byReason: [String: Int]
    /// All-time count keyed by the hook_event_name field (field 2).
    public var byHookEvent: [String: Int]
    /// Count of well-formed lines whose timestamp parsed AND is within
    /// `recentWindow` of `now`.
    public var recentTotal: Int
    /// Recent-window count keyed by reason.
    public var recentByReason: [String: Int]
    /// All-time count of rows that are BOTH `read_timeout` AND `PreToolUse`
    /// — the gate-bypass indicator (a deny-capable hook whose verdict was
    /// dropped past the read deadline). Stored (not derived) because the
    /// cross-tab is not recoverable from the two independent `byReason` /
    /// `byHookEvent` histograms; `summarize` is the only writer.
    public var preToolUseReadTimeouts: Int
    /// Non-blank lines that were NOT well-formed (fewer than 3 tab fields).
    /// Lets the doctor surface distinguish a genuinely empty log (healthy)
    /// from a non-empty log whose rows could not be parsed (drops present but
    /// unreadable — NOT healthy).
    public var malformedLines: Int
    /// True when `load` read only the tail of an over-cap log; the all-time
    /// counts then cover the loaded tail, not the whole file.
    public var truncated: Bool

    public init(
        total: Int = 0,
        byReason: [String: Int] = [:],
        byHookEvent: [String: Int] = [:],
        recentTotal: Int = 0,
        recentByReason: [String: Int] = [:],
        preToolUseReadTimeouts: Int = 0,
        malformedLines: Int = 0,
        truncated: Bool = false
    ) {
        self.total = total
        self.byReason = byReason
        self.byHookEvent = byHookEvent
        self.recentTotal = recentTotal
        self.recentByReason = recentByReason
        self.preToolUseReadTimeouts = preToolUseReadTimeouts
        self.malformedLines = malformedLines
        self.truncated = truncated
    }

    /// The all-zero summary an empty / absent / unreadable log yields.
    public static let empty = HookRelayDropSummary()

    /// All-time count of `read_timeout_failclosed_ask` rows — the fail-closed
    /// escalation ("ask the human gate") fire rate.
    public var failClosedFires: Int { byReason["read_timeout_failclosed_ask"] ?? 0 }
}

extension HookRelayDropSummary {

    /// The default drop-log path, surfaced from the HookRelay enum's
    /// `internal` constant so the doctor surface (which calls
    /// `load(now:)` with no path) names the same file the writer uses
    /// WITHOUT loosening the writer-side constant to `public`.
    public static func defaultDropLogPath() -> String {
        HookRelay.defaultDropLogPath
    }

    /// Sanitize a LOG-DERIVED string for terminal display. The
    /// `hook_event_name` field originates in an external hook payload, so a
    /// crafted value can carry ANSI escapes / control chars that would let the
    /// drop log SPOOF or corrupt the trusted `senkani doctor` output (erase the
    /// line, recolor, hide the gate-bypass count). Strip every C0 control char
    /// (`< 0x20`, including ESC `0x1B` / CR / BEL), DEL (`0x7F`), and C1
    /// (`0x80–0x9F`), then cap the length. This is the LOAD-BEARING defense:
    /// logs already on disk may carry raw escapes regardless of writer hygiene.
    public static func sanitizeForDisplay(_ s: String, maxLength: Int = 40) -> String {
        let scalars = s.unicodeScalars.filter { scalar in
            let v = scalar.value
            return !(v < 0x20 || v == 0x7F || (v >= 0x80 && v <= 0x9F))
        }
        let cleaned = String(String.UnicodeScalarView(scalars))
        if cleaned.count > maxLength {
            return String(cleaned.prefix(maxLength)) + "…"
        }
        return cleaned
    }

    /// Parse `contents` (the raw TSV log) into a rollup as of `now`.
    ///
    /// Parse rules (defensive — a malformed log NEVER produces a fatal
    /// error):
    ///   * Split on newlines. An empty / whitespace-only line is skipped.
    ///   * A WELL-FORMED line splits into ≥ 3 tab-separated fields
    ///     (timestamp, reason, hookEvent). Fewer than 3 tab fields →
    ///     MALFORMED → counted in `malformedLines` and skipped (does NOT abort
    ///     the parse; well-formed lines around it still count).
    ///   * `total` / `byReason` / `byHookEvent` count over well-formed lines.
    ///   * For the recent window: field 0 is parsed as ISO-8601. A row whose
    ///     timestamp PARSES and is in `[now - recentWindow, now]` counts in
    ///     `recentTotal` / `recentByReason` — a FUTURE-dated row (skew /
    ///     tampering) is excluded. An UNPARSEABLE timestamp still counts in the
    ///     all-time totals but NOT the recent window.
    public static func summarize(
        contents: String,
        now: Date,
        recentWindow: TimeInterval = 86_400
    ) -> HookRelayDropSummary {
        var total = 0
        var byReason: [String: Int] = [:]
        var byHookEvent: [String: Int] = [:]
        var recentTotal = 0
        var recentByReason: [String: Int] = [:]
        var preToolUseReadTimeouts = 0
        var malformedLines = 0

        // Fresh formatters per call — `ISO8601DateFormatter` is not
        // documented thread-safe and a summarizer is cheap to construct. The
        // writer emits a bare (no-fractional-seconds) ISO-8601 stamp, but
        // operator-edited / future logs may carry fractional seconds, so we
        // try the plain formatter first and fall back to a fractional one.
        let plainFormatter = ISO8601DateFormatter()
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            // A well-formed line has ≥ 3 tab fields. `split` with the default
            // `omittingEmptySubsequences: true` would mis-handle empty fields,
            // so keep them and require at least three components.
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 3 else {
                malformedLines += 1  // non-blank but unparseable → count, skip
                continue
            }

            let timestampField = fields[0]
            let reason = fields[1]
            let hookEvent = fields[2]

            total += 1
            byReason[reason, default: 0] += 1
            byHookEvent[hookEvent, default: 0] += 1
            if reason == "read_timeout" && hookEvent == "PreToolUse" {
                preToolUseReadTimeouts += 1
            }

            // Recent-window membership requires a parseable timestamp that is
            // not in the future: `delta` in `[0, recentWindow]`.
            let parsed = plainFormatter.date(from: timestampField)
                ?? fractionalFormatter.date(from: timestampField)
            if let ts = parsed {
                let delta = now.timeIntervalSince(ts)
                if delta >= 0 && delta <= recentWindow {
                    recentTotal += 1
                    recentByReason[reason, default: 0] += 1
                }
            }
        }

        return HookRelayDropSummary(
            total: total,
            byReason: byReason,
            byHookEvent: byHookEvent,
            recentTotal: recentTotal,
            recentByReason: recentByReason,
            preToolUseReadTimeouts: preToolUseReadTimeouts,
            malformedLines: malformedLines
        )
    }

    /// Load + summarize the drop log at `path`. An ABSENT or UNREADABLE file
    /// yields the all-zero summary — this NEVER throws (a missing log is the
    /// healthy "no drops yet" state, identical to an empty one).
    ///
    /// The drop log is append-only and NEVER rotated, and it grows FASTEST in
    /// the exact failure mode this surface exists to diagnose (a machine whose
    /// gate constantly times out). So a naive whole-file read + per-line
    /// ISO-8601 parse turns `senkani doctor` into a multi-second soft hang on a
    /// large log. Read only the last `maxBytes` (the tail holds the recent,
    /// actionable entries since the log is chronological); `truncated` records
    /// that the all-time counts then cover the tail, not the whole file.
    public static func load(
        path: String? = nil,
        now: Date,
        recentWindow: TimeInterval = 86_400,
        maxBytes: Int = 1_048_576
    ) -> HookRelayDropSummary {
        // `path == nil` → the writer's default. Resolved via the public
        // accessor (not the `internal` constant directly) so this default
        // works from any module without loosening the writer-side constant.
        let target = path ?? defaultDropLogPath()
        guard let handle = FileHandle(forReadingAtPath: target) else { return .empty }
        defer { try? handle.close() }

        let size: UInt64
        do { size = try handle.seekToEnd() } catch { return .empty }

        var truncated = false
        let start: UInt64
        if size > UInt64(maxBytes) {
            truncated = true
            start = size - UInt64(maxBytes)
        } else {
            start = 0
        }
        do { try handle.seek(toOffset: start) } catch { return .empty }

        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            // EOF / empty file → no drops.
            return .empty
        }
        // `String(decoding:as:)` is lossy on invalid UTF-8 (replacement chars)
        // rather than nil — one bad byte no longer nukes the whole summary.
        var contents = String(decoding: data, as: UTF8.self)
        if truncated, let nl = contents.firstIndex(of: "\n") {
            // Seeking into the middle of the file usually lands mid-line; drop
            // that partial first line so it isn't mis-counted as malformed.
            contents = String(contents[contents.index(after: nl)...])
        }

        var summary = summarize(contents: contents, now: now, recentWindow: recentWindow)
        summary.truncated = truncated
        return summary
    }
}
