import Testing
import Foundation
@testable import CLI
@testable import Core

/// T.1d-2b-ii r85 — Schneier P1 / Allspaw P1 env-safety doctor surface.
///
/// Pure-formatter tests for `Doctor.formatMITMTerminationReadinessLine`
/// which renders the operator-facing line for the MITM termination
/// readiness check. Three states:
///
///   - flag OFF → `.skip` (opaque tunnel mode, default).
///   - flag ON + on-disk CA pem/key present → `.pass`.
///   - flag ON + on-disk CA missing → `.fail` with operator-runnable
///     `senkani doctor --install-egress-ca` next step.
///
/// Mirror of `DoctorAnthropicVaultLabelsSurfaceTests` — the production
/// check (`checkMITMTerminationReadiness`) resolves the flag via
/// `FeatureConfig.resolve()` and probes `~/.senkani/egress-ca.{pem,key}`;
/// the formatter is lifted out so tests can drive the three states
/// without touching the filesystem or env.
@Suite("DoctorMITMTerminationReadinessSurface (T.1d-2b-ii r85)")
struct DoctorMITMTerminationReadinessSurfaceTests {

    @Test("flag OFF — .skip with opaque-tunnel marker")
    func flagOffSkipsWithOpaqueTunnelMarker() {
        let (status, line) = Doctor.formatMITMTerminationReadinessLine(
            flagOn: false,
            caOnDisk: false
        )
        guard case .skip = status else {
            Issue.record("expected .skip when flag is OFF, got \(status): \(line)")
            return
        }
        #expect(line.contains("MITM termination"), "header missing: \(line)")
        #expect(line.contains("OFF"), "flag-OFF marker missing: \(line)")
        #expect(line.contains("opaque tunnel"), "opaque-tunnel phrase missing: \(line)")
    }

    /// CA-on-disk presence does not change the OFF verdict — the flag
    /// is the gate. This pins the "flag is the source of truth" invariant.
    @Test("flag OFF with CA on disk — still .skip (flag is the gate)")
    func flagOffWithCAOnDiskStillSkips() {
        let (status, line) = Doctor.formatMITMTerminationReadinessLine(
            flagOn: false,
            caOnDisk: true
        )
        guard case .skip = status else {
            Issue.record("expected .skip on flag OFF regardless of CA, got \(status): \(line)")
            return
        }
        #expect(line.contains("OFF"))
    }

    @Test("flag ON + CA on disk — .pass")
    func flagOnWithCAOnDiskPasses() {
        let (status, line) = Doctor.formatMITMTerminationReadinessLine(
            flagOn: true,
            caOnDisk: true
        )
        guard case .pass = status else {
            Issue.record("expected .pass on flag ON + CA present, got \(status): \(line)")
            return
        }
        #expect(line.contains("MITM termination"), "header missing: \(line)")
        #expect(line.contains("ON"), "flag-ON marker missing: \(line)")
        #expect(line.contains("CA"), "CA-present phrase missing: \(line)")
    }

    /// The load-bearing operator-safety assertion: when the flag is ON
    /// but no CA materials exist on disk, doctor MUST fail with an
    /// operator-runnable next step. This is the exact env-safety
    /// observability gap the Schneier + Allspaw r85 verifier panel
    /// flagged.
    @Test("flag ON + CA missing — .fail with `senkani doctor --install-egress-ca` next step")
    func flagOnWithoutCAFailsWithNextStep() {
        let (status, line) = Doctor.formatMITMTerminationReadinessLine(
            flagOn: true,
            caOnDisk: false
        )
        guard case .fail = status else {
            Issue.record("expected .fail on flag ON + CA missing, got \(status): \(line)")
            return
        }
        #expect(line.contains("MITM termination"), "header missing: \(line)")
        #expect(line.contains("ON"), "flag-ON marker missing: \(line)")
        #expect(line.contains("no on-disk CA"), "missing-CA phrase missing: \(line)")
        #expect(line.contains("opaque tunnel"),
            "must explain that the opaque tunnel is what's actually running: \(line)")
        #expect(line.contains("senkani doctor --install-egress-ca"),
            "operator-runnable next step missing: \(line)")
    }
}
