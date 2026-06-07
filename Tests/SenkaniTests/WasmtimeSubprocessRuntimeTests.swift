import Testing
import Foundation
@testable import Core

/// T.3a-2 contract tests for `WasmtimeSubprocessRuntime`. Route B
/// (one-shot subprocess + tempfile, no warm pool, WASI `_start`)
/// chosen by scope-groom 2026-05-22.
///
/// Two tests: a happy-path that exercises the full spawn/pipe/EOF
/// cycle against the operator-precompiled WASI `_start` echo fixture
/// at `Tests/SenkaniTests/Fixtures/wasm/echo.wasm`, and a refusal
/// path that injects a `wasmtime` lookup closure throwing
/// `.wasmtime_missing` so we can verify the structured error +
/// install-hint string without needing a real PATH override.
///
/// Fuel / epoch CLI args + DispatchSource watchdog land in t3a-3;
/// `wasm_kill` audit-chain rows in t3a-4; the 12 fuel-/wall-/escape-
/// fixture parameterized tests in t3a-5.
@Suite("WasmtimeSubprocessRuntime — T.3a-2 happy + refusal paths")
struct WasmtimeSubprocessRuntimeTests {

    /// Returns the URL of the operator-precompiled echo fixture
    /// shipped via Package.swift `.copy("Fixtures/wasm")`. Loading
    /// fails the test with `Issue.record` if the resource isn't
    /// bundled — that means the test target's resources list drifted
    /// from the fixture on disk.
    static func echoFixtureURL() -> URL? {
        return Bundle.module.url(
            forResource: "echo",
            withExtension: "wasm",
            subdirectory: "wasm"
        )
    }

    @Test("run echoes guest WASI stdin back as stdout against the precompiled fixture")
    func happyPathEcho() async throws {
        guard let fixtureURL = Self.echoFixtureURL() else {
            Issue.record("missing Tests/SenkaniTests/Fixtures/wasm/echo.wasm — operator must compile via `wasm-tools parse echo.wat -o echo.wasm` and re-run Package.swift resources sync")
            return
        }
        let moduleBytes = try Data(contentsOf: fixtureURL)
        #expect(moduleBytes.count >= 32, "echo.wasm must be a non-trivial WASI command (>= 32 bytes)")

        let runtime = WasmtimeSubprocessRuntime(
            manifest: HandManifest(name: "test", description: "echo test", version: "0")
        )
        let input = Data("hello world\n".utf8)
        let output = try await runtime.run(module: moduleBytes, input: input)
        #expect(output == input, "guest WASI stdin → stdout passthrough must round-trip the input bytes unchanged")
    }

    @Test("run refuses with wasmtime_missing when the lookup closure throws")
    func refusalOnMissingWasmtime() async throws {
        let runtime = WasmtimeSubprocessRuntime(
            manifest: HandManifest(name: "test", description: "refusal test", version: "0"),
            wasmtimeLookup: {
                throw WasmtimeRunnerError.wasmtime_missing(
                    installHint: WasmtimeSubprocessRuntime.installHint
                )
            }
        )
        do {
            _ = try await runtime.run(module: Data(), input: Data())
            Issue.record("expected wasmtime_missing; runtime returned without throwing")
        } catch let error as WasmtimeRunnerError {
            #expect(error == .wasmtime_missing(installHint: "brew install wasmtime"),
                    "refusal hint must match the canonical `brew install wasmtime` string")
        } catch {
            Issue.record("expected WasmtimeRunnerError.wasmtime_missing; got \(error)")
        }
    }
}
