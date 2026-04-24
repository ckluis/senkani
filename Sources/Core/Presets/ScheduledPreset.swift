import Foundation

/// A scheduled-preset record — a template over the already-shipped
/// scheduling spine (`ScheduledTask` + `ScheduleStore` + `CronToLaunchd`).
///
/// Day-1 contract: a preset is a small versioned JSON record that an
/// operator can install via `senkani schedule preset install <name>`
/// to produce a working `ScheduledTask` + launchd plist. Presets add
/// **zero** new infrastructure — they are examples, not a subsystem.
public struct ScheduledPreset: Codable, Sendable, Equatable, Hashable {
    /// Preset identifier. MUST be valid as a `ScheduledTask.name`
    /// (alphanumeric + dashes + underscores only).
    public let name: String

    /// Schema version of the preset record. Bump only when the JSON
    /// shape changes in a non-additive way.
    public let version: Int

    /// Standard 5-field cron expression. MUST round-trip through
    /// `CronToLaunchd.convert`.
    public let cronPattern: String

    /// Shell command to run on schedule. MAY contain placeholders
    /// (`<topic>`, `<competitor>`, `$(date +%F)`, `${SENKANI_…}`) that
    /// `PresetInstaller` substitutes at install time.
    public let command: String

    /// Optional budget cap in cents. `nil` means uncapped. Presets that
    /// call paid surfaces MUST set a non-nil value (Majors' gate).
    public let budgetLimitCents: Int?

    /// Whether each fire runs inside a fresh git worktree.
    public let worktree: Bool

    /// Notification policy per outcome. Consumed by the (planned)
    /// `NotificationSink`; presence here is forward-compatible.
    public let notify: NotifyPolicy

    /// One-of {"shell","claude","local-llm"} — the engine class this
    /// preset exercises. Used for display grouping and sanity checks,
    /// NOT dispatched on at runtime (the `command` is always a shell
    /// string).
    public let engine: Engine

    /// One-line description for `preset list` + the Schedules pane
    /// sheet (keep under ~120 characters).
    public let description: String

    /// Docs URL for the preset's reference page. May be absolute
    /// (`https://…`) or repo-relative (`/docs/…`).
    public let docUrl: String

    /// Companion surfaces this preset depends on to run at full
    /// capability. Each entry is a free-form identifier that the
    /// prerequisite check interprets (e.g. `"ollama"`, `"senkani_search_web"`,
    /// `"guard-research"`, `"senkani-brief-cli"`,
    /// `"pushover-notification-sink"`). Missing prerequisites warn at
    /// install time, they do NOT block install (Podmajersky gate).
    public let prerequisites: [String]

    public enum Engine: String, Codable, Sendable, Equatable, Hashable {
        case shell
        case claude
        case localLLM = "local-llm"
    }

    public struct NotifyPolicy: Codable, Sendable, Equatable, Hashable {
        public let onSuccess: Priority
        public let onFailure: Priority

        public enum Priority: String, Codable, Sendable, Equatable, Hashable {
            case none, info, attention
        }

        public init(onSuccess: Priority, onFailure: Priority) {
            self.onSuccess = onSuccess
            self.onFailure = onFailure
        }
    }

    public init(
        name: String,
        version: Int = 1,
        cronPattern: String,
        command: String,
        budgetLimitCents: Int? = nil,
        worktree: Bool = false,
        notify: NotifyPolicy = NotifyPolicy(onSuccess: .none, onFailure: .attention),
        engine: Engine,
        description: String,
        docUrl: String,
        prerequisites: [String] = []
    ) {
        self.name = name
        self.version = version
        self.cronPattern = cronPattern
        self.command = command
        self.budgetLimitCents = budgetLimitCents
        self.worktree = worktree
        self.notify = notify
        self.engine = engine
        self.description = description
        self.docUrl = docUrl
        self.prerequisites = prerequisites
    }
}

public extension ScheduledPreset {
    /// Placeholder tokens this preset accepts at install time. Derived
    /// from the `command` string — we scan for `<...>` shell-unfriendly
    /// angle-bracket tokens and return their names.
    ///
    /// A preset that needs a `--topic "AI workstation"` override
    /// will have `<topic>` in its command; `placeholders` returns
    /// `["topic"]`.
    var placeholders: [String] {
        var seen = Set<String>()
        var out: [String] = []
        var i = command.startIndex
        while i < command.endIndex {
            guard command[i] == "<",
                  let end = command[i...].firstIndex(of: ">") else {
                i = command.index(after: i)
                continue
            }
            let inner = command[command.index(after: i)..<end]
            // Only accept simple identifier-shaped tokens — avoids
            // catching redirections like `<&1` or `<filename`.
            let ok = !inner.isEmpty && inner.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            if ok {
                let key = String(inner)
                if seen.insert(key).inserted { out.append(key) }
            }
            i = command.index(after: end)
        }
        return out
    }

    /// Resolve placeholders (`<topic>`) against an override map.
    /// Unknown placeholders are left untouched so the operator sees
    /// them in the stored command — they become "this preset has an
    /// unfilled slot" instead of a silent empty substitution.
    func resolvedCommand(overrides: [String: String]) -> String {
        var out = command
        for (key, value) in overrides {
            out = out.replacingOccurrences(of: "<\(key)>", with: value)
        }
        return out
    }

    /// Produce the `ScheduledTask` for a given override map. Caller is
    /// responsible for calling `ScheduleStore.save(_:)` + launchd plist
    /// install after secret-scan + prerequisite-check pass.
    func toScheduledTask(overrides: [String: String] = [:],
                        budgetOverride: Int? = nil,
                        cronOverride: String? = nil) -> ScheduledTask {
        ScheduledTask(
            name: name,
            cronPattern: cronOverride ?? cronPattern,
            command: resolvedCommand(overrides: overrides),
            budgetLimitCents: budgetOverride ?? budgetLimitCents,
            worktree: worktree
        )
    }
}
