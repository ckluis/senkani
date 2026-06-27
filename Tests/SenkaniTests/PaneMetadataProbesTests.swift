import Testing
import Foundation
@testable import Core

/// V.3 — the REAL pane-metadata probes (`PaneMetadataProbes`) over the argv
/// `ProcessRunning` seam. Acceptance:
///   - branch: exact argv to `/usr/bin/git`; trim on exit 0; nil on non-zero
///     or blank stdout.
///   - port: lsof multi-row PGID filter; lowest port on multi-port; address
///     format tolerance; header-row tolerance; nil on non-zero exit / no match.
///   - PR: which-gh silent degrade (gh NEVER invoked); JSON decode → PRRef;
///     empty array / non-zero gh exit / garbage → nil; 60s per-branch TTL
///     (one gh call within the window, re-probe after the clock advances).
///   - end-to-end: probes feeding a real `PaneMetadataResolver`'s seams.
@Suite("V.3 — PaneMetadataProbes (lsof / git / gh)")
struct PaneMetadataProbesTests {

    /// Test double for `ProcessRunning`: returns a canned `ProcessRunResult`
    /// keyed by `executable + " " + args.joined(separator: " ")`, and records
    /// every `(executable, args)` invocation in order so tests can assert the
    /// exact argv each probe constructs. NSLock-guarded (mirrors
    /// `MockCommandRunner`).
    final class MockProcessRunner: ProcessRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(executable: String, args: [String])] = []
        private let canned: [String: ProcessRunResult]
        private let defaultResult: ProcessRunResult

        init(
            canned: [String: ProcessRunResult] = [:],
            defaultResult: ProcessRunResult = ProcessRunResult(stdout: "", exitCode: 0)
        ) {
            self.canned = canned
            self.defaultResult = defaultResult
        }

        static func key(_ executable: String, _ args: [String]) -> String {
            ([executable] + args).joined(separator: " ")
        }

        var calls: [(executable: String, args: [String])] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }

        func run(executable: String, args: [String]) -> ProcessRunResult {
            lock.lock()
            _calls.append((executable, args))
            lock.unlock()
            return canned[MockProcessRunner.key(executable, args)] ?? defaultResult
        }
    }

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Branch (git rev-parse)

    @Test("branch: exact argv + trimmed stdout on exit 0")
    func branchHappyPath() {
        let wd = "/Users/dev/proj"
        let key = MockProcessRunner.key(
            "/usr/bin/git", ["-C", wd, "rev-parse", "--abbrev-ref", "HEAD"]
        )
        let runner = MockProcessRunner(
            canned: [key: ProcessRunResult(stdout: "feature/x\n", exitCode: 0)]
        )
        let probes = PaneMetadataProbes(runner: runner, now: { self.fixedDate })

        #expect(probes.branchProbe(wd) == "feature/x")

        // Assert the EXACT argv the branch probe constructs.
        #expect(runner.calls.count == 1)
        #expect(runner.calls[0].executable == "/usr/bin/git")
        #expect(runner.calls[0].args == ["-C", wd, "rev-parse", "--abbrev-ref", "HEAD"])
    }

    @Test("branch: non-zero exit → nil")
    func branchNonZeroNil() {
        let wd = "/not/a/repo"
        let key = MockProcessRunner.key(
            "/usr/bin/git", ["-C", wd, "rev-parse", "--abbrev-ref", "HEAD"]
        )
        let runner = MockProcessRunner(
            canned: [key: ProcessRunResult(stdout: "fatal: not a git repository", exitCode: 128)]
        )
        let probes = PaneMetadataProbes(runner: runner, now: { self.fixedDate })
        #expect(probes.branchProbe(wd) == nil)
    }

    @Test("branch: detached HEAD ('HEAD') → nil, not a meaningless chip")
    func branchDetachedHeadNil() {
        let wd = "/detached"
        let key = MockProcessRunner.key(
            "/usr/bin/git", ["-C", wd, "rev-parse", "--abbrev-ref", "HEAD"]
        )
        let runner = MockProcessRunner(
            canned: [key: ProcessRunResult(stdout: "HEAD\n", exitCode: 0)]
        )
        let probes = PaneMetadataProbes(runner: runner, now: { self.fixedDate })
        #expect(probes.branchProbe(wd) == nil)
    }

    @Test("branch: empty / whitespace stdout → nil")
    func branchBlankNil() {
        let wd = "/empty"
        let key = MockProcessRunner.key(
            "/usr/bin/git", ["-C", wd, "rev-parse", "--abbrev-ref", "HEAD"]
        )
        let runner = MockProcessRunner(
            canned: [key: ProcessRunResult(stdout: "   \n", exitCode: 0)]
        )
        let probes = PaneMetadataProbes(runner: runner, now: { self.fixedDate })
        #expect(probes.branchProbe(wd) == nil)
    }

    // MARK: - Port (lsof)

    private func lsofRunner(stdout: String, exitCode: Int32 = 0) -> MockProcessRunner {
        let key = MockProcessRunner.key(
            "/usr/sbin/lsof", ["-i", "-P", "-n", "-sTCP:LISTEN"]
        )
        return MockProcessRunner(canned: [key: ProcessRunResult(stdout: stdout, exitCode: exitCode)])
    }

    @Test("port: mixed PIDs + address formats → only matching-PGID row's port")
    func portMatchingPgidOnly() {
        // Header + three rows: PID 4242 (target) on *:8080, PID 9999 on
        // 127.0.0.1:3000, PID 4242 (target) on [::1]:5173 — but we test the
        // single-port case here by giving the target exactly one row.
        let fixture = """
        COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        node     4242 dev    23u  IPv4 0x0          0t0  TCP *:8080 (LISTEN)
        ruby     9999 dev    11u  IPv4 0x1          0t0  TCP 127.0.0.1:3000 (LISTEN)
        """
        let runner = lsofRunner(stdout: fixture)
        let probes = PaneMetadataProbes(runner: runner, now: { self.fixedDate })

        #expect(probes.portProbe("4242") == 8080)
        // Exact argv assertion for the port probe.
        #expect(runner.calls.count == 1)
        #expect(runner.calls[0].executable == "/usr/sbin/lsof")
        #expect(runner.calls[0].args == ["-i", "-P", "-n", "-sTCP:LISTEN"])
    }

    @Test("port: a PGID with two ports → the LOWEST")
    func portLowestOfTwo() {
        // The HIGHER port (8080) is listed FIRST so the test discriminates
        // "lowest" from "first-seen": a first-seen-wins bug returns 8080 here
        // and is killed by the `== 5173` assertion.
        let fixture = """
        COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        vite     4242 dev    21u  IPv4 0x1  0t0  TCP *:8080 (LISTEN)
        vite     4242 dev    20u  IPv6 0x0  0t0  TCP [::1]:5173 (LISTEN)
        """
        let runner = lsofRunner(stdout: fixture)
        let probes = PaneMetadataProbes(runner: runner, now: { self.fixedDate })
        #expect(probes.portProbe("4242") == 5173)
    }

    @Test("port: a bare bracketed address with no port ([::1]) is not parsed as bogus port 1")
    func portBareBracketNoPortIgnored() {
        // A NAME of bare "[::1]" (no :port) must be SKIPPED, not misread as port
        // 1 — which, being lower than any real port, would be wrongly selected
        // as the LOWEST. The same PGID also owns a real *:8080, which must win.
        let fixture = """
        COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        weird    4242 dev    19u  IPv6 0x0  0t0  TCP [::1] (LISTEN)
        node     4242 dev    23u  IPv4 0x1  0t0  TCP *:8080 (LISTEN)
        """
        let runner = lsofRunner(stdout: fixture)
        let probes = PaneMetadataProbes(runner: runner, now: { self.fixedDate })
        #expect(probes.portProbe("4242") == 8080)
    }

    @Test("port: no matching PID → nil")
    func portNoMatchNil() {
        let fixture = """
        COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        node     1111 dev    23u  IPv4 0x0  0t0  TCP *:8080 (LISTEN)
        """
        let runner = lsofRunner(stdout: fixture)
        let probes = PaneMetadataProbes(runner: runner, now: { self.fixedDate })
        #expect(probes.portProbe("4242") == nil)
    }

    @Test("port: non-zero exit (no listeners) → nil")
    func portNonZeroNil() {
        let runner = lsofRunner(stdout: "", exitCode: 1)
        let probes = PaneMetadataProbes(runner: runner, now: { self.fixedDate })
        #expect(probes.portProbe("4242") == nil)
    }

    @Test("port: header-row tolerance — header alone yields nil, never a parse crash")
    func portHeaderToleranceNil() {
        // Only the header row (no data). The header's PID column is "PID",
        // not an Int, so it is skipped — and there is no matching data row.
        let runner = lsofRunner(stdout: "COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME\n")
        let probes = PaneMetadataProbes(runner: runner, now: { self.fixedDate })
        #expect(probes.portProbe("PID") == nil)
    }

    // MARK: - PR (gh, which-degrade + TTL)

    private static let whichGhKey = MockProcessRunner.key("/usr/bin/which", ["gh"])
    private static let ghPath = "/opt/homebrew/bin/gh"

    private static func ghListKey(branch: String) -> String {
        MockProcessRunner.key(
            ghPath, ["pr", "list", "--head", branch, "--json", "number,url", "--limit", "1"]
        )
    }

    @Test("pr: which-gh missing → nil AND gh is NEVER invoked")
    func prWhichMissingNeverCallsGh() {
        let runner = MockProcessRunner(
            canned: [Self.whichGhKey: ProcessRunResult(stdout: "", exitCode: 1)]
        )
        let probes = PaneMetadataProbes(runner: runner, now: { self.fixedDate })

        #expect(probes.prProbe("feature/x") == nil)
        // Only the `which gh` probe ran; gh itself was never invoked.
        #expect(runner.calls.count == 1)
        #expect(runner.calls[0].executable == "/usr/bin/which")
        #expect(!runner.calls.contains(where: { $0.executable == Self.ghPath }))
    }

    @Test("pr: gh JSON array → PRRef(number, url)")
    func prHappyPath() {
        let branch = "feature/x"
        let runner = MockProcessRunner(canned: [
            Self.whichGhKey: ProcessRunResult(stdout: Self.ghPath + "\n", exitCode: 0),
            Self.ghListKey(branch: branch): ProcessRunResult(
                stdout: #"[{"number":42,"url":"https://github.com/o/r/pull/42"}]"#,
                exitCode: 0
            ),
        ])
        let probes = PaneMetadataProbes(runner: runner, now: { self.fixedDate })

        let ref = probes.prProbe(branch)
        #expect(ref?.number == 42)
        #expect(ref?.url == "https://github.com/o/r/pull/42")
        // gh was invoked with the trimmed `which` path + exact argv.
        let ghCall = runner.calls.first(where: { $0.executable == Self.ghPath })
        #expect(ghCall != nil)
        #expect(ghCall?.args == ["pr", "list", "--head", branch, "--json", "number,url", "--limit", "1"])
    }

    @Test("pr: multi-element array → the FIRST PR is returned")
    func prFirstOfMultiple() {
        // gh --limit 1 returns at most one, but the parse takes `.first`
        // defensively; assert it is the FIRST element, not the second.
        let branch = "feature/multi"
        let runner = MockProcessRunner(canned: [
            Self.whichGhKey: ProcessRunResult(stdout: Self.ghPath, exitCode: 0),
            Self.ghListKey(branch: branch): ProcessRunResult(
                stdout: #"[{"number":11,"url":"https://x/pull/11"},{"number":22,"url":"https://x/pull/22"}]"#,
                exitCode: 0
            ),
        ])
        let probes = PaneMetadataProbes(runner: runner, now: { self.fixedDate })
        let ref = probes.prProbe(branch)
        #expect(ref?.number == 11)
        #expect(ref?.url == "https://x/pull/11")
    }

    @Test("pr: empty array → nil")
    func prEmptyArrayNil() {
        let branch = "feature/y"
        let runner = MockProcessRunner(canned: [
            Self.whichGhKey: ProcessRunResult(stdout: Self.ghPath, exitCode: 0),
            Self.ghListKey(branch: branch): ProcessRunResult(stdout: "[]", exitCode: 0),
        ])
        let probes = PaneMetadataProbes(runner: runner, now: { self.fixedDate })
        #expect(probes.prProbe(branch) == nil)
    }

    @Test("pr: non-zero gh exit (unauth) → nil")
    func prNonZeroGhNil() {
        let branch = "feature/z"
        let runner = MockProcessRunner(canned: [
            Self.whichGhKey: ProcessRunResult(stdout: Self.ghPath, exitCode: 0),
            Self.ghListKey(branch: branch): ProcessRunResult(
                stdout: "gh: not authenticated", exitCode: 1
            ),
        ])
        let probes = PaneMetadataProbes(runner: runner, now: { self.fixedDate })
        #expect(probes.prProbe(branch) == nil)
    }

    @Test("pr: garbage / non-JSON stdout → nil")
    func prGarbageJsonNil() {
        let branch = "feature/garbage"
        let runner = MockProcessRunner(canned: [
            Self.whichGhKey: ProcessRunResult(stdout: Self.ghPath, exitCode: 0),
            Self.ghListKey(branch: branch): ProcessRunResult(
                stdout: "not json at all <<>>", exitCode: 0
            ),
        ])
        let probes = PaneMetadataProbes(runner: runner, now: { self.fixedDate })
        #expect(probes.prProbe(branch) == nil)
    }

    @Test("pr: TTL — two calls in-window invoke gh once; a call past TTL re-invokes")
    func prTTLCacheThenExpire() {
        let branch = "feature/ttl"
        let runner = MockProcessRunner(canned: [
            Self.whichGhKey: ProcessRunResult(stdout: Self.ghPath, exitCode: 0),
            Self.ghListKey(branch: branch): ProcessRunResult(
                stdout: #"[{"number":7,"url":"https://github.com/o/r/pull/7"}]"#,
                exitCode: 0
            ),
        ])
        // Mutable injected clock.
        var clock = fixedDate
        let probes = PaneMetadataProbes(runner: runner, now: { clock }, prTTL: 60)

        // 1st call — cache miss, hits gh.
        #expect(probes.prProbe(branch)?.number == 7)
        var ghCalls = runner.calls.filter { $0.executable == Self.ghPath }.count
        #expect(ghCalls == 1)

        // 2nd call within 60s — cache HIT, gh NOT re-invoked.
        clock = fixedDate.addingTimeInterval(30)
        #expect(probes.prProbe(branch)?.number == 7)
        ghCalls = runner.calls.filter { $0.executable == Self.ghPath }.count
        #expect(ghCalls == 1, "second in-window call must be a cache hit")

        // 3rd call past 60s — cache expired, gh re-invoked.
        clock = fixedDate.addingTimeInterval(61)
        #expect(probes.prProbe(branch)?.number == 7)
        ghCalls = runner.calls.filter { $0.executable == Self.ghPath }.count
        #expect(ghCalls == 2, "a call past the TTL must re-invoke gh")
    }

    // MARK: - End-to-end: probes feeding the real resolver

    @Test("end-to-end: probes feed PaneMetadataResolver port/branch/PR seams")
    func endToEndIngest() {
        let wd = "/Users/dev/proj"
        let pgid = "4242"
        let branch = "feature/e2e"
        let runner = MockProcessRunner(canned: [
            MockProcessRunner.key("/usr/bin/git", ["-C", wd, "rev-parse", "--abbrev-ref", "HEAD"]):
                ProcessRunResult(stdout: branch + "\n", exitCode: 0),
            MockProcessRunner.key("/usr/sbin/lsof", ["-i", "-P", "-n", "-sTCP:LISTEN"]):
                ProcessRunResult(
                    stdout: "node \(pgid) dev 23u IPv4 0x0 0t0 TCP *:8080 (LISTEN)\n",
                    exitCode: 0
                ),
            Self.whichGhKey: ProcessRunResult(stdout: Self.ghPath, exitCode: 0),
            Self.ghListKey(branch: branch): ProcessRunResult(
                stdout: #"[{"number":99,"url":"https://github.com/o/r/pull/99"}]"#,
                exitCode: 0
            ),
        ])
        let probes = PaneMetadataProbes(runner: runner, now: { self.fixedDate })

        let resolver = PaneMetadataResolver(
            now: { self.fixedDate },
            portProbe: probes.portProbe,
            branchProbe: probes.branchProbe,
            prProbe: probes.prProbe
        )

        resolver.ingestPort(paneId: "pane-1", probeKey: pgid)
        resolver.ingestBranch(paneId: "pane-1", probeKey: wd)
        resolver.ingestPR(paneId: "pane-1", probeKey: branch)

        let meta = resolver.metadata(for: "pane-1")
        #expect(meta?.port == 8080)
        #expect(meta?.branch == branch)
        #expect(meta?.prRef?.number == 99)
        #expect(meta?.prRef?.url == "https://github.com/o/r/pull/99")
    }
}
