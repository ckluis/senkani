// Sources/HookRelay/HookRelay.swift
//
// Canonical implementation of the hook relay binary logic.
// Shared by the standalone senkani-hook executable AND the app's --hook mode.
// MUST have ZERO dependencies beyond Foundation + Darwin.POSIX (Lesson #12).

import Foundation
#if canImport(Darwin)
import Darwin.POSIX
#endif

public enum HookRelay {

    private static let socketPath = NSHomeDirectory() + "/.senkani/hook.sock"
    internal static let defaultTokenPath = NSHomeDirectory() + "/.senkani/.token"
    private static let timeoutMs: UInt32 = 5 // 5ms — hooks must be imperceptible

    /// Append-log of deadline-driven passthroughs (the gate-bypass signal).
    /// See `recordDrop`. Path is injectable for tests only.
    internal static let defaultDropLogPath = NSHomeDirectory() + "/.senkani/hook-relay-drops.log"

    /// P2-12: read a same-UID-only token file. Returns nil if absent or
    /// insecure. Inlined (not imported from Core) to preserve HookRelay's
    /// zero-dependency contract — see Lesson #12 in the file header.
    ///
    /// `path` is injectable for tests only — production always calls with
    /// the default (nil → `defaultTokenPath`). Must stay in sync with
    /// `Core.SocketAuthToken.load(at:)` (see that file's F7 note).
    internal static func loadAuthToken(at path: String? = nil) -> String? {
        let target = path ?? defaultTokenPath
        guard FileManager.default.fileExists(atPath: target) else { return nil }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: target),
           let posix = attrs[.posixPermissions] as? NSNumber,
           (posix.uint16Value & 0o177) != 0 {
            return nil
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: target)),
              let hex = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
              !hex.isEmpty
        else { return nil }
        return hex
    }

    /// P2-12: send length-prefixed handshake frame on the given fd.
    /// Returns true on successful write, false on short-write / I/O error.
    /// No-op (returns true) when no token file is present — server-side
    /// enforcement is gated by SENKANI_SOCKET_AUTH on the server.
    ///
    /// `tokenPath` is injectable for tests only. The frame format MUST
    /// match `Core.SocketAuthToken.handshakeFrame(token:)` byte-for-byte
    /// or the inline-vs-Core drift the audit flagged will reappear.
    internal static func sendHandshake(fd: Int32, tokenPath: String? = nil) -> Bool {
        guard let token = loadAuthToken(at: tokenPath) else { return true }
        let body = "{\"handshake\":{\"token\":\"\(token)\"}}"
        let payload = Data(body.utf8)
        var length = UInt32(payload.count).bigEndian
        let lengthData = Data(bytes: &length, count: 4)
        let w1 = lengthData.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, 4) }
        guard w1 == 4 else { return false }
        let w2 = payload.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, payload.count) }
        return w2 == payload.count
    }

    /// Best-effort parse of the Claude Code hook event name (`PreToolUse`,
    /// `PostToolUse`, `Notification`, `Stop`, …) from the raw stdin payload.
    /// Used ONLY to LABEL a dropped-verdict log line so the operator can tell
    /// a deny-capable drop (PreToolUse) from a never-deny one (Notification).
    /// Returns nil on any parse failure — observability must never throw or
    /// change the passthrough contract. Foundation-only (zero-dep, Lesson #12).
    internal static func hookEventName(from data: Data) -> String? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["hook_event_name"] as? String,
              !name.isEmpty
        else { return nil }
        return name
    }

    /// CARVE 1 (observability, pure-additive): record a DEADLINE-driven
    /// passthrough — the relay gave up on the server's verdict before it
    /// arrived, so any `deny`/`block` the server computed past the deadline
    /// was silently discarded and the tool call proceeded UNBLOCKED. This is
    /// the gate-bypass signal of
    /// `t6-hook-relay-5ms-deadline-drops-deny-decisions-2026-06-22`. It does
    /// NOT change behavior (the caller still passes through); it makes the
    /// otherwise-invisible drop detectable.
    ///
    /// Appends one TSV line `<iso8601>\t<reason>\t<hook_event_name>\n` to the
    /// drop log via an atomic `O_APPEND` write, so concurrent short-lived
    /// relay processes don't clobber each other. Entirely best-effort: any
    /// failure (no dir, no perms, full disk) is swallowed — a relay must
    /// never fail a hook because it couldn't write a metric. `path`/`now` are
    /// injectable for tests only. Zero-dep (Foundation + Darwin.POSIX).
    internal static func recordDrop(reason: String,
                                    hookEvent: String?,
                                    at path: String? = nil,
                                    now: Date = Date()) {
        let target = path ?? defaultDropLogPath
        let dir = (target as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let ts = ISO8601DateFormatter().string(from: now)
        let event = (hookEvent ?? "unknown")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let line = "\(ts)\t\(reason)\t\(event)\n"
        let fd = Darwin.open(target, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        _ = Data(line.utf8).withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return -1 }
            return Darwin.write(fd, base, buf.count)
        }
    }

    /// Relay a hook event from stdin to the daemon socket and write the response to stdout.
    /// On ANY failure, emits `{}` (passthrough — never block the agent).
    public static func run() -> Int32 {
        // Check activation env vars
        let intercept = ProcessInfo.processInfo.environment["SENKANI_INTERCEPT"] ?? "off"
        let hookEnabled = ProcessInfo.processInfo.environment["SENKANI_HOOK"] ?? "off"
        guard intercept == "on" || hookEnabled == "on" else {
            passthrough()
            return 0
        }

        // Read hook event JSON from stdin
        let inputData = FileHandle.standardInput.readDataToEndOfFile()
        guard !inputData.isEmpty else {
            passthrough()
            return 0
        }

        // Connect to daemon socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            passthrough()
            return 0
        }
        defer { Darwin.close(fd) }

        // Set non-blocking for timeout control
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        // Build sockaddr_un
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            passthrough()
            return 0
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            pathBytes.withUnsafeBufferPointer { buf in
                let dest = UnsafeMutableRawPointer(sunPath).assumingMemoryBound(to: CChar.self)
                buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) { src in
                    dest.update(from: src, count: buf.count)
                }
            }
        }

        // Connect
        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if connectResult != 0 && errno != EINPROGRESS {
            passthrough()
            return 0
        }

        // Wait for connect with poll (5ms timeout)
        var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pollResult = poll(&pollFD, 1, Int32(timeoutMs))
        guard pollResult > 0 else {
            // Deadline drop: server didn't accept within the deadline. Any
            // verdict it would have computed never reaches us → bypass signal.
            recordDrop(reason: "connect_timeout", hookEvent: hookEventName(from: inputData))
            passthrough()
            return 0
        }

        // Switch back to blocking for write/read
        _ = fcntl(fd, F_SETFL, flags)

        // P2-12: send handshake first if a token file exists. Server rejects
        // when auth is enabled and the handshake is missing/wrong.
        guard sendHandshake(fd: fd) else { passthrough(); return 0 }

        // Send: 4-byte length prefix + JSON payload
        var length = UInt32(inputData.count).bigEndian
        let lengthData = Data(bytes: &length, count: 4)
        let sent1 = lengthData.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, 4) }
        guard sent1 == 4 else { passthrough(); return 0 }

        let sent2 = inputData.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, inputData.count) }
        guard sent2 == inputData.count else { passthrough(); return 0 }

        // Read response: 4-byte length prefix + JSON
        pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let readPoll = poll(&pollFD, 1, Int32(timeoutMs))
        guard readPoll > 0 else {
            // THE critical deadline drop: the server accepted our request and
            // is running HookRouter.handle() (which routinely exceeds 5ms),
            // but the response — possibly a `deny`/`block` — did not arrive in
            // time. We pass through (approve) and the verdict is discarded.
            recordDrop(reason: "read_timeout", hookEvent: hookEventName(from: inputData))
            passthrough()
            return 0
        }

        var respLengthBytes = [UInt8](repeating: 0, count: 4)
        let readLen = Darwin.read(fd, &respLengthBytes, 4)
        guard readLen == 4 else { passthrough(); return 0 }

        let respLength = Int(UInt32(bigEndian: Data(respLengthBytes).withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard respLength > 0, respLength < 65536 else { passthrough(); return 0 }

        var respBuffer = Data(count: respLength)
        var totalRead = 0
        while totalRead < respLength {
            let n = respBuffer.withUnsafeMutableBytes { buf in
                Darwin.read(fd, buf.baseAddress! + totalRead, respLength - totalRead)
            }
            if n <= 0 { break }
            totalRead += n
        }
        guard totalRead == respLength else { passthrough(); return 0 }

        // Write response to stdout
        FileHandle.standardOutput.write(respBuffer)
        return 0
    }

    private static func passthrough() {
        FileHandle.standardOutput.write(Data("{}".utf8))
    }
}
