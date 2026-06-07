import Foundation

/// Read-only git probes used by the remove-confirmation dialogs to
/// surface "branch has unpushed commits" warnings *before* the operator
/// confirms destruction. Mutating worktree/branch ops live in
/// `GitWorktreeManager`; this enum exists so the dialog layer can ask
/// "is this safe to drop?" without depending on the heavier manager
/// API and without re-running `git worktree add`-shaped commands.
enum WorktreeGitInspector {

    /// Result of probing whether a branch has commits not on its
    /// upstream remote. `.none` means the branch is fully pushed (or
    /// has no remote-tracking branch and no commits, which is
    /// equivalent for the dialog's purpose).
    enum UnpushedStatus: Equatable {
        case none
        case unpushed(count: Int)
        case noUpstream      // branch has no remote-tracking ref; surface as warning
        case branchMissing   // branch ref does not exist on disk
    }

    /// Probe the given branch for unpushed commits relative to its
    /// upstream tracking ref. Uses `git rev-list --count <branch>
    /// ^<branch>@{upstream}`; falls back to `.noUpstream` if no
    /// upstream is configured.
    static func unpushedCommits(repoPath: String, branch: String) -> UnpushedStatus {
        // Verify the branch exists first; otherwise rev-list complains.
        let (_, refExit) = runGit(args: ["-C", repoPath, "rev-parse", "--verify", "refs/heads/\(branch)"])
        if refExit != 0 {
            return .branchMissing
        }

        // Check upstream configured.
        let (_, upExit) = runGit(args: ["-C", repoPath, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "\(branch)@{upstream}"])
        if upExit != 0 {
            return .noUpstream
        }

        // Count commits on branch not on upstream.
        let (out, exit) = runGit(args: ["-C", repoPath, "rev-list", "--count", "\(branch)", "^\(branch)@{upstream}"])
        guard exit == 0, let n = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .noUpstream
        }
        return n > 0 ? .unpushed(count: n) : .none
    }

    /// Delete a local branch via `git branch -D` (force). Returns nil
    /// on success, stderr on failure. The dialog already gates this
    /// behind the operator's tiered-checkbox opt-in and the unpushed-
    /// commits warning, so the destructive `-D` form is what the
    /// operator asked for; we do NOT silently downgrade to `-d`.
    @discardableResult
    static func deleteBranch(repoPath: String, branch: String) -> String? {
        let (err, exit) = runGit(args: ["-C", repoPath, "branch", "-D", branch])
        return exit == 0 ? nil : err
    }

    /// Pre-existence probe used by `WorkspaceModel.removeProject` /
    /// `removeWorkstream` to make partial-success retry idempotent:
    /// if a prior call's branch-delete step succeeded and a later
    /// step failed, the force-retry call re-runs the branch step
    /// against a now-gone branch and `git branch -D` returns non-zero
    /// — surfacing a spurious failure for an already-cleaned artifact.
    /// Callers should treat `branchExists == false` as a no-op success
    /// rather than calling `deleteBranch`. Mirror of the `rev-parse
    /// --verify` shape `unpushedCommits` already uses for `.branchMissing`.
    static func branchExists(repoPath: String, branch: String) -> Bool {
        let (_, exit) = runGit(args: ["-C", repoPath, "rev-parse", "--verify", "refs/heads/\(branch)"])
        return exit == 0
    }

    // MARK: - Private

    private static func runGit(args: [String]) -> (String, Int32) {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (error.localizedDescription, -1)
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus == 0 ? out : err, process.terminationStatus)
    }
}
