import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One wake-up event for the TUI event loop. The loop blocks on a
/// `TUIEventSource` until one of these arrives, then acts on it.
public enum TUIEvent: Equatable {
    /// A byte was read from stdin.
    case key(UInt8)
    /// The poll interval elapsed with no key — re-render (delta).
    case tick
    /// Terminal was resized (SIGWINCH) — force a full repaint.
    case resize
    /// SIGINT / SIGTERM arrived — flush, restore, exit 0.
    case signal
    /// stdin reached EOF — exit.
    case eof
}

/// Pluggable source of `TUIEvent`s. Production uses `PollEventSource`
/// (poll(2) on the stdin fd, timeout = poll interval, plus a signal /
/// resize self-pipe). Tests inject `ScriptedEventSource` to drive a
/// deterministic sequence of events with NO wall-clock sleeps.
public protocol TUIEventSource: AnyObject {
    /// Block until the next event (or the poll interval elapses, in
    /// which case `.tick`). Returns `nil` only if the source is
    /// permanently exhausted (treated like `.eof`).
    func nextEvent() -> TUIEvent?
}

/// Deterministic test source. Replays a pre-built queue of events; the
/// loop consumes them one at a time. No timers, no fds, no sleeps — a
/// `.tick` is just an enqueued event, so a test can drive "N poll
/// ticks" by enqueuing N `.tick`s.
public final class ScriptedEventSource: TUIEventSource {
    private var queue: [TUIEvent]
    private var index = 0
    /// Records how many events were actually consumed (for assertions).
    public private(set) var consumed = 0

    public init(_ events: [TUIEvent]) {
        self.queue = events
    }

    public func nextEvent() -> TUIEvent? {
        guard index < queue.count else { return nil }
        let event = queue[index]
        index += 1
        consumed += 1
        return event
    }
}

#if canImport(Darwin)
/// Production event source. Bridges three wake-up reasons into one
/// blocking call:
///   1. a byte readable on the stdin fd,
///   2. the poll interval elapsing (`poll(2)` timeout → `.tick`),
///   3. an async signal (SIGWINCH / SIGINT / SIGTERM) delivered via a
///      self-pipe whose read end is also watched by `poll(2)`.
///
/// The self-pipe trick keeps signal handling async-safe: the C handler
/// only does a single non-blocking `write()` of a 1-byte tag; the loop
/// drains + classifies the tag on the next `poll(2)` wake.
public final class PollEventSource: TUIEventSource {
    private let stdinFD: Int32
    private let pollTimeoutMS: Int32

    public init(stdinFD: Int32, pollInterval: Duration) {
        self.stdinFD = stdinFD
        // Duration → milliseconds, clamped to Int32 and ≥ 1ms.
        let comps = pollInterval.components
        let millis = comps.seconds * 1000 + comps.attoseconds / 1_000_000_000_000_000
        self.pollTimeoutMS = Int32(clamping: max(millis, 1))
        PollEventSource.installSignalSelfPipe()
    }

    public func nextEvent() -> TUIEvent? {
        var fds = [pollfd]()
        fds.append(pollfd(fd: stdinFD, events: Int16(POLLIN), revents: 0))
        let sigReadFD = PollEventSource.signalPipeReadFD
        if sigReadFD >= 0 {
            fds.append(pollfd(fd: sigReadFD, events: Int16(POLLIN), revents: 0))
        }

        let rc = poll(&fds, nfds_t(fds.count), pollTimeoutMS)
        if rc == 0 {
            return .tick // timeout — poll-interval elapsed
        }
        if rc < 0 {
            if errno == EINTR { return .tick } // interrupted — re-render
            return nil
        }

        // Signal pipe first (preempts a pending key per the spec: an
        // arriving signal preempts the next tick).
        if fds.count > 1, (fds[1].revents & Int16(POLLIN)) != 0 {
            var tag: UInt8 = 0
            _ = read(sigReadFD, &tag, 1)
            switch tag {
            case PollEventSource.tagWinch: return .resize
            default: return .signal
            }
        }

        if (fds[0].revents & Int16(POLLIN)) != 0 {
            var byte: UInt8 = 0
            let n = read(stdinFD, &byte, 1)
            if n == 0 { return .eof }
            if n < 0 { return nil }
            return .key(byte)
        }
        // Hangup / error on stdin → treat as EOF.
        if (fds[0].revents & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0 {
            return .eof
        }
        return .tick
    }

    // MARK: - Signal self-pipe (async-signal-safe)

    static let tagWinch: UInt8 = 1
    static let tagTerm: UInt8 = 2
    nonisolated(unsafe) static var signalPipeReadFD: Int32 = -1
    nonisolated(unsafe) static var signalPipeWriteFD: Int32 = -1
    private static let installLock = NSLock()
    nonisolated(unsafe) private static var installed = false

    static func installSignalSelfPipe() {
        installLock.lock(); defer { installLock.unlock() }
        guard !installed else { return }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return }
        signalPipeReadFD = fds[0]
        signalPipeWriteFD = fds[1]
        // Non-blocking write end so the handler never stalls.
        let flags = fcntl(signalPipeWriteFD, F_GETFL, 0)
        _ = fcntl(signalPipeWriteFD, F_SETFL, flags | O_NONBLOCK)

        signal(SIGWINCH, pollSignalHandler)
        // NOTE: SIGINT/SIGTERM termios restoration is owned by
        // Termios.withRawMode's own handler chain. Here we additionally
        // wake the loop so it can flush + exit 0 cleanly under poll.
        signal(SIGINT, pollSignalHandler)
        signal(SIGTERM, pollSignalHandler)
        installed = true
    }
}

/// C-ABI handler: a single non-blocking 1-byte write. Async-signal-safe.
private let pollSignalHandler: @convention(c) (Int32) -> Void = { signo in
    var tag: UInt8 = (signo == SIGWINCH) ? PollEventSource.tagWinch : PollEventSource.tagTerm
    let fd = PollEventSource.signalPipeWriteFD
    if fd >= 0 {
        _ = write(fd, &tag, 1)
    }
}
#endif
