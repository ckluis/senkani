import Foundation

/// V.3 — the REAL pane-metadata probe implementations that produce the three
/// injected closures the V.3a `PaneMetadataResolver` exposes
/// (`portProbe` / `branchProbe` / `prProbe`). Each probe shells a known tool
/// through the argv `ProcessRunning` seam (so untrusted branch/dir strings
/// never touch a shell) and SILENTLY DEGRADES to `nil` on any failure — a
/// missing tool, a non-zero exit, an unparseable payload. A probe NEVER
/// throws and NEVER logs above `info`: a sidebar chip is best-effort, so a
/// degraded probe just means "no chip", never a crash or a noisy log.
///
/// A `final class` (not a struct) because the PR probe holds a lock-guarded
/// TTL cache: gh is the expensive/rate-limited tool, so a 60s per-branch
/// cache keeps hover-driven re-probes off the network.
///
/// The GUI round constructs one of these with the real `SystemProcessRunner`
/// and binds `probes.portProbe` / `.branchProbe` / `.prProbe` into the
/// resolver; tests construct it with a `MockProcessRunner` + a fixed clock.
public final class PaneMetadataProbes: @unchecked Sendable {

    private let runner: ProcessRunning
    private let now: () -> Date
    private let prTTL: TimeInterval

    /// Lock-guarded PR TTL cache, keyed by branch name. Stores the LAST
    /// resolved ref (including a `nil` ref — "we checked, no PR") plus the
    /// wall-time we resolved it, so a hit within `prTTL` skips gh entirely.
    private let prLock = NSLock()
    private var prCache: [String: (ref: PaneMetadata.PRRef?, at: Date)] = [:]

    public init(
        runner: ProcessRunning = SystemProcessRunner(),
        now: @escaping () -> Date = { Date() },
        prTTL: TimeInterval = 60
    ) {
        self.runner = runner
        self.now = now
        self.prTTL = prTTL
    }

    // MARK: - Port probe (lsof)

    /// `portProbe` — input is the pane shell's PGID (as a String). Runs
    /// `/usr/sbin/lsof -i -P -n -sTCP:LISTEN` and returns the LOWEST TCP
    /// listening port owned by a process whose PID column equals the probe
    /// key, or `nil` if none. lsof exits `1` when there are no listeners at
    /// all — treated as "no port", not an error.
    public var portProbe: (String) -> Int? {
        { [weak self] probeKey in
            self?.resolvePort(pgid: probeKey)
        }
    }

    private func resolvePort(pgid: String) -> Int? {
        let result = runner.run(
            executable: "/usr/sbin/lsof",
            args: ["-i", "-P", "-n", "-sTCP:LISTEN"]
        )
        // lsof exits non-zero (1) when there are simply no listeners. That is
        // not an error for us — there is just no port. Any non-zero exit ⇒ nil.
        guard result.exitCode == 0 else { return nil }

        var lowest: Int? = nil
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            // lsof default columns:
            //   COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
            // PID is field index 1; NAME (the address) is the LAST field.
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2 else { continue }

            let pidField = String(fields[1])
            // Header tolerance: the header row's PID column is the literal
            // "PID", not an Int — skip any row whose PID field isn't an Int.
            guard Int(pidField) != nil else { continue }
            guard pidField == pgid else { continue }

            // NAME is the address column, e.g. "*:8080", "127.0.0.1:3000",
            // "[::1]:5173" — and with `-sTCP:LISTEN` lsof appends a trailing
            // " (LISTEN)" annotation, so a naive "last field" grabs "(LISTEN)".
            // Scan the columns from the NAME column onward (index 8 in the
            // default 9-column layout) and take the first token that yields a
            // valid port after its FINAL ":" (drops the "(LISTEN)" suffix and
            // is robust to the IPv6 "[::1]:5173" form, whose final colon
            // precedes the port). Guard the start index in case a row is
            // shorter than the default layout.
            let nameStart = min(8, fields.count - 1)
            var rowPort: Int? = nil
            for token in fields[nameStart...] {
                guard let colon = token.lastIndex(of: ":") else { continue }
                let after = token[token.index(after: colon)...]
                let portToken = after.prefix(while: { $0.isNumber })
                if let port = Int(portToken) {
                    rowPort = port
                    break
                }
            }
            guard let port = rowPort else { continue }

            if lowest == nil || port < lowest! {
                lowest = port
            }
        }
        return lowest
    }

    // MARK: - Branch probe (git)

    /// `branchProbe` — input is the pane working directory. Runs
    /// `/usr/bin/git -C <wd> rev-parse --abbrev-ref HEAD` and returns the
    /// trimmed branch on exit 0 (nil if blank), nil on any non-zero exit
    /// (not a repo, git missing, detached-HEAD edge, …).
    public var branchProbe: (String) -> String? {
        { [weak self] probeKey in
            self?.resolveBranch(workingDir: probeKey)
        }
    }

    private func resolveBranch(workingDir: String) -> String? {
        let result = runner.run(
            executable: "/usr/bin/git",
            args: ["-C", workingDir, "rev-parse", "--abbrev-ref", "HEAD"]
        )
        guard result.exitCode == 0 else { return nil }
        let branch = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? nil : branch
    }

    // MARK: - PR probe (gh, which-degrade + TTL cache)

    /// `prProbe` — input is the branch name. Resolves an open PR for that
    /// branch via `gh pr list`, behind a `which gh` degrade and a 60s
    /// per-branch TTL cache. EVERY failure mode degrades silently to nil:
    ///   - gh not installed (`which gh` non-zero / blank stdout) ⇒ nil,
    ///     and gh is NEVER invoked.
    ///   - non-zero `gh` exit (unauth / rate-limited) ⇒ nil.
    ///   - JSON decode failure (garbage stdout) ⇒ nil.
    ///   - empty PR array ⇒ nil.
    /// The resolved result (INCLUDING a nil ref) is cached with the current
    /// timestamp; a second call for the same branch within `prTTL` returns the
    /// cached value WITHOUT invoking gh.
    public var prProbe: (String) -> PaneMetadata.PRRef? {
        { [weak self] branch in
            self?.resolvePR(branch: branch) ?? nil
        }
    }

    private func resolvePR(branch: String) -> PaneMetadata.PRRef? {
        // (b) TTL cache hit — return without touching gh.
        prLock.lock()
        if let cached = prCache[branch], now().timeIntervalSince(cached.at) < prTTL {
            prLock.unlock()
            return cached.ref
        }
        prLock.unlock()

        // (a) Resolve gh — silent degrade if not installed. Done OUTSIDE the
        // lock (a subprocess call must not hold the cache lock).
        let which = runner.run(executable: "/usr/bin/which", args: ["gh"])
        let ghPath = which.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard which.exitCode == 0, !ghPath.isEmpty else {
            // gh not installed — degrade silently. (Intentionally NOT cached:
            // do not pin a "no gh" verdict for a tool that may get installed.)
            return nil
        }

        // (c) Cache miss — ask gh for one open PR on this branch.
        let result = runner.run(
            executable: ghPath,
            args: ["pr", "list", "--head", branch, "--json", "number,url", "--limit", "1"]
        )

        let ref: PaneMetadata.PRRef?
        if result.exitCode == 0,
           let data = result.stdout.data(using: .utf8),
           let rows = try? JSONDecoder().decode([GHPRRow].self, from: data),
           let first = rows.first {
            ref = PaneMetadata.PRRef(number: first.number, url: first.url)
        } else {
            // Non-zero exit (unauth/rate-limited) OR decode failure OR empty
            // array ⇒ nil. Total silent degrade.
            ref = nil
        }

        prLock.lock()
        prCache[branch] = (ref: ref, at: now())
        prLock.unlock()
        return ref
    }

    /// One row of `gh pr list --json number,url` output.
    private struct GHPRRow: Decodable {
        let number: Int
        let url: String
    }
}
