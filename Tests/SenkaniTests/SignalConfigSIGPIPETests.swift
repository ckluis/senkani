import Testing
import Foundation
#if canImport(Darwin)
import Darwin.POSIX
#endif
@testable import Core

/// Regression coverage for the traceless-GUI-exit fix
/// (`t6-banner-walk-app-exits-traceless-on-claude-pane-prompt-2026-06-22`).
///
/// Root cause: the GUI process did raw `Darwin.write` on hook/pane
/// Unix-domain sockets with the DEFAULT `SIGPIPE` disposition. When a
/// short-lived peer (the 5 ms hook-relay client) closed before
/// `HookRouter.handle` returned, that write delivered SIGPIPE and killed
/// the process with no `.ips`/stderr/jetsam/log. `SignalConfig.ignoreSIGPIPE()`
/// (called at startup in `SenkaniApp/App/main.swift`) flips the disposition
/// to `SIG_IGN` so the write fails with `EPIPE` instead.
@Suite("SignalConfig — SIGPIPE ignore (traceless-exit regression)")
struct SignalConfigSIGPIPETests {

    /// The load-bearing invariant: after `ignoreSIGPIPE()`, writing to a
    /// socket whose peer has closed returns `-1`/`EPIPE` INSTEAD of killing
    /// the process. If the fix regresses (the `signal(SIGPIPE, SIG_IGN)`
    /// call is removed), this write delivers SIGPIPE and the entire test
    /// process dies — the chunk crashes, which is itself the alarm. Merely
    /// reaching the assertions below proves the process survived the write.
    @Test func writeToClosedPeerReturnsEPIPENotSignal() {
        SignalConfig.ignoreSIGPIPE()

        var fds: [Int32] = [0, 0]
        let rc = fds.withUnsafeMutableBufferPointer { buf in
            Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
        }
        #expect(rc == 0, "socketpair must succeed to set up the test")
        let writeEnd = fds[0]
        let peerEnd = fds[1]
        defer { Darwin.close(writeEnd) }

        // Close the peer entirely — a subsequent write to `writeEnd` has no
        // reader, the SIGPIPE-or-EPIPE condition.
        Darwin.close(peerEnd)

        // Write up to a few times: on a stream socket the very first write
        // after peer-close normally returns EPIPE, but loop as cheap
        // insurance against a buffer-then-reset variant. Each iteration that
        // does NOT crash the process is itself the proof we care about.
        var lastN = 0
        var lastErrno: Int32 = 0
        for _ in 0..<4 {
            var byte: UInt8 = 0x42
            errno = 0
            lastN = Darwin.write(writeEnd, &byte, 1)
            lastErrno = errno
            if lastN == -1 { break }
        }

        #expect(lastN == -1, "write to a closed-peer socket must fail, not succeed")
        #expect(lastErrno == EPIPE, "the failure must surface as EPIPE (got errno=\(lastErrno))")
    }

    /// Idempotent: startup may install the ignore more than once across the
    /// host-mode branch dispatch / test ordering. Reaching the end without a
    /// crash is the assertion.
    @Test func ignoreIsIdempotent() {
        SignalConfig.ignoreSIGPIPE()
        SignalConfig.ignoreSIGPIPE()
        #expect(Bool(true))
    }
}
