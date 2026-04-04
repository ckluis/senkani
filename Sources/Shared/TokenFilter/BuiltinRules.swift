import Foundation

/// Built-in filter rules for common commands.
/// More specific rules (with subcommand) are listed first so they match before
/// the general rule for that command.
public enum BuiltinRules {
    public static let rules: [FilterRule] = [
        // --- git ---
        FilterRule(command: "git", subcommand: "clone", ops: [
            .stripANSI,
            .stripMatching("Receiving objects"),
            .stripMatching("Resolving deltas"),
            .stripMatching("remote: Counting"),
            .stripMatching("remote: Compressing"),
            .groupSimilar(threshold: 3),
        ]),
        FilterRule(command: "git", subcommand: "log", ops: [
            .stripANSI,
            .tail(50),
            .truncateBytes(8192),
        ]),
        FilterRule(command: "git", subcommand: "diff", ops: [
            .stripANSI,
            .truncateBytes(16384),
        ]),
        FilterRule(command: "git", subcommand: "status", ops: [
            .stripANSI,
            .stripBlankRuns(max: 1),
        ]),
        FilterRule(command: "git", subcommand: "push", ops: [
            .stripANSI,
            .stripMatching("Writing objects"),
            .stripMatching("Compressing objects"),
        ]),
        FilterRule(command: "git", subcommand: "pull", ops: [
            .stripANSI,
            .stripMatching("Receiving objects"),
            .stripMatching("Resolving deltas"),
        ]),
        // General git fallback
        FilterRule(command: "git", subcommand: nil, ops: [
            .stripANSI,
        ]),

        // --- npm/pnpm/yarn ---
        FilterRule(command: "npm", subcommand: "install", ops: [
            .stripANSI,
            .stripMatching("added "),
            .stripMatching("WARN"),
            .groupSimilar(threshold: 5),
            .tail(30),
        ]),
        FilterRule(command: "npm", subcommand: "run", ops: [
            .stripANSI,
            .stripBlankRuns(max: 1),
        ]),
        FilterRule(command: "npm", subcommand: nil, ops: [
            .stripANSI,
        ]),
        FilterRule(command: "pnpm", subcommand: "install", ops: [
            .stripANSI,
            .groupSimilar(threshold: 5),
            .tail(30),
        ]),
        FilterRule(command: "pnpm", subcommand: nil, ops: [
            .stripANSI,
        ]),
        FilterRule(command: "yarn", subcommand: nil, ops: [
            .stripANSI,
            .groupSimilar(threshold: 5),
            .tail(30),
        ]),

        // --- cargo ---
        FilterRule(command: "cargo", subcommand: "build", ops: [
            .stripANSI,
            .stripMatching("Compiling"),
            .stripMatching("Downloading"),
            .groupSimilar(threshold: 3),
            .tail(40),
        ]),
        FilterRule(command: "cargo", subcommand: "test", ops: [
            .stripANSI,
            .groupSimilar(threshold: 3),
            .tail(50),
        ]),
        FilterRule(command: "cargo", subcommand: nil, ops: [
            .stripANSI,
        ]),

        // --- docker ---
        FilterRule(command: "docker", subcommand: "build", ops: [
            .stripANSI,
            .groupSimilar(threshold: 5),
            .tail(30),
        ]),
        FilterRule(command: "docker", subcommand: "pull", ops: [
            .stripANSI,
            .stripMatching("Pulling fs layer"),
            .stripMatching("Waiting"),
            .stripMatching("Already exists"),
            .groupSimilar(threshold: 3),
        ]),
        FilterRule(command: "docker", subcommand: nil, ops: [
            .stripANSI,
        ]),

        // --- kubectl ---
        FilterRule(command: "kubectl", subcommand: "logs", ops: [
            .stripANSI,
            .tail(100),
            .truncateBytes(16384),
        ]),
        FilterRule(command: "kubectl", subcommand: nil, ops: [
            .stripANSI,
            .truncateBytes(8192),
        ]),

        // --- pip ---
        FilterRule(command: "pip", subcommand: "install", ops: [
            .stripANSI,
            .stripMatching("Downloading"),
            .stripMatching("Using cached"),
            .stripMatching("Collecting"),
            .groupSimilar(threshold: 3),
            .tail(20),
        ]),
        FilterRule(command: "pip", subcommand: nil, ops: [
            .stripANSI,
        ]),
        FilterRule(command: "pip3", subcommand: "install", ops: [
            .stripANSI,
            .stripMatching("Downloading"),
            .stripMatching("Using cached"),
            .groupSimilar(threshold: 3),
            .tail(20),
        ]),

        // --- make ---
        FilterRule(command: "make", subcommand: nil, ops: [
            .stripANSI,
            .groupSimilar(threshold: 5),
            .tail(50),
        ]),

        // --- go ---
        FilterRule(command: "go", subcommand: "build", ops: [
            .stripANSI,
            .groupSimilar(threshold: 3),
            .tail(40),
        ]),
        FilterRule(command: "go", subcommand: "test", ops: [
            .stripANSI,
            .tail(50),
        ]),
        FilterRule(command: "go", subcommand: nil, ops: [
            .stripANSI,
        ]),

        // --- pytest ---
        FilterRule(command: "pytest", subcommand: nil, ops: [
            .stripANSI,
            .groupSimilar(threshold: 3),
            .tail(50),
        ]),

        // --- brew ---
        FilterRule(command: "brew", subcommand: "install", ops: [
            .stripANSI,
            .stripMatching("Downloading"),
            .stripMatching("Pouring"),
            .groupSimilar(threshold: 3),
        ]),
        FilterRule(command: "brew", subcommand: nil, ops: [
            .stripANSI,
        ]),

        // --- ls (just strip ANSI) ---
        FilterRule(command: "ls", subcommand: nil, ops: [
            .stripANSI,
        ]),

        // --- cat (truncate large files) ---
        FilterRule(command: "cat", subcommand: nil, ops: [
            .stripANSI,
            .truncateBytes(10240),  // 10KB max
        ]),

        // --- find (limit results) ---
        FilterRule(command: "find", subcommand: nil, ops: [
            .tail(100),
        ]),

        // --- grep / rg (limit results + strip ANSI) ---
        FilterRule(command: "grep", subcommand: nil, ops: [
            .stripANSI,
            .tail(100),
            .truncateBytes(16384),
        ]),
        FilterRule(command: "rg", subcommand: nil, ops: [
            .stripANSI,
            .tail(100),
            .truncateBytes(16384),
        ]),

        // --- swift ---
        FilterRule(command: "swift", subcommand: "build", ops: [
            .stripANSI,
            .groupSimilar(threshold: 3),
            .tail(40),
        ]),
        FilterRule(command: "swift", subcommand: "test", ops: [
            .stripANSI,
            .tail(50),
        ]),
        FilterRule(command: "swift", subcommand: nil, ops: [
            .stripANSI,
        ]),

        // --- bun ---
        FilterRule(command: "bun", subcommand: "install", ops: [
            .stripANSI,
            .groupSimilar(threshold: 5),
            .tail(30),
        ]),
        FilterRule(command: "bun", subcommand: "test", ops: [
            .stripANSI,
            .tail(50),
        ]),
        FilterRule(command: "bun", subcommand: nil, ops: [
            .stripANSI,
        ]),

        // --- curl/wget (strip ANSI, truncate) ---
        FilterRule(command: "curl", subcommand: nil, ops: [
            .stripANSI,
            .truncateBytes(16384),
        ]),
        FilterRule(command: "wget", subcommand: nil, ops: [
            .stripANSI,
            .stripMatching("Saving to"),
            .groupSimilar(threshold: 3),
        ]),
    ]
}
