import Testing
import Foundation
@testable import CLI

/// V.13e-6 — surface-docs regression lock.
///
/// The final V.13 integration child documents the operator-facing
/// OpenAI-endpoint surface in CLI `--help` and flips the V.13 phase row
/// to ✅ SHIPPED. The phase flip lives in the spec tree; this suite locks
/// the *help-text* half so a future flag rename / abstract rewrite can't
/// silently drop documentation of:
///   • `senkani serve --openai` and its bind / port / accept-network-bind
///     surface (the full listener contract — `OpenAIEndpointConfig`'s four
///     keys minus `enabled`, which is config-only).
///   • `senkani vault add openai-key` (the credential-provisioning verb).
///
/// In-process `helpMessage()` rendering, no subprocess — same convention as
/// `OpenAIPresetVocabularyTests.helpTextMatchesVocabulary` and
/// `CLISmokeTests`. (`senkani`/`vault` are CLI-only operator commands, not
/// MCP tools; the agent-facing copy of this surface lives in README +
/// docs/reference/cli.html, kept in sync by the round's doc-sync, while
/// this suite is the binary's own self-documentation gate.)
@Suite("V.13e-6 — OpenAI surface is documented in CLI help")
struct OpenAISurfaceDocsTests {

    // MARK: - `senkani serve --help` documents the full --openai surface

    @Test("serve --help documents --openai + bind + port + accept-network-bind")
    func serveHelpDocumentsOpenAISurface() {
        let help = Serve.helpMessage()
        #expect(help.contains("--openai"),
                "serve --help must document the --openai surface flag")
        #expect(help.contains("--bind"),
                "serve --help must document --bind")
        #expect(help.contains("--port"),
                "serve --help must document --port")
        #expect(help.contains("--accept-network-bind"),
                "serve --help must document --accept-network-bind")
    }

    /// Schneier guard: the bind/accept-network-bind help must keep the
    /// non-loopback default-deny framing. A help rewrite that drops the
    /// "requires --accept-network-bind" / "non-loopback" language would
    /// mis-document the listener's refuse-to-start security contract even
    /// while the flags themselves still parse.
    @Test("serve --help keeps the non-loopback default-deny framing")
    func serveHelpKeepsNonLoopbackGuardFraming() {
        let help = Serve.helpMessage().lowercased()
        #expect(help.contains("loopback"),
                "serve --help must explain the loopback default")
        #expect(help.contains("accept-network-bind"),
                "serve --help must tie a non-loopback bind to --accept-network-bind")
    }

    // MARK: - `senkani vault add` documents openai-key

    @Test("vault add --help documents the openai-key credential kind")
    func vaultAddHelpDocumentsOpenAIKey() {
        let help = VaultAdd.helpMessage()
        #expect(help.contains("openai-key"),
                "vault add --help must document the openai-key credential kind")
    }

    @Test("vault --help lists the add subcommand")
    func vaultHelpListsAddSubcommand() {
        let help = Vault.helpMessage()
        #expect(help.contains("add"),
                "vault --help must list the `add` subcommand so operators discover `vault add openai-key`")
    }
}
