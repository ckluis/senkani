import Testing
import Foundation
@testable import Core

/// Regression fixtures for the env-var bundle that every pane subprocess
/// receives. Pins the MCP gate-key set and the parity between the plain
/// Terminal pane and the Ollama-launcher pane — i.e. "tooling works
/// inside the Ollama pane because the same keys go in."
///
/// Traceability: `mcp-in-ollama-pane-verify` (backlog 2026-04-20). The
/// operator's concern ("not sure the senkani tooling worked") couldn't
/// be reproduced at code-review time — the env-injection path is shared
/// with the Terminal pane through `TerminalViewRepresentable`. These
/// tests pin the shared contract so future drift surfaces loudly.
@Suite("PaneLaunchEnv")
struct PaneLaunchEnvTests {

    // MARK: - Fixture

    private static let sampleInputs = PaneLaunchEnv.Inputs(
        paneID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        projectRoot: "/Users/example/code/project",
        metricsFilePath: "/tmp/senkani-metrics.jsonl",
        configFilePath: "/tmp/senkani-pane.env",
        workspaceSlug: "code-project",
        paneSlug: "ollamaLauncher",
        filterOn: true,
        cacheOn: true,
        secretsOn: true,
        indexerOn: true,
        terseOn: false
    )

    // MARK: - Gate-key coverage

    @Test func ollamaLauncherEnvHasEveryRequiredGateKey() {
        let env = PaneLaunchEnv.ollamaLauncher(
            Self.sampleInputs,
            resolvedModelTag: "llama3.1:8b"
        )
        for key in PaneLaunchEnv.requiredGateKeys {
            #expect(env[key] != nil,
                    "Ollama-launcher env missing required MCP gate key '\(key)'")
            #expect(!(env[key] ?? "").isEmpty,
                    "Ollama-launcher env has empty value for gate key '\(key)'")
        }
    }

    @Test func terminalEnvHasEveryRequiredGateKey() {
        let env = PaneLaunchEnv.terminal(Self.sampleInputs)
        for key in PaneLaunchEnv.requiredGateKeys {
            #expect(env[key] != nil,
                    "Terminal env missing required MCP gate key '\(key)'")
        }
    }

    // MARK: - Parity (the actual mcp-in-ollama-pane-verify assertion)

    @Test func ollamaLauncherEnvSharesAllGateKeysWithTerminalEnv() {
        // The operator's concern collapses to this: for every
        // SENKANI_* gate key a plain Terminal pane ships, the
        // Ollama-launcher pane must ship the same key with the same
        // value. If this test ever regresses, the MCP server attached
        // to the Ollama pane's socket will silently disable whatever
        // subsystem the dropped key gates.
        let terminalEnv = PaneLaunchEnv.terminal(Self.sampleInputs)
        let ollamaEnv = PaneLaunchEnv.ollamaLauncher(
            Self.sampleInputs,
            resolvedModelTag: "qwen2.5-coder:7b"
        )
        for (key, expected) in terminalEnv {
            #expect(ollamaEnv[key] == expected,
                    "Parity gap on '\(key)': terminal='\(expected)' vs ollama='\(ollamaEnv[key] ?? "<nil>")'")
        }
    }

    // MARK: - Ollama-specific key

    @Test func ollamaLauncherEnvCarriesResolvedModelTag() {
        let env = PaneLaunchEnv.ollamaLauncher(
            Self.sampleInputs,
            resolvedModelTag: "mistral:7b"
        )
        #expect(env["SENKANI_OLLAMA_MODEL"] == "mistral:7b",
                "Ollama pane must surface its resolved model tag via SENKANI_OLLAMA_MODEL")
    }

    @Test func terminalEnvOmitsOllamaModelKey() {
        // Bounded-context gate (Evans): plain Terminal panes have no
        // Ollama concern; leaking the key would invite downstream code
        // to branch on its presence as a proxy for pane type.
        let env = PaneLaunchEnv.terminal(Self.sampleInputs)
        #expect(env["SENKANI_OLLAMA_MODEL"] == nil,
                "Terminal env must not set SENKANI_OLLAMA_MODEL")
    }

    // MARK: - Schneier: shell-safe values

    @Test func everyEnvValueIsShellSafe() {
        // All values injected into `startProcess`'s env end up as raw
        // `KEY=VALUE` strings. If any value carries a newline, NUL, or
        // embedded `=`-bombs, downstream consumers (the hook script,
        // `env` invocations, CLI wrappers) can mis-parse. Pin the
        // promise at the build boundary.
        let env = PaneLaunchEnv.ollamaLauncher(
            Self.sampleInputs,
            resolvedModelTag: "llama3.1:8b"
        )
        let banned: Set<Character> = ["\n", "\r", "\0"]
        for (key, value) in env {
            for char in value {
                #expect(!banned.contains(char),
                        "env['\(key)']='\(value)' contains a forbidden control character")
            }
        }
    }

    // MARK: - Workspace/pane slugs

    @Test func workspaceSlugAndPaneSlugRoundTrip() {
        // Round-3 pane-diary invariant: slugs are stable across
        // pane-id recycles. The env bundle is the handoff — if the
        // slug keys disappear or change shape, pane diaries stop
        // reattaching to the right pane.
        let env = PaneLaunchEnv.ollamaLauncher(
            Self.sampleInputs,
            resolvedModelTag: "llama3.1:8b"
        )
        #expect(env["SENKANI_WORKSPACE_SLUG"] == "code-project")
        #expect(env["SENKANI_PANE_SLUG"] == "ollamaLauncher")
    }

    // MARK: - Feature flag mapping

    @Test func featureFlagsTurningOffFlipValues() {
        let offInputs = PaneLaunchEnv.Inputs(
            paneID: Self.sampleInputs.paneID,
            projectRoot: Self.sampleInputs.projectRoot,
            metricsFilePath: Self.sampleInputs.metricsFilePath,
            configFilePath: Self.sampleInputs.configFilePath,
            workspaceSlug: Self.sampleInputs.workspaceSlug,
            paneSlug: Self.sampleInputs.paneSlug,
            filterOn: false,
            cacheOn: false,
            secretsOn: false,
            indexerOn: false,
            terseOn: true
        )
        let env = PaneLaunchEnv.ollamaLauncher(offInputs, resolvedModelTag: "llama3.1:8b")
        #expect(env["SENKANI_MCP_FILTER"]  == "off")
        #expect(env["SENKANI_MCP_CACHE"]   == "off")
        #expect(env["SENKANI_MCP_SECRETS"] == "off")
        #expect(env["SENKANI_MCP_INDEX"]   == "off")
        #expect(env["SENKANI_MCP_TERSE"]   == "on")
    }
}
