import Foundation

/// Parser + validation for `senkani monitor --tui --poll-interval=<dur>`.
///
/// Operator-locked design (2026-05-07 scope answers):
///   • Suffix grammar: `ms` / `s` / `m` / `h` (e.g. `500ms`, `1s`,
///     `5s`, `30s`, `5m`, `10m`). The numeric part may be an integer.
///   • Default `5s`.
///   • REJECT anything `< 1s` with the exact documented stderr message
///     and a non-zero exit. No upper bound.
///
/// Lives here (not buried in ArgumentParser glue) so tests can call
/// `PollInterval.parse(_:)` directly and assert the Duration + the
/// rejection message.
public enum PollInterval {
    /// The minimum allowed interval. Anything strictly below this is
    /// rejected — a sub-second poll would hammer the database.
    public static let minimum: Duration = .seconds(1)

    /// Default when `--poll-interval` is omitted.
    public static let `default`: Duration = .seconds(5)

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        /// The string did not match `<number><suffix>` with a known suffix.
        case malformed(input: String)
        /// Parsed fine but was below `minimum`.
        case tooSmall(input: String)

        public var description: String {
            switch self {
            case .malformed(let input):
                return "--poll-interval '\(input)' is not a valid duration; use a suffix of ms/s/m/h (e.g. 500ms, 1s, 5s, 30s, 5m, 10m)"
            case .tooSmall(let input):
                // Documented message — MUST contain the substring "≥ 1s".
                return "--poll-interval must be ≥ 1s; '\(input)' would hammer the DB"
            }
        }
    }

    /// Parse a duration string with a unit suffix. Returns the Duration
    /// on success; throws `ParseError` (whose `description` is the
    /// operator-facing message) otherwise.
    public static func parse(_ raw: String) throws -> Duration {
        let input = raw.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { throw ParseError.malformed(input: raw) }

        // Longest-suffix-first so "ms" is matched before "s".
        let suffixes: [(suffix: String, toDuration: (Double) -> Duration)] = [
            ("ms", { .milliseconds(Int64(($0).rounded())) }),
            ("s", { secondsDuration($0) }),
            ("m", { minutesDuration($0) }),
            ("h", { hoursDuration($0) }),
        ]

        for (suffix, toDuration) in suffixes where input.hasSuffix(suffix) {
            let numberPart = String(input.dropLast(suffix.count))
            guard !numberPart.isEmpty, let value = Double(numberPart), value >= 0 else {
                throw ParseError.malformed(input: raw)
            }
            let duration = toDuration(value)
            if duration < minimum {
                throw ParseError.tooSmall(input: raw)
            }
            return duration
        }

        throw ParseError.malformed(input: raw)
    }

    // MARK: - Duration builders (fractional-safe)

    private static func secondsDuration(_ v: Double) -> Duration {
        let millis = Int64((v * 1000).rounded())
        return .milliseconds(millis)
    }
    private static func minutesDuration(_ v: Double) -> Duration {
        let millis = Int64((v * 60_000).rounded())
        return .milliseconds(millis)
    }
    private static func hoursDuration(_ v: Double) -> Duration {
        let millis = Int64((v * 3_600_000).rounded())
        return .milliseconds(millis)
    }
}
