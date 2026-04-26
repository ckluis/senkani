// CLI conventions: see docs/cli-conventions.md.
// Glossary: see spec/glossary.md.
//
// Known deviations from docs/cli-conventions.md (track or fix; don't
// add new ones):
//   • Type-name suffix `Command`: only `BenchCommand` + `BundleCommand`
//     follow it. The other 20 types (Exec, Init, Stats, Index, Search,
//     Fetch, Explore, Compare, Validate, MCPInstall, Schedule, Doctor,
//     Grammars, Uninstall, KB, Eval, MLEval, Learn, Wipe, Export)
//     elide the suffix. Rename in a dedicated cleanup round.
//   • `WipeCommand`'s `--yes` help text reads "Confirm the destructive
//     action" while `UninstallCommand`'s reads "Skip confirmation
//     prompt." Same flag, same purpose — copy should match.
//   • `BundleCommand` exposes `--format <markdown|json>`; `EvalCommand`
//     and `BenchCommand` expose `--json` (Bool). Both forms are valid
//     under the conventions (markdown is a document format), but new
//     commands should pick one and stick with it.
import ArgumentParser

@main
struct Senkani: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "senkani",
        abstract: "CLI proxy that reduces LLM token consumption by filtering command output.",
        version: "0.1.0",
        subcommands: [Exec.self, Init.self, Stats.self, Index.self, Search.self, Fetch.self, Explore.self, Compare.self, Validate.self, MCPInstall.self, Schedule.self, Doctor.self, Grammars.self, BenchCommand.self, Uninstall.self, KB.self, Eval.self, MLEval.self, Learn.self, Wipe.self, Export.self, BundleCommand.self]
    )
}
