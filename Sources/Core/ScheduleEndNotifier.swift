import Foundation

#if canImport(Darwin)
import Darwin.POSIX
#endif

/// t6-schedule-end-cli-to-app-bridge — the headless half of the ratified
/// D7 architecture (operator decision 2026-06-08, Torvalds/Carmack;
/// Kleppmann constraint).
///
/// The durable `schedule_end` `token_events` row written by
/// `ScheduleTelemetry.recordEnd(...)` is canonical truth. The GUI banner is
/// best-effort, pushed via the EXISTING hook socket (fire-and-forget) with
/// reconcile-on-launch; the DB row is the fallback queue. Because there is a
/// push path, Kleppmann's constraint is mandatory: a high-water cursor +
/// **session_id dedup** so a live push and a future reconcile replay never
/// double-deliver the same `schedule_end`.
///
/// This type is the idempotent delivery PRIMITIVE that satisfies that
/// constraint by construction. `deliverIfNew(scheduleId:summary:sessionId:)`
/// consults a DURABLE delivered-ledger keyed by `sessionId` (the schedule
/// run's `ScheduleTelemetry.sessionId(taskName:runId:)` value, which matches
/// the DB row for future reconcile dedup):
///
/// - If the `sessionId` is NEW, it fires
///   `NotificationDelivery.deliver(.scheduleEnd(...))`, records the
///   `sessionId` as delivered, and returns `true`.
/// - If the `sessionId` was already delivered, it no-ops and returns `false`.
///
/// The future reconcile-on-launch drain (App-launch, GUI-process, OUT OF
/// SCOPE for this carve) reuses THIS primitive so a replay of an undelivered
/// DB row dedups against a live push that already landed.
///
/// The ledger persists as a small JSON file under `~/.senkani/`, mirroring
/// `TrustSettingsStore` / `ScheduleStore`'s on-disk convention (via
/// `SettingsIO`). The ledger path + clock are injectable so tests run
/// hermetically against a temp dir. No SQLite migration — the blast radius
/// stays a single JSON file.
public enum ScheduleEndNotifier {

    // MARK: - Ledger path

    /// Canonical ledger path under `$HOME/.senkani/`. Honors the
    /// `SENKANI_HOME` env override (same convention as `TrustSettingsPath`)
    /// so tests and sandboxed runs can redirect the whole config dir.
    public static func defaultLedgerPath() -> String {
        if let home = ProcessInfo.processInfo.environment["SENKANI_HOME"], !home.isEmpty {
            return "\(home)/schedule-end-delivered.json"
        }
        return NSString(string: "~/.senkani/schedule-end-delivered.json").expandingTildeInPath
    }

    // MARK: - Idempotent delivery primitive

    /// Deliver a `scheduleEnd` notification exactly once per `sessionId`.
    ///
    /// Returns `true` when this is the FIRST delivery for `sessionId` (the
    /// notification was fired and the sessionId recorded as delivered);
    /// returns `false` when `sessionId` was already delivered (no-op — the
    /// Kleppmann dedup invariant).
    ///
    /// `delivered` (default the durable JSON ledger fire) and `now` (default
    /// the wall clock) are injectable so tests are hermetic. The ledger
    /// read+record is serialized by `ScheduleEndLedger`'s own lock, so a
    /// live push and a future reconcile replay racing on the same sessionId
    /// resolve to a single delivery.
    @discardableResult
    public static func deliverIfNew(
        scheduleId: String,
        summary: String,
        sessionId: String,
        ledgerPath: String? = nil,
        now: () -> Date = { Date() }
    ) -> Bool {
        let ledger = ScheduleEndLedger(path: ledgerPath ?? defaultLedgerPath())
        // markDeliveredIfNew is the atomic test-and-set: it returns true ONLY
        // when sessionId was absent (and was just recorded). A second call
        // with the same sessionId returns false WITHOUT re-firing.
        guard ledger.markDeliveredIfNew(sessionId: sessionId, at: now()) else {
            return false
        }
        NotificationDelivery.deliver(
            .scheduleEnd(scheduleId: scheduleId, summary: summary)
        )
        return true
    }

    // MARK: - Producer: best-effort hook-socket emit (CLI side)

    /// Path of the existing hook socket the App's `SocketServerManager`
    /// listens on. Same path `HookRelay` connects to; reused, not reinvented.
    public static func hookSocketPath() -> String {
        if let home = ProcessInfo.processInfo.environment["SENKANI_HOME"], !home.isEmpty {
            return "\(home)/hook.sock"
        }
        return NSHomeDirectory() + "/.senkani/hook.sock"
    }

    /// Outcome of `emitScheduleEnd`. Mirrors `PaneIPC.SendOutcome` — every
    /// non-`.written` case is a silent no-op for production callers (the DB
    /// row from `recordEnd` is canonical truth); the cases exist so tests
    /// can assert.
    public enum EmitOutcome: Equatable {
        /// The schedule_end frame was framed and written to the socket.
        case written
        /// Socket file absent or connection refused — App not running.
        case socketUnreachable
        /// Socket reached but the frame write failed (short write / hang-up).
        case writeFailed
        /// Encoding the JSON payload failed — should never happen.
        case encodeFailed
    }

    /// Build the canonical `schedule_end` hook-event payload. Extracted so a
    /// test can assert the exact wire shape (`hook_event_name`,
    /// `schedule_id`, `summary`, `session_id`) the HookRouter consumer reads,
    /// without driving a real socket.
    public static func makeEmitPayload(
        scheduleId: String,
        summary: String,
        sessionId: String
    ) -> Data? {
        let event: [String: Any] = [
            "hook_event_name": "schedule_end",
            "schedule_id": scheduleId,
            "summary": summary,
            "session_id": sessionId,
        ]
        return try? JSONSerialization.data(withJSONObject: event)
    }

    /// Fire-and-forget emit of a `schedule_end` message over the EXISTING
    /// hook socket. NON-BLOCKING and swallows all errors: a missing socket
    /// (App not running) is a silent no-op, because the durable DB row from
    /// `ScheduleTelemetry.recordEnd(...)` is canonical truth and the future
    /// reconcile-on-launch drain will replay it through `deliverIfNew`.
    ///
    /// The wire protocol is the SAME length-prefixed `UInt32 big-endian
    /// length + JSON payload` the hook socket already speaks (optionally
    /// preceded by a `SocketAuthToken` handshake frame when
    /// `SENKANI_SOCKET_AUTH=on`). Mirrors `PaneIPC.sendFireAndForget` — the
    /// canonical Core fire-and-forget client — rather than reinventing the
    /// connect/write path.
    ///
    /// Result is discardable: production callers ignore it; tests assert.
    @discardableResult
    public static func emitScheduleEnd(
        scheduleId: String,
        summary: String,
        sessionId: String,
        socketPath: String? = nil
    ) -> EmitOutcome {
        let path = socketPath ?? hookSocketPath()

        guard let payload = makeEmitPayload(
            scheduleId: scheduleId, summary: summary, sessionId: sessionId
        ) else {
            return .encodeFailed
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .socketUnreachable }
        defer { Darwin.close(fd) }

        // SO_SNDTIMEO — cap the write stall at 200 ms so a stuck peer can't
        // defeat fire-and-forget semantics. Same idiom as PaneIPC.
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            return .socketUnreachable
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
            pathBytes.withUnsafeBufferPointer { srcBuf in
                let count = min(srcBuf.count, rawBuf.count)
                rawBuf.baseAddress!.copyMemory(from: srcBuf.baseAddress!, byteCount: count)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            return .socketUnreachable
        }

        // Handshake frame first when SENKANI_SOCKET_AUTH=on — the server
        // rejects unauthenticated clients on the gate path. Reuses the same
        // SocketAuthToken frame HookRelay/PaneIPC use, byte-for-byte.
        if let token = SocketAuthToken.load(),
           let frame = SocketAuthToken.handshakeFrame(token: token) {
            let n = frame.withUnsafeBytes { writeAll(fd, $0.baseAddress!, frame.count) }
            if n != frame.count {
                return .writeFailed
            }
        }

        // UInt32 big-endian length + JSON payload, each through the
        // partial-write loop so a slow reader still receives the full frame.
        var length = UInt32(payload.count).bigEndian
        let lengthData = Data(bytes: &length, count: 4)

        let wroteLen = lengthData.withUnsafeBytes {
            writeAll(fd, $0.baseAddress!, 4)
        }
        guard wroteLen == 4 else { return .writeFailed }

        let wrotePayload = payload.withUnsafeBytes {
            writeAll(fd, $0.baseAddress!, payload.count)
        }
        guard wrotePayload == payload.count else { return .writeFailed }

        // Fire-and-forget: do NOT read the server response. The DB row is
        // canonical truth; the push is best-effort.
        return .written
    }

    /// Blocking write-until-complete of `total` bytes from `buffer` on `fd`,
    /// looping on partial writes and bounded by a stall budget. Same idiom
    /// as `PaneIPC.writeAll` (a single `write(2)` can return a SHORT count
    /// against a slow-but-alive reader; a stuck reader is bounded so the
    /// call cannot hang forever). Returns the total bytes written.
    private static func writeAll(
        _ fd: Int32,
        _ buffer: UnsafeRawPointer,
        _ total: Int
    ) -> Int {
        let maxStallRetries = 10
        let base = buffer.assumingMemoryBound(to: UInt8.self)
        var written = 0
        var stalls = 0
        while written < total {
            let n = Darwin.write(fd, base + written, total - written)
            if n > 0 {
                written += n
                stalls = 0
                continue
            }
            if n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                stalls += 1
                if stalls >= maxStallRetries { break }
                continue
            }
            break
        }
        return written
    }
}

// MARK: - Durable delivered-ledger

/// Durable, thread-safe delivered-ledger for `schedule_end` deliveries,
/// keyed by `sessionId`. Persists as a small JSON file under `~/.senkani/`
/// using the `SettingsIO` atomic-write convention (same shape
/// `TrustSettingsStore` uses).
///
/// The JSON shape is a single `delivered` object mapping
/// `sessionId → ISO-8601 deliveredAt` so the file is human-readable and a
/// future reconcile cursor can inspect it. Unknown keys are ignored on read
/// (migrate-on-read), so a future field never breaks an old file.
///
/// `markDeliveredIfNew` is the atomic test-and-set the Kleppmann dedup
/// invariant rests on: it returns `true` only when `sessionId` was absent
/// (and records it); a second call with the same id returns `false`. The
/// read-modify-write is serialized by an internal `NSLock` so a live push
/// and a reconcile replay racing on the same id can't both win.
final class ScheduleEndLedger: @unchecked Sendable {

    private let path: String
    private static let lock = NSLock()

    init(path: String) {
        self.path = path
    }

    /// Atomic test-and-set. Returns `true` iff `sessionId` was NOT already in
    /// the ledger (it is now recorded with `at` as the deliveredAt stamp);
    /// `false` when it was already present (no write performed).
    func markDeliveredIfNew(sessionId: String, at: Date) -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        var delivered = Self.readDelivered(path: path)
        if delivered[sessionId] != nil {
            return false
        }
        let fmt = ISO8601DateFormatter()
        delivered[sessionId] = fmt.string(from: at)
        Self.writeDelivered(delivered, path: path)
        return true
    }

    /// True iff `sessionId` has already been delivered. Read-only; used by
    /// tests and by a future reconcile cursor to skip already-pushed rows.
    func isDelivered(sessionId: String) -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return Self.readDelivered(path: path)[sessionId] != nil
    }

    // MARK: - JSON I/O (SettingsIO convention)

    private static func readDelivered(path: String) -> [String: String] {
        guard let dict = try? SettingsIO.readJSONOrEmpty(at: path),
              let delivered = dict["delivered"] as? [String: Any] else {
            return [:]
        }
        var out: [String: String] = [:]
        for (k, v) in delivered {
            if let s = v as? String { out[k] = s }
        }
        return out
    }

    private static func writeDelivered(_ delivered: [String: String], path: String) {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        SettingsIO.backupIfFirstWrite(path: path)
        let dict: [String: Any] = ["delivered": delivered]
        // Best-effort: a write failure leaves the prior ledger in place. The
        // DB row remains canonical truth, so a lost ledger write at worst
        // causes a future reconcile to re-push (which dedups on the DB row).
        try? SettingsIO.writeJSONAtomically(dict, to: path)
    }
}
