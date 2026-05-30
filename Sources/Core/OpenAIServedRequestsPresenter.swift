import Foundation

/// Pure presentation logic for the served-requests pane
/// (`SenkaniApp/Views/OpenAIServedRequestsPane.swift`, V.13 GUI a-1).
///
/// Lives in Core — NOT in the SenkaniApp executable target — so it is
/// `@testable import`-able from `SenkaniTests`. The SwiftUI `View` itself
/// cannot be imported into the test target (executable targets are not
/// importable), so every behavioral assertion the acceptance needs (status
/// → color category, relative-age formatting, raw `model_logged`
/// pass-through, NULL tolerance) is exercised here; the view is a thin
/// shell that maps `StatusCategory` → a concrete SwiftUI `Color` and is
/// covered by a `#filePath` source guard.
///
/// **Privacy.** `modelLogged` is rendered RAW. The producer
/// (`OpenAIServedRequestSink`) already sanitized it at the trust boundary
/// (regex → `<malformed>`) and refusal rows persist the literal
/// `<refused>`. The consumer trusts the bounded persisted value
/// (Schneier — sanitize once, at the boundary). The presenter therefore
/// performs NO transformation of `modelLogged` beyond a nil placeholder.
public enum OpenAIServedRequestsPresenter {

    /// Semantic status bucket. A Core-side enum (not a SwiftUI `Color`) so
    /// it is testable without importing SwiftUI; the view maps it to the
    /// `AgentTimelinePane` palette verbatim (ok → savingsGreen, warn →
    /// orange, error → red, neutral → textTertiary).
    public enum StatusCategory: String, Sendable, Equatable {
        case ok       // 2xx
        case warn     // 429 (rate-limited / backpressure)
        case error    // any other 4xx / 5xx
        case neutral  // unknown / out-of-range / informational
    }

    /// Placeholder rendered for a NULL / absent column so a cell is never
    /// blank (refusal rows carry NULL token counts + tier).
    public static let nullPlaceholder = "—"

    /// HTTP status → semantic bucket. 429 is its own `warn` bucket
    /// (operator decision 2026-05-30): rate-limit backpressure is not the
    /// same signal as a hard 4xx/5xx error.
    public static func statusCategory(_ status: Int) -> StatusCategory {
        switch status {
        case 200...299: return .ok
        case 429:       return .warn
        case 400...599: return .error
        default:        return .neutral
        }
    }

    /// Relative age, mirroring `AgentTimelinePane.timeLabel` verbatim
    /// (operator decision 2026-05-30): `<60s` → `Ns`, `<1h` → `Nm`,
    /// else absolute `HH:mm:ss`. `now` is injectable for deterministic
    /// tests.
    public static func relativeAge(_ ts: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(ts)
        if interval < 60 { return "\(Int(interval))s" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: ts)
    }

    /// Surface token shown in the row. Empty → `other` (defensive; the
    /// store always writes a non-empty `Surface.rawValue`).
    public static func surfaceLabel(_ surface: String) -> String {
        surface.isEmpty ? "other" : surface
    }

    /// `model_logged` rendered RAW (already sanitized upstream). nil →
    /// placeholder. Literal `<malformed>` / `<refused>` pass through
    /// unchanged — no special UI treatment (acceptance bullets 3 + 4).
    public static func modelDisplay(_ modelLogged: String?) -> String {
        modelLogged ?? nullPlaceholder
    }

    /// `resolvedTier` with nil tolerance (refusals carry no routing tier).
    public static func tierDisplay(_ tier: String?) -> String {
        tier ?? nullPlaceholder
    }

    /// `keyLabel` with nil tolerance.
    public static func keyLabelDisplay(_ keyLabel: String?) -> String {
        keyLabel ?? nullPlaceholder
    }

    /// `input/output` token counts, each nil-tolerant (refusals carry
    /// NULL counts).
    public static func tokensDisplay(input: Int?, output: Int?) -> String {
        let i = input.map(String.init) ?? nullPlaceholder
        let o = output.map(String.init) ?? nullPlaceholder
        return "\(i)/\(o)"
    }

    /// Fully-rendered, view-agnostic row fields. The SwiftUI view binds
    /// these strings + the `statusCategory` directly; tests assert on them
    /// without constructing any SwiftUI types.
    public struct Fields: Sendable, Equatable {
        public let id: Int64
        public let age: String
        public let surface: String
        public let model: String
        public let tier: String
        public let tokens: String
        public let keyLabel: String
        public let status: Int
        public let statusCategory: StatusCategory

        public init(
            id: Int64, age: String, surface: String, model: String,
            tier: String, tokens: String, keyLabel: String,
            status: Int, statusCategory: StatusCategory
        ) {
            self.id = id; self.age = age; self.surface = surface
            self.model = model; self.tier = tier; self.tokens = tokens
            self.keyLabel = keyLabel; self.status = status
            self.statusCategory = statusCategory
        }
    }

    /// Build display fields from a persisted row. `now` injectable for
    /// deterministic age assertions.
    public static func fields(for row: OpenAIRequestLogStore.Row, now: Date = Date()) -> Fields {
        Fields(
            id: row.id,
            age: relativeAge(row.ts, now: now),
            surface: surfaceLabel(row.surface),
            model: modelDisplay(row.modelLogged),
            tier: tierDisplay(row.resolvedTier),
            tokens: tokensDisplay(input: row.inputTokens, output: row.outputTokens),
            keyLabel: keyLabelDisplay(row.keyLabel),
            status: row.status,
            statusCategory: statusCategory(row.status)
        )
    }
}
