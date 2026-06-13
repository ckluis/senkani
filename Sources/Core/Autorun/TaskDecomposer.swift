import Foundation

/// U.3 (LEG 1) — `TaskDecomposer`: parse a free-form markdown task file
/// into `[WorkstreamTaskContract]` rows.
///
/// This is the Core-pure decomposition seam behind `senkani autorun
/// --tasks <path>`. It reads a markdown file where each **top-level
/// bullet** (`-` / `*` / `+`) is one task, and emits one
/// `WorkstreamTaskContract` (U.11's contract type — U.3 ships ZERO new
/// task-type definitions, per the item's Q4 scope decision) per bullet.
///
/// ## Field mapping (leg 1 — EXISTING `WorkstreamTaskContract` fields only)
///
/// The decomposer fills the contract from the bullet text plus optional
/// inline annotations. It does NOT introduce a `taskClass` field — class
/// inference + `--allow-classes` are a LATER leg (the item's Q3 guardrail
/// list), and adding the column would be a schema break. Mapping:
///
///   - `objective`     ← the bullet's prose (annotations stripped).
///   - `commands`      ← `cmd:` / `cmds:` inline annotation, split on `;`
///                       and `&&`; defaults to `["swift build", "swift
///                       test"]` (the existing test/lint gate axes the
///                       item names) when none is annotated.
///   - `fileScope`     ← `files:` inline annotation, comma/space split;
///                       defaults to `[]` (no scope restriction).
///   - `acceptance`    ← left `[]` (the assertion-id FK surface is U.11's;
///                       leg 1 gates on the command exit codes, not on
///                       pre-registered `ValidationAssertion` rows).
///   - `allowedTools`  ← `[]` (leg 1 does not constrain tools).
///   - `dependencies`  ← `[]`.
///   - `budget`        ← a zero budget (caps disabled; the loop does not
///                       enforce token/wall-clock caps in leg 1).
///   - `reviewLevel`   ← `.none`.
///   - `id`            ← deterministic UUIDv5-style derivation is overkill
///                       for leg 1; a fresh `UUID()` per task is fine — the
///                       contracts.json file is the durable identity once
///                       persisted (resume reads it back, never re-runs the
///                       decomposer for a live run).
///   - `workstreamID`  ← one shared per-run workstream id (so all tasks in a
///                       run share a workstream).
///
/// ## Inline annotation syntax (leg 1)
///
/// A bullet may carry zero or more `key: value` annotations after the
/// prose, each introduced by a literal `[key: value]` bracket OR a
/// trailing ` -- key: value` segment. Leg 1 recognizes `cmd`/`cmds`,
/// `files`. Unknown keys are left in the objective verbatim (forward-
/// compat: a newer senkani that recognizes more keys won't choke on an
/// older file, and vice-versa). The parse is deliberately small — the
/// rich TUI decomposer pane is a later leg.
public struct TaskDecomposer: Sendable {

    /// The default per-task command gate when a bullet carries no `cmd:`
    /// annotation. These are the existing test/lint axes the U.3 item's
    /// per-task validation gate runs on (NOT U.2's browser axes).
    public static let defaultCommands: [String] = ["swift build", "swift test"]

    public init() {}

    /// Decompose markdown `source` into one contract per top-level bullet.
    ///
    /// - Parameters:
    ///   - source: the raw markdown text.
    ///   - workstreamID: the shared workstream id all tasks in this run
    ///     attach to. Defaults to a fresh id.
    ///   - idFactory: injectable id source so tests can pin deterministic
    ///     ids; defaults to `UUID()`.
    /// - Returns: the decomposed contracts, in document order. A file with
    ///   no top-level bullets yields `[]`.
    public func decompose(
        markdown source: String,
        workstreamID: UUID = UUID(),
        idFactory: () -> UUID = { UUID() }
    ) -> [WorkstreamTaskContract] {
        var contracts: [WorkstreamTaskContract] = []
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard let bullet = Self.bulletBody(of: line) else { continue }
            let parsed = Self.parseBullet(bullet)
            guard !parsed.objective.isEmpty else { continue }
            let contract = WorkstreamTaskContract(
                id: idFactory(),
                workstreamID: workstreamID,
                objective: parsed.objective,
                fileScope: parsed.files,
                allowedTools: [],
                dependencies: [],
                staleSpecAt: nil,
                budget: ContractBudget(tokensMax: 0, wallClockMaxS: 0),
                commands: parsed.commands.isEmpty ? Self.defaultCommands : parsed.commands,
                acceptance: [],
                reviewLevel: .none
            )
            contracts.append(contract)
        }
        return contracts
    }

    /// Decompose a markdown file at `path`. Throws `DecomposeError` if the
    /// file cannot be read.
    public func decompose(
        contentsOfFile path: String,
        workstreamID: UUID = UUID(),
        idFactory: () -> UUID = { UUID() }
    ) throws -> [WorkstreamTaskContract] {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            throw DecomposeError.unreadable(path: path)
        }
        return decompose(markdown: text, workstreamID: workstreamID, idFactory: idFactory)
    }

    public enum DecomposeError: Error, Equatable {
        /// The task file at `path` does not exist or is not UTF-8 text.
        case unreadable(path: String)
    }

    // MARK: - Parsing internals

    /// Returns the body of a TOP-LEVEL markdown bullet (`-`, `*`, `+`
    /// with NO leading indentation), or nil if the line is not such a
    /// bullet. Indented (nested) bullets are deliberately ignored in
    /// leg 1 — one top-level bullet = one task.
    static func bulletBody(of line: String) -> String? {
        // No leading whitespace allowed (top-level only). A leading space
        // or tab marks a nested bullet, which leg 1 does not flatten.
        guard let first = line.first else { return nil }
        guard first == "-" || first == "*" || first == "+" else { return nil }
        let afterMarker = line.dropFirst()
        // Require a space after the marker so a literal `-->` or `***`
        // horizontal rule is not mistaken for a bullet.
        guard let sep = afterMarker.first, sep == " " || sep == "\t" else { return nil }
        let body = afterMarker.drop { $0 == " " || $0 == "\t" }
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    struct ParsedBullet {
        var objective: String
        var commands: [String]
        var files: [String]
    }

    /// Parse one bullet body into its objective + recognized annotations.
    static func parseBullet(_ body: String) -> ParsedBullet {
        var objectiveParts: [String] = []
        var commands: [String] = []
        var files: [String] = []

        // First pull out any `[key: value]` bracket annotations.
        var remaining = body
        for (key, value) in Self.bracketAnnotations(in: &remaining) {
            Self.apply(key: key, value: value, commands: &commands, files: &files)
        }

        // Then handle a single trailing ` -- key: value[; key: value]` tail.
        if let tailRange = remaining.range(of: " -- ") {
            let head = String(remaining[..<tailRange.lowerBound])
            let tail = String(remaining[tailRange.upperBound...])
            objectiveParts.append(head)
            for (key, value) in Self.tailAnnotations(in: tail) {
                Self.apply(key: key, value: value, commands: &commands, files: &files)
            }
        } else {
            objectiveParts.append(remaining)
        }

        let objective = objectiveParts
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedBullet(objective: objective, commands: commands, files: files)
    }

    /// Extract `[key: value]` bracket annotations, removing them from
    /// `text` in place. Only brackets whose key is a recognized
    /// annotation key are consumed; unrecognized `[...]` spans are left
    /// in the objective verbatim.
    private static func bracketAnnotations(in text: inout String) -> [(String, String)] {
        var found: [(String, String)] = []
        var result = ""
        var scanner = Substring(text)
        while let open = scanner.firstIndex(of: "[") {
            // Keep text before the bracket.
            result += scanner[..<open]
            let afterOpen = scanner.index(after: open)
            guard let close = scanner[afterOpen...].firstIndex(of: "]") else {
                // Unbalanced — keep the rest verbatim and stop.
                result += scanner[open...]
                scanner = Substring("")
                break
            }
            let inner = String(scanner[afterOpen..<close])
            if let (key, value) = Self.splitKeyValue(inner), Self.isRecognizedKey(key) {
                // Recognized annotation — consume the whole `[...]` span
                // (do NOT re-append it to the objective).
                found.append((key, value))
            } else {
                // Not an annotation — keep the literal `[...]` span,
                // closing bracket included, in the objective verbatim.
                let spanEnd = scanner.index(after: close)
                result += scanner[open..<spanEnd]
            }
            scanner = scanner[scanner.index(after: close)...]
        }
        result += scanner
        text = result
        return found
    }

    /// Parse a trailing-tail annotation segment: `key: value; key: value`.
    private static func tailAnnotations(in tail: String) -> [(String, String)] {
        var out: [(String, String)] = []
        for segment in tail.split(separator: ";") {
            if let (key, value) = Self.splitKeyValue(String(segment)), Self.isRecognizedKey(key) {
                out.append((key, value))
            }
        }
        return out
    }

    private static func splitKeyValue(_ s: String) -> (String, String)? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let key = String(s[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
        let value = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty else { return nil }
        return (key, value)
    }

    private static func isRecognizedKey(_ key: String) -> Bool {
        switch key {
        case "cmd", "cmds", "command", "commands", "files", "file", "scope":
            return true
        default:
            return false
        }
    }

    private static func apply(
        key: String,
        value: String,
        commands: inout [String],
        files: inout [String]
    ) {
        switch key {
        case "cmd", "cmds", "command", "commands":
            commands.append(contentsOf: Self.splitCommands(value))
        case "files", "file", "scope":
            files.append(contentsOf: Self.splitFiles(value))
        default:
            break
        }
    }

    /// Split a command annotation on `;` and `&&` into individual command
    /// strings; trims each and drops empties.
    static func splitCommands(_ value: String) -> [String] {
        value
            .replacingOccurrences(of: "&&", with: ";")
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Split a file-scope annotation on commas and whitespace.
    static func splitFiles(_ value: String) -> [String] {
        value
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
