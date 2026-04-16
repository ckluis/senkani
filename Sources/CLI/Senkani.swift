import ArgumentParser

@main
struct Senkani: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "senkani",
        abstract: "CLI proxy that reduces LLM token consumption by filtering command output.",
        version: "0.1.0",
        subcommands: [Exec.self, Init.self, Stats.self, Index.self, Search.self, Fetch.self, Explore.self, Compare.self, Validate.self, MCPInstall.self, Schedule.self, Doctor.self, Grammars.self, BenchCommand.self, Uninstall.self, KB.self, Eval.self, Learn.self]
    )
}
