import Darwin
import Foundation

/// Process-wide RLIMIT_NOFILE soft-limit management.
///
/// macOS GUI apps (and any process launched via `open` / LaunchServices)
/// inherit launchd's default soft limit of 256 open files. A medium-sized
/// indexing pass — recursive file walks, per-file `attributesOfItem` /
/// xattr queries, transient subprocess pipes — can exhaust 256 quickly,
/// triggering EMFILE on the next system asset load. Observed crash
/// (2026-05-15): `default.metallib failed to open with error: Too many
/// open files` during pane launch after warm-index. See
/// `spec/autonomous/completed/2026/2026-05-15-senkani-app-emfile-crash-during-pane-launch.md`
/// for the closing item.
///
/// Call `raiseFileDescriptorLimit()` once at process startup — before any
/// subsystem (MCPServer, SwiftUI, hooks) gets a chance to open fds.
public enum FileDescriptorLimit {

    /// Default target soft limit. macOS hard limit is typically 10240
    /// (sysctl kern.maxfilesperproc); we cap requested at the hard limit
    /// to ensure setrlimit succeeds.
    public static let defaultTarget: rlim_t = 10240

    /// Raise the process's RLIMIT_NOFILE soft limit toward `target`,
    /// clamping at the current hard limit so setrlimit never fails on
    /// permission grounds.
    ///
    /// - Returns: `(before, after, hard)` — the soft-limit values
    ///   observed before and after the raise, and the hard cap.
    @discardableResult
    public static func raise(target: rlim_t = defaultTarget) -> (before: rlim_t, after: rlim_t, hard: rlim_t) {
        var current = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &current) == 0 else {
            return (before: 0, after: 0, hard: 0)
        }
        let hard = current.rlim_max
        let desired = min(target, hard)
        if current.rlim_cur >= desired {
            return (before: current.rlim_cur, after: current.rlim_cur, hard: hard)
        }
        var raised = current
        raised.rlim_cur = desired
        _ = setrlimit(RLIMIT_NOFILE, &raised)
        var verified = rlimit()
        _ = getrlimit(RLIMIT_NOFILE, &verified)
        return (before: current.rlim_cur, after: verified.rlim_cur, hard: hard)
    }
}

/// Top-level convenience: raise RLIMIT_NOFILE to a sensible default.
/// Safe to call multiple times; no-ops if soft is already high enough.
@discardableResult
public func raiseFileDescriptorLimit() -> (before: rlim_t, after: rlim_t, hard: rlim_t) {
    FileDescriptorLimit.raise()
}
