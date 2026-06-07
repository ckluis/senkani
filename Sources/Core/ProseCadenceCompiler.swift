import Foundation

// MARK: - ProseCadenceCompiler
//
// Phase U.8 — narrow protocol for compiling a natural-language schedule
// expression ("every weekday at 9am") into a 5-field cron string.
//
// The protocol lives in Core so wiring (CLI, App, MCP) can compose with
// any compiler backend without importing MLX into every Core client.
// Production wires an MLX-backed Gemma 4 adapter that runs a strict
// JSON-schema response; tests wire a `MockProseCadenceCompiler`. When
// no model is available, `NullProseCadenceCompiler` throws `.unavailable`
// and callers either fall back to operator-entered cron OR refuse the
// schedule registration with a "no model" message.
//
// Contract:
//   - `compile(prose:locale:)` accepts a prose expression and a
//     BCP-47 locale tag (default "en-US"). Returns a `ProseCadence`
//     with the original prose and the compiled cron.
//   - The compiled cron MUST validate against `CronToLaunchd.convert`
//     before the schedule is saved; the compiler is best-effort, the
//     validation is the gate.
//   - Adapters MAY be slow (LLM inference); caller is responsible for
//     timeouts.
//   - Errors propagate as `ProseCadenceCompilerError`. The .unavailable
//     case is the silent-fallback signal; .invalidJSON / .invalidCron
//     surface to the user so they can correct the prose.

public struct ProseCadence: Equatable, Sendable, Codable {
    /// Original prose as the user typed it.
    public let prose: String
    /// Locale used to parse the prose (BCP-47, e.g. "en-US").
    public let locale: String
    /// 5-field cron expression that the compiler emitted.
    public let cron: String

    public init(prose: String, locale: String, cron: String) {
        self.prose = prose
        self.locale = locale
        self.cron = cron
    }
}

public protocol ProseCadenceCompiler: Sendable {
    /// Compile `prose` (in `locale`) into a 5-field cron expression.
    func compile(prose: String, locale: String) async throws -> ProseCadence
}

extension ProseCadenceCompiler {
    /// Convenience overload defaulting to en-US.
    public func compile(prose: String) async throws -> ProseCadence {
        try await compile(prose: prose, locale: "en-US")
    }
}

// MARK: - NullProseCadenceCompiler
//
// Default wiring when no LLM adapter is available. Every call throws
// `.unavailable` so callers can short-circuit prose-driven registration
// with a "no model installed; type a cron expression instead" message.

public struct NullProseCadenceCompiler: ProseCadenceCompiler {
    public init() {}

    public func compile(prose: String, locale: String) async throws -> ProseCadence {
        throw ProseCadenceCompilerError.unavailable
    }
}

// MARK: - MockProseCadenceCompiler
//
// Test-time adapter. Maps prose → cron via a closure so each test can
// pin the compiler's behavior to a specific output (success, malformed
// cron, throw, etc.) without spinning up an LLM.

public struct MockProseCadenceCompiler: ProseCadenceCompiler {
    public typealias Handler = @Sendable (String, String) throws -> String
    private let handler: Handler

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Convenience: every prose maps to `cron`.
    public init(constantCron cron: String) {
        self.handler = { _, _ in cron }
    }

    public func compile(prose: String, locale: String) async throws -> ProseCadence {
        let cron = try handler(prose, locale)
        guard CronToLaunchd.convert(cron) != nil else {
            throw ProseCadenceCompilerError.invalidCron(cron)
        }
        return ProseCadence(prose: prose, locale: locale, cron: cron)
    }
}

// MARK: - Errors

public enum ProseCadenceCompilerError: Error, Equatable, Sendable {
    /// No backend is configured or the model isn't downloaded.
    case unavailable
    /// The backend returned malformed JSON.
    case invalidJSON(String)
    /// The backend emitted a cron string that fails CronToLaunchd validation.
    case invalidCron(String)
    /// The inference timed out or was cancelled.
    case cancelled
    /// The prose phrase didn't match any supported cadence pattern.
    /// Carries the original prose so the caller can echo it back.
    case unrecognizedPhrase(String)
    /// The locale's language isn't supported by this compiler (the
    /// rule-based compiler is English-only). Carries the BCP-47 tag.
    case unsupportedLocale(String)
}

extension ProseCadenceCompilerError {
    /// A clear, operator-facing message for each case. Used by CLI / App
    /// wiring so the prose path never fails silently — the operator
    /// always learns what to do next (`--cron`, a different phrase, or
    /// `--locale en-US`).
    public var userMessage: String {
        switch self {
        case .unavailable:
            return "No prose-cadence model is available. Pass an explicit cron with --cron instead."
        case .invalidJSON(let raw):
            return "The cadence compiler returned malformed output: \(raw)"
        case .invalidCron(let cron):
            return "The compiled cron \"\(cron)\" is invalid. Pass an explicit --cron instead."
        case .cancelled:
            return "Cadence compilation was cancelled."
        case .unrecognizedPhrase(let prose):
            return "Could not understand the cadence \"\(prose)\". Try a phrase like "
                + "\"every weekday at 9am\", \"every 6 hours\", \"daily\", or pass an explicit --cron."
        case .unsupportedLocale(let locale):
            return "Locale \"\(locale)\" is not supported by the rule-based prose compiler "
                + "(English only). Pass --locale en-US, or use an explicit --cron."
        }
    }
}

// MARK: - CompositeProseCadenceCompiler
//
// Phase U.8b-3 — two-arm composite: rule-based FIRST, MLX fallback ONLY
// on `.unrecognizedPhrase` / `.unsupportedLocale`. Every other rule-side
// error (`.invalidCron`, `.unavailable`, `.invalidJSON`, `.cancelled`)
// re-throws unchanged — those are operator-actionable verdicts and
// must NOT be hidden behind a silent fallback. MLX-side errors also
// re-throw unchanged so the operator sees clear messages ("no MLX
// model installed; pass --cron" / "model output unparseable" / "model
// emitted invalid cron").
//
// The selection seam was chosen at the 2026-05-28 operator interview
// (Q3 of the `phase-u8b-prose-compiler-adapter` decomposition): rule
// FIRST + MLX-on-fallback minimizes latency for the common case
// (deterministic phrases like "every weekday at 9am" hit in <1 ms)
// while still letting MLX handle irregular language ("every other
// Tuesday at 6pm") and non-English locales.
//
// Composes via `any ProseCadenceCompiler` for both arms so this type
// lives in Core with no MLX import — the CLI/App wiring picks the
// concrete arms at construction time.

public struct CompositeProseCadenceCompiler: ProseCadenceCompiler {
    private let rule: any ProseCadenceCompiler
    private let mlx: any ProseCadenceCompiler

    public init(rule: any ProseCadenceCompiler, mlx: any ProseCadenceCompiler) {
        self.rule = rule
        self.mlx = mlx
    }

    public func compile(prose: String, locale: String) async throws -> ProseCadence {
        do {
            return try await rule.compile(prose: prose, locale: locale)
        } catch let e as ProseCadenceCompilerError {
            switch e {
            case .unrecognizedPhrase, .unsupportedLocale:
                // Fall through to MLX. MLX-side errors propagate
                // unchanged so the operator sees the MLX verdict
                // (.unavailable / .invalidJSON / .invalidCron /
                // .cancelled / .unsupportedLocale).
                return try await mlx.compile(prose: prose, locale: locale)
            case .invalidCron, .unavailable, .invalidJSON, .cancelled:
                // Operator-actionable — re-throw unchanged. No
                // fall-through (a rule-side .invalidCron means the
                // rule emitted a malformed cron, NOT that MLX should
                // try; calling MLX here would mask a real bug).
                throw e
            }
        }
        // Any non-ProseCadenceCompilerError thrown by the rule arm
        // propagates unchanged (defense-in-depth — current taxonomy
        // is closed, but a future adapter might leak).
    }
}

// MARK: - RuleBasedProseCadenceCompiler
//
// Deterministic, MLX-free production compiler for `senkani schedule
// create --prose`. Maps a curated set of common ENGLISH cadence phrases
// to a 5-field cron string, then leans on `CronToLaunchd.convert` as the
// final validation gate. The compiler is pure + total: every input either
// maps to a valid cron or throws a clear `ProseCadenceCompilerError` —
// there is no silent fallback. The MLX-backed adapter that handles
// arbitrary natural language is a separate item (`phase-u8b-prose-
// compiler-adapter`); this compiler intentionally lives in Core with no
// MLX import so every Core client can compose with it.
//
// Supported phrases (case-insensitive, surplus whitespace ignored):
//   - "hourly"                       → 0 * * * *
//   - "daily"                        → 0 0 * * *
//   - "weekly"                       → 0 0 * * 0   (Sunday midnight)
//   - "every minute"                 → * * * * *
//   - "every hour"                   → 0 * * * *
//   - "every day"                    → 0 0 * * *
//   - "every N minutes"  (1 ≤ N ≤ 59) → */N * * * *
//   - "every N hours"    (1 ≤ N ≤ 23) → 0 */N * * *
//   - "every day at <time>"          → M H * * *
//   - "every weekday at <time>"      → M H * * 1,2,3,4,5  (Mon–Fri)
//   - "every <weekday> at <time>"    → M H * * <dow>      (Sun=0 … Sat=6)
//
// <time> accepts "9", "9am", "9:30", "9:30am", "14:00", "2pm", "noon
// forms are not special-cased". Weekday names accept full + common
// 3-letter abbreviations (mon, tue, …).
//
// NOTE: weekday sets use the comma form `1,2,3,4,5` — NOT the range form
// `1-5` — because `CronToLaunchd.convert` does not parse cron ranges
// (it handles `*`, `*/N`, comma-lists, and single ints only).

public struct RuleBasedProseCadenceCompiler: ProseCadenceCompiler {
    public init() {}

    public func compile(prose: String, locale: String) async throws -> ProseCadence {
        // Locale gate — English only.
        guard Self.isEnglish(locale) else {
            throw ProseCadenceCompilerError.unsupportedLocale(locale)
        }

        let phrase = prose
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !phrase.isEmpty, let cron = Self.cron(for: phrase) else {
            throw ProseCadenceCompilerError.unrecognizedPhrase(prose)
        }

        // Validation gate (defense-in-depth — cron(for:) only emits forms
        // that should already pass, but the contract demands convert() is
        // the authority).
        guard CronToLaunchd.convert(cron) != nil else {
            throw ProseCadenceCompilerError.invalidCron(cron)
        }
        return ProseCadence(prose: prose, locale: locale, cron: cron)
    }

    // MARK: Locale

    /// The BCP-47 / ICU language subtag is the text before the first
    /// `-` or `_`. Parsed manually rather than via `Locale` so that both
    /// `en-US` (hyphen, BCP-47) and `en_US` (underscore, ICU) resolve
    /// identically regardless of Foundation's normalization quirks.
    // Public so cross-module compilers (e.g. `MLXProseCadenceCompiler`
    // in the `MLXProseCompiler` target) can reuse the same parsing
    // rules and stay in lockstep with the rule-based path on
    // `en-US`/`en_US` equivalence. See parent
    // `phase-u8b-prose-compiler-adapter` acceptance bullet on locale
    // gate reuse.
    public static func languageCode(of locale: String) -> String {
        let lower = locale.lowercased()
        if let sep = lower.firstIndex(where: { $0 == "-" || $0 == "_" }) {
            return String(lower[..<sep])
        }
        return lower
    }

    public static func isEnglish(_ locale: String) -> Bool {
        languageCode(of: locale) == "en"
    }

    // MARK: Phrase → cron

    /// Map a normalized (lowercased, trimmed) phrase to a 5-field cron, or
    /// nil if unrecognized. Internal whitespace is collapsed to single
    /// spaces first.
    static func cron(for phrase: String) -> String? {
        let p = phrase.split(separator: " ").joined(separator: " ")

        switch p {
        case "hourly":       return "0 * * * *"
        case "daily":        return "0 0 * * *"
        case "weekly":       return "0 0 * * 0"
        case "every minute": return "* * * * *"
        case "every hour":   return "0 * * * *"
        case "every day":    return "0 0 * * *"
        default:             break
        }

        let tokens = p.split(separator: " ").map(String.init)

        // "every N minutes" / "every N hours"
        if tokens.count == 3, tokens[0] == "every", let n = Int(tokens[1]), n > 0 {
            switch tokens[2] {
            case "minute", "minutes":
                return (1...59).contains(n) ? "*/\(n) * * * *" : nil
            case "hour", "hours":
                return (1...23).contains(n) ? "0 */\(n) * * *" : nil
            default:
                return nil
            }
        }

        // "<subject> at <time>"
        if let atRange = p.range(of: " at ") {
            let subject = String(p[..<atRange.lowerBound])
            let timeStr = String(p[atRange.upperBound...])
            guard let (h, m) = parseTime(timeStr) else { return nil }

            switch subject {
            case "every day":
                return "\(m) \(h) * * *"
            case "every weekday":
                return "\(m) \(h) * * 1,2,3,4,5"
            default:
                guard subject.hasPrefix("every "),
                      let dow = weekday(String(subject.dropFirst("every ".count)))
                else { return nil }
                return "\(m) \(h) * * \(dow)"
            }
        }

        return nil
    }

    /// Parse "H", "H:MM", with optional "am"/"pm" suffix, into 24-hour
    /// (hour 0–23, minute 0–59). Returns nil on any out-of-range or
    /// malformed input.
    static func parseTime(_ raw: String) -> (hour: Int, minute: Int)? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        var meridiem: String?
        if s.hasSuffix("am") { meridiem = "am"; s = String(s.dropLast(2)) }
        else if s.hasSuffix("pm") { meridiem = "pm"; s = String(s.dropLast(2)) }
        s = s.trimmingCharacters(in: .whitespaces)

        let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
        guard let first = parts.first, var hour = Int(first) else { return nil }
        var minute = 0
        if parts.count == 2 {
            guard let m = Int(parts[1]) else { return nil }
            minute = m
        }

        if let mer = meridiem {
            guard (1...12).contains(hour) else { return nil }
            if mer == "am" {
                hour = (hour == 12) ? 0 : hour
            } else {
                hour = (hour == 12) ? 12 : hour + 12
            }
        }

        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    /// Map a weekday name (full or common abbreviation) to a cron weekday
    /// index (Sun=0 … Sat=6).
    static func weekday(_ name: String) -> Int? {
        switch name {
        case "sunday", "sun":                 return 0
        case "monday", "mon":                 return 1
        case "tuesday", "tue", "tues":        return 2
        case "wednesday", "wed":              return 3
        case "thursday", "thu", "thur", "thurs": return 4
        case "friday", "fri":                 return 5
        case "saturday", "sat":               return 6
        default:                              return nil
        }
    }
}
