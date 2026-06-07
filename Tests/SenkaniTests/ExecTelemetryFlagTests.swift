import Testing
import Foundation
@testable import CLI

/// V.18b-2 — pins `senkani exec --telemetry`'s env-bundle behavior.
///
/// `Exec.resolveTelemetryEnv(...)` is the surface the CLI's `run()`
/// composes on top of `ProcessInfo.processInfo.environment`. Driving
/// the helper directly avoids spawning a subprocess for what is
/// purely a dictionary-shape contract.
@Suite("Exec --telemetry env injection")
struct ExecTelemetryFlagTests {

    private static let sampleBaseEnv: [String: String] = [
        "PATH": "/usr/bin:/bin",
        "HOME": "/Users/example",
    ]

    @Test func telemetryFlagWithEndpointInjectsOTLPVar() {
        let env = Exec.resolveTelemetryEnv(
            baseEnv: Self.sampleBaseEnv,
            telemetryEnabled: true,
            endpoint: "http://127.0.0.1:54321"
        )
        #expect(env["OTEL_EXPORTER_OTLP_ENDPOINT"] == "http://127.0.0.1:54321",
                "--telemetry with a discovered endpoint must inject OTEL_EXPORTER_OTLP_ENDPOINT")
        // Base env keys are preserved — the helper layers on top, it
        // does not replace the bundle.
        #expect(env["PATH"] == "/usr/bin:/bin")
        #expect(env["HOME"] == "/Users/example")
    }

    @Test func defaultNoFlagDoesNotInjectOTLPVar() {
        // Even when a valid endpoint is present (receiver is bound),
        // the absence of --telemetry must leave OTEL_EXPORTER_OTLP_ENDPOINT
        // unset in the bundle senkani adds. This is the "default off"
        // contract from the V.18b-2 acceptance.
        let env = Exec.resolveTelemetryEnv(
            baseEnv: Self.sampleBaseEnv,
            telemetryEnabled: false,
            endpoint: "http://127.0.0.1:54321"
        )
        #expect(env["OTEL_EXPORTER_OTLP_ENDPOINT"] == nil,
                "no --telemetry flag must not inject OTEL_EXPORTER_OTLP_ENDPOINT even when endpoint is discoverable")
    }
}
