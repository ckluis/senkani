import Darwin
import Foundation
import Testing
@testable import Core

/// Pairs with `senkani-app-emfile-crash-during-pane-launch-2026-05-15`.
/// Asserts that `raiseFileDescriptorLimit()` raises the process's
/// RLIMIT_NOFILE soft cap up to the hard cap, so that recursive index
/// passes don't exhaust the default 256 soft cap that GUI apps inherit
/// from launchd.
@Suite("FileDescriptorLimit")
struct FileDescriptorLimitTests {

    @Test("raise() lifts soft limit to at least 4096 when hard limit permits")
    func raiseLiftsSoft() {
        var probe = rlimit()
        #expect(getrlimit(RLIMIT_NOFILE, &probe) == 0)
        let hard = probe.rlim_max
        let result = FileDescriptorLimit.raise(target: 10240)
        // Whatever the hard cap is, the resulting soft must equal
        // min(target, hard) — i.e. setrlimit succeeded.
        let expected = min(rlim_t(10240), hard)
        #expect(result.after >= expected)
        #expect(result.hard == hard)
        // Verify the post-state with a fresh getrlimit, in case the
        // call mutated process-wide state.
        var verify = rlimit()
        #expect(getrlimit(RLIMIT_NOFILE, &verify) == 0)
        #expect(verify.rlim_cur >= expected)
    }

    @Test("raise() is idempotent — second call no-ops when already at target")
    func raiseIdempotent() {
        let first = FileDescriptorLimit.raise(target: 10240)
        let second = FileDescriptorLimit.raise(target: 10240)
        #expect(second.before == second.after)
        #expect(second.after >= first.after)
    }

    @Test("raise() clamps target above hard cap to hard cap")
    func raiseClampsToHard() {
        let result = FileDescriptorLimit.raise(target: .max)
        #expect(result.after <= result.hard)
    }
}
