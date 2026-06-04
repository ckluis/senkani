import Foundation
import Testing
#if canImport(Darwin)
import Darwin.POSIX
#endif
@testable import Core

/// T.1d-2b-ii r85 — Schneier P1 / Allspaw P1 env-safety stderr-WARN
/// invariant.
///
/// When the operator flips `mitmTermination: true` in the listener
/// config but the constructor receives `mitmLeafProvider: nil`,
/// `EgressListener.start()` MUST emit a stderr WARNING so the
/// operator knows the security control they enabled is currently a
/// no-op (the connection handler silently falls through to the
/// opaque tunnel). Without this, the operator believes the flag is
/// delivering protection it isn't.
///
/// **Why a separate `.serialized` suite.** Both tests dup2 the
/// process-wide STDERR_FILENO — running them in parallel against
/// each other (or against another stderr-capture suite) would have
/// one suite's dup2 overwrite the other's, dropping the writes onto
/// the wrong pipe. `.serialized` here serializes within this suite;
/// the two sibling stderr-capture suites
/// (`ClaudeAPIChatEnginePromptCachingTests`,
/// `ClaudeAPIServeDispatchTests`) carry the same trait. The cross-
/// suite race is rare enough that those siblings have shipped
/// without a process-wide gate, but a future failure would justify
/// promoting the pattern to a shared `stderrCaptureGate` trait
/// (mirror of `LoggerSinkGateTrait`).
@Suite("EgressListener env-safety stderr WARN (T.1d-2b-ii r85)", .serialized)
struct EgressListenerEnvSafetyWarnTests {

    /// `start()` MUST emit the WARNING marker on stderr when the
    /// operator state is `flag ON + no leaf provider`.
    @Test("listener start() emits stderr WARNING when mitmTermination ON but no leaf provider wired")
    func envSafetyStderrWarnFiresOnFlagOnWithoutProvider() throws {
        let captured = Self.captureStderr {
            let listener = EgressListener(
                rules: EgressRuleEngine(rules: []),
                database: Self.tempDB(),
                config: .init(
                    port: 0,
                    writePortFile: false,
                    portFilePath: "",
                    mitmTermination: true
                ),
                mitmLeafProvider: nil
            )
            try? listener.start()
            listener.stop()
        }

        let captureStr = String(data: captured, encoding: .utf8) ?? ""
        #expect(
            captureStr.contains("WARNING — mitmTlsTermination flag is ON but no leaf provider"),
            "expected env-safety WARNING marker on stderr; got: \(captureStr)"
        )
    }

    /// Negative control. The WARNING MUST NOT fire when the flag is
    /// OFF (default state). Otherwise every fresh install would spam
    /// a misleading warning on the operator's terminal at egress
    /// daemon start.
    @Test("listener start() does NOT emit env-safety WARNING when mitmTermination is OFF")
    func envSafetyStderrWarnSilentWhenFlagOff() throws {
        let captured = Self.captureStderr {
            let listener = EgressListener(
                rules: EgressRuleEngine(rules: []),
                database: Self.tempDB(),
                config: .init(
                    port: 0,
                    writePortFile: false,
                    portFilePath: "",
                    mitmTermination: false
                ),
                mitmLeafProvider: nil
            )
            try? listener.start()
            listener.stop()
        }

        let captureStr = String(data: captured, encoding: .utf8) ?? ""
        #expect(
            !captureStr.contains("WARNING — mitmTlsTermination flag is ON"),
            "WARNING fired when flag was OFF — false positive: \(captureStr)"
        )
    }

    // MARK: - Helpers

    /// dup2-backed stderr capture (mirror of `captureStandardError` in
    /// `ClaudeAPIChatEnginePromptCachingTests.swift`). Synchronous body
    /// shape since the unit under test (`EgressListener.start()`) is
    /// synchronous.
    private static func captureStderr(_ body: () -> Void) -> Data {
        fflush(stderr)
        let savedFd = dup(fileno(stderr))
        precondition(savedFd >= 0, "dup(stderr) failed")
        let pipe = Pipe()
        let writeFd = pipe.fileHandleForWriting.fileDescriptor
        let dupResult = dup2(writeFd, fileno(stderr))
        precondition(dupResult >= 0, "dup2(stderr) failed")

        body()

        // Flush + close the write end so readDataToEndOfFile drains and
        // returns. Restore stderr BEFORE the read so any diagnostic that
        // fires during the drain goes to the real stderr.
        fflush(stderr)
        try? pipe.fileHandleForWriting.close()
        _ = dup2(savedFd, fileno(stderr))
        close(savedFd)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        try? pipe.fileHandleForReading.close()
        return data
    }

    private static func tempDB() -> SessionDatabase {
        let dir = NSTemporaryDirectory() + "senkani-egress-envsafety-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return SessionDatabase(path: dir + "senkani.db")
    }
}
