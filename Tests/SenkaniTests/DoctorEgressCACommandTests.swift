import Testing
import Foundation
@testable import CLI
@testable import Core

/// T.1d-6 contract tests for `senkani doctor --install-egress-ca` /
/// `--uninstall-egress-ca`.
///
/// CRITICAL SECURITY INVARIANT (asserted structurally, not just by
/// behavior): there is NO real-exec path for `security` in this leg. The
/// `TrustInstallExecutor` protocol has exactly ONE conformer —
/// `Doctor.DryRunTrustInstallExecutor` — which PRINTS and RECORDS the
/// `security ...` invocation but never spawns a process. No test here, and
/// no production code path, can run `security add-trusted-cert` /
/// `remove-trusted-cert`, sudo, or mutate the System Keychain. The real
/// trust install is the gui-human item t1d-7.
///
/// Every test uses a TEST CA path in a fresh temp dir — never `~/.senkani`,
/// never `/Library/Keychains/System.keychain`. The motions only ever (a)
/// write the CA pem + 0600 key to the temp dir and (b) append the
/// invocation to the recorder's in-memory array. The System Keychain is
/// never opened, read, or written, because there is no code that does so.
@Suite("Doctor --install/--uninstall-egress-ca — T.1d-6 dry-run scaffolding")
struct DoctorEgressCACommandTests {

    /// A fresh temp directory + CA paths under it. Caller is responsible for
    /// removing the directory (use `defer`).
    private static func makeTempCAPaths() -> (paths: MITMCertificateAuthority.Paths, dir: String) {
        let dir = NSTemporaryDirectory() + "senkani-egress-ca-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let paths = MITMCertificateAuthority.Paths(
            publicCertPEM: (dir as NSString).appendingPathComponent("egress-ca.pem"),
            privateKeyPEM: (dir as NSString).appendingPathComponent("egress-ca.key")
        )
        return (paths, dir)
    }

    private static func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test("install dry-run records security add-trusted-cert and spawns NO process; CA pem written to temp dir")
    func installDryRunRecordsInvocation() throws {
        let (paths, dir) = Self.makeTempCAPaths()
        defer { Self.cleanup(dir) }

        let recorder = Doctor.DryRunTrustInstallExecutor(silent: true)

        // Matching confirm string → motion proceeds.
        try Doctor.installEgressCAMotion(
            caPaths: paths,
            executor: recorder,
            confirmReader: { Doctor.installConfirmPhrase }
        )

        // The recorder is the ONLY sink — there is no process-spawn code to
        // reach. Exactly one invocation was captured.
        #expect(recorder.invocations.count == 1,
                "install motion must record exactly one trust-install invocation, got \(recorder.invocations.count)")

        let inv = recorder.invocations.first ?? []
        #expect(inv.first == "security",
                "invocation argv[0] must be `security`, got: \(inv)")
        #expect(inv.contains("add-trusted-cert"),
                "invocation must be `security add-trusted-cert ...`, got: \(inv)")
        #expect(inv.contains("-r") && inv.contains("trustRoot"),
                "invocation must mark the cert as a trust root, got: \(inv)")
        #expect(inv.contains(Doctor.systemKeychainPath),
                "invocation must target the System keychain PATH (printed, never opened), got: \(inv)")
        #expect(inv.last == paths.publicCertPEM,
                "invocation must reference the TEST CA pem path, got: \(inv)")

        // The CA pem (and its 0600 key) were generated into the temp dir —
        // NOT into ~/.senkani and NOT into any keychain.
        #expect(FileManager.default.fileExists(atPath: paths.publicCertPEM),
                "install motion must generate the CA pem at the TEST path")
        #expect(FileManager.default.fileExists(atPath: paths.privateKeyPEM),
                "install motion must generate the 0600 CA key at the TEST path")

        // The pem path lives under our temp dir — never the System Keychain
        // or the real ~/.senkani default.
        #expect(paths.publicCertPEM.hasPrefix(dir),
                "CA pem must live under the test temp dir, got: \(paths.publicCertPEM)")
    }

    @Test("uninstall dry-run records security remove-trusted-cert and removes the local CA pem")
    func uninstallDryRunRemovesPemAndRecords() throws {
        let (paths, dir) = Self.makeTempCAPaths()
        defer { Self.cleanup(dir) }

        // Seed a CA pem + key on disk first (so uninstall has something to
        // remove). Generate via the same sync bridge the CLI uses.
        try Doctor.generateCASync(paths: paths)
        #expect(FileManager.default.fileExists(atPath: paths.publicCertPEM),
                "fixture: CA pem must exist before uninstall")

        let recorder = Doctor.DryRunTrustInstallExecutor(silent: true)
        try Doctor.uninstallEgressCAMotion(caPaths: paths, executor: recorder)

        // Recorded the removal invocation (printed, never run).
        #expect(recorder.invocations.count == 1,
                "uninstall must record exactly one removal invocation, got \(recorder.invocations.count)")
        let inv = recorder.invocations.first ?? []
        #expect(inv.first == "security" && inv.contains("remove-trusted-cert"),
                "invocation must be `security remove-trusted-cert ...`, got: \(inv)")
        #expect(inv.last == paths.publicCertPEM,
                "removal invocation must reference the TEST CA pem path, got: \(inv)")

        // Local pem + key removed from the temp dir.
        #expect(!FileManager.default.fileExists(atPath: paths.publicCertPEM),
                "uninstall must remove the local CA pem")
        #expect(!FileManager.default.fileExists(atPath: paths.privateKeyPEM),
                "uninstall must remove the local 0600 CA key")
    }

    @Test("typed-confirm ACCEPT: matching string proceeds and the recorder holds the invocation")
    func typedConfirmAcceptProceeds() throws {
        let (paths, dir) = Self.makeTempCAPaths()
        defer { Self.cleanup(dir) }

        let recorder = Doctor.DryRunTrustInstallExecutor(silent: true)
        // Inject a reader returning the EXACT expected phrase.
        try Doctor.installEgressCAMotion(
            caPaths: paths,
            executor: recorder,
            confirmReader: { Doctor.installConfirmPhrase }
        )

        #expect(recorder.invocations.count == 1,
                "matching confirm must let the motion proceed and record the invocation")

        // Pure helper: the same comparison the motion gates on.
        #expect(Doctor.confirmMatches(input: Doctor.installConfirmPhrase,
                                      expected: Doctor.installConfirmPhrase),
                "confirmMatches must accept an exact match")
    }

    @Test("typed-confirm REJECT: mismatched string hard-aborts; recorder EMPTY; no CA generated")
    func typedConfirmRejectAborts() throws {
        let (paths, dir) = Self.makeTempCAPaths()
        defer { Self.cleanup(dir) }

        let recorder = Doctor.DryRunTrustInstallExecutor(silent: true)

        // Mismatched confirm string → the motion must throw before any
        // invocation is built/recorded AND before the CA is generated.
        #expect(throws: (any Error).self) {
            try Doctor.installEgressCAMotion(
                caPaths: paths,
                executor: recorder,
                confirmReader: { "not-the-phrase" }
            )
        }

        // Recorder is EMPTY — the abort happened before any motion. There is
        // no trust action, recorded or otherwise.
        #expect(recorder.invocations.isEmpty,
                "rejected confirm must leave the recorder EMPTY (abort before any invocation), got \(recorder.invocations)")

        // No CA pem was generated (the abort precedes generation).
        #expect(!FileManager.default.fileExists(atPath: paths.publicCertPEM),
                "rejected confirm must not generate the CA pem")
        #expect(!FileManager.default.fileExists(atPath: paths.privateKeyPEM),
                "rejected confirm must not generate the CA key")

        // Pure helper rejects a mismatch (and a nil/no-input tty).
        #expect(!Doctor.confirmMatches(input: "not-the-phrase",
                                       expected: Doctor.installConfirmPhrase),
                "confirmMatches must reject a mismatch")
        #expect(!Doctor.confirmMatches(input: nil,
                                       expected: Doctor.installConfirmPhrase),
                "confirmMatches must reject nil (EOF / no tty)")
    }

    @Test("invocation builders are pure and match the printed argv exactly")
    func invocationBuildersArePure() {
        let pem = "/tmp/test-only/egress-ca.pem"
        let add = Doctor.addTrustedCertInvocation(pemPath: pem)
        #expect(add == ["security", "add-trusted-cert", "-d", "-r", "trustRoot",
                        "-k", Doctor.systemKeychainPath, pem],
                "add-trusted-cert argv drifted: \(add)")

        let remove = Doctor.removeTrustedCertInvocation(pemPath: pem)
        #expect(remove == ["security", "remove-trusted-cert", "-d", pem],
                "remove-trusted-cert argv drifted: \(remove)")
    }
}
