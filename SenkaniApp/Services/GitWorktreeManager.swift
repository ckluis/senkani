import Foundation

/// Manages git worktree lifecycle for workstream isolation.
/// All commands use `/usr/bin/git` absolute path with array arguments — no shell interpolation.
enum GitWorktreeManager {

    struct WorktreeInfo {
        let path: String
        let branch: String
    }

    enum GitError: Error, LocalizedError {
        case notGitRepo
        case branchExists(String)
        case worktreeCreateFailed(String)
        case worktreeRemoveFailed(String)
        case directoryCreateFailed(String)

        var errorDescription: String? {
            switch self {
            case .notGitRepo: return "This project is not a git repository"
            case .branchExists(let branch): return "Branch '\(branch)' already exists"
            case .worktreeCreateFailed(let msg): return "Failed to create worktree: \(msg)"
            case .worktreeRemoveFailed(let msg): return "Failed to remove worktree: \(msg)"
            case .directoryCreateFailed(let msg): return "Failed to create directory: \(msg)"
            }
        }
    }

    // MARK: - Public API

    /// Check if a directory is inside a git repository.
    static func isGitRepo(path: String) -> Bool {
        let (_, exitCode) = runGit(args: ["-C", path, "rev-parse", "--is-inside-work-tree"])
        return exitCode == 0
    }

    /// Create a git worktree at `.worktrees/<slug>` with a new branch.
    /// Returns the absolute path to the created worktree directory.
    static func createWorktree(projectRoot: String, slug: String, branch: String? = nil) -> Result<String, GitError> {
        guard isGitRepo(path: projectRoot) else {
            return .failure(.notGitRepo)
        }

        // Create .worktrees directory
        let worktreesDir = projectRoot + "/.worktrees"
        let fm = FileManager.default
        if !fm.fileExists(atPath: worktreesDir) {
            do {
                try fm.createDirectory(atPath: worktreesDir, withIntermediateDirectories: true)
            } catch {
                return .failure(.directoryCreateFailed(error.localizedDescription))
            }
        }

        let worktreePath = worktreesDir + "/" + slug

        // Auto-generate branch name if not provided
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        let dateSlug = fmt.string(from: Date())
        let branchName = branch ?? "feature/\(dateSlug)-\(slug)"

        // Create the worktree with a new branch
        let (stderr, exitCode) = runGit(args: [
            "-C", projectRoot,
            "worktree", "add",
            worktreePath,
            "-b", branchName
        ])

        if exitCode != 0 {
            if stderr.contains("already exists") {
                return .failure(.branchExists(branchName))
            }
            return .failure(.worktreeCreateFailed(stderr))
        }

        return .success(worktreePath)
    }

    /// Remove a git worktree.
    static func removeWorktree(path: String, force: Bool = false) -> Result<Void, GitError> {
        var args = ["worktree", "remove", path]
        if force { args.append("--force") }

        let (stderr, exitCode) = runGit(args: args)
        if exitCode != 0 {
            return .failure(.worktreeRemoveFailed(stderr))
        }
        return .success(())
    }

    /// Slugify a name for use as a directory and branch component.
    /// Lowercase, replace non-alphanumeric with hyphens, collapse multiples, trim edges.
    static func slugify(_ name: String) -> String {
        var slug = name.lowercased()
        slug = slug.map { $0.isLetter || $0.isNumber ? $0 : Character("-") }
            .reduce("") { $0 + String($1) }
        // Collapse multiple hyphens
        while slug.contains("--") {
            slug = slug.replacingOccurrences(of: "--", with: "-")
        }
        // Trim leading/trailing hyphens
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "workstream" : String(slug.prefix(50))
    }

    // MARK: - Private

    /// Run a git command and return (stderr output, exit code).
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

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (stderr, process.terminationStatus)
    }
}
