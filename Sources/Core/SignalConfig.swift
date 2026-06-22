import Darwin
import Foundation

/// Process-wide POSIX signal disposition management.
///
/// macOS delivers `SIGPIPE` to a process that `write(2)`s to a socket or
/// pipe whose read end has already closed. The DEFAULT disposition
/// (`SIG_DFL`) TERMINATES the process — and a SIGPIPE kill is **traceless**:
/// it produces no crash report (`.ips`), no stderr, no kernel
/// jetsam/memorystatus entry, and no unified-log line. A process that does
/// raw `Darwin.write` on Unix-domain sockets (see
/// ``SocketServerManager``'s hook + pane listeners) can therefore vanish
/// the instant a short-lived peer disconnects mid-response.
///
/// Observed defect (2026-06-22): the SenkaniApp GUI terminated cleanly,
/// with zero diagnostics, ~seconds after a Claude-pane prompt submit. The
/// hook-relay child (`HookRelay.run`) waits only **5 ms** for a response,
/// then its `defer { Darwin.close(fd) }` closes the socket;
/// `HookRouter.handle` frequently runs longer than that (a SQLite
/// `recordHookEvent` write, the credential-vault bridge with a 5-second
/// `DispatchSemaphore` ceiling, AutoValidate enqueue, pack-policy stat), so
/// the server's `Darwin.write(clientFD, …)` lands on a peer that already
/// gave up → SIGPIPE → the whole GUI process is killed. The 5 ms-vs-handle
/// race explains the observed timing variance (survived a ~100-event
/// session once, died in ~2 s another). See
/// `spec/autonomous/backlog/t6-banner-walk-app-exits-traceless-on-claude-pane-prompt-2026-06-22.md`.
///
/// The fix every networked process needs: ignore SIGPIPE process-wide so
/// the offending `write(2)` returns `-1`/`EPIPE` instead of killing the
/// process. Every raw-socket writer in this codebase already discards the
/// write result (`_ = Darwin.write(...)`), so a dropped response to a peer
/// that has already disconnected is the correct, harmless outcome.
///
/// Call ``ignoreSIGPIPE()`` once at process startup — before any subsystem
/// (MCPServer, the socket listeners, hooks) can write to a socket. Cheap,
/// idempotent, and thread-safe (a single `signal(2)` call).
public enum SignalConfig {

    /// Set `SIGPIPE`'s disposition to `SIG_IGN` for the whole process so a
    /// `write(2)` to a closed socket/pipe peer fails with `EPIPE` rather
    /// than delivering the default process-terminating signal.
    ///
    /// Idempotent: safe to call repeatedly (re-installs the same handler).
    public static func ignoreSIGPIPE() {
        signal(SIGPIPE, SIG_IGN)
    }
}

/// Top-level convenience: ignore `SIGPIPE` process-wide so a `write(2)` to a
/// closed socket/pipe peer fails with `EPIPE` instead of terminating the
/// process traceless. Call once at process startup, before any socket
/// listener binds. Mirrors ``raiseFileDescriptorLimit()``. See
/// ``SignalConfig``.
public func ignoreBrokenPipeSignal() {
    SignalConfig.ignoreSIGPIPE()
}
