import Foundation

/// Curated user-facing LLM catalog for the Ollama-launcher pane.
///
/// Round `ollama-model-curation` (sub-item c of the
/// `ollama-pane-discovery-models-bundle` umbrella, 2026-04-20). This is
/// the surface inside the Ollama pane's settings drawer — strictly
/// separate from `ModelManager`, which owns senkani-internal ML
/// (minilm-l6 + gemma4). Two bounded contexts, two surfaces
/// (Evans' gate at umbrella time).
///
/// Scope rules (Schneier):
///   - Pull goes through the `ollama` CLI, never a direct HTTP call
///     to ollama's registry — this inherits ollama's signature checks
///     such as they are, and avoids re-implementing the pull path.
///   - Size is disclosed in the button copy BEFORE the click
///     (Podmajersky). Callers must render `pullButtonCopy`, not build
///     their own "Pull" label.
///   - No auto-pull on pane launch (Karpathy + Schneier). The curated
///     list exists as an opt-in surface, never a trigger.
public struct OllamaCuratedModel: Sendable, Equatable, Identifiable, Hashable {
    /// Exact `ollama pull` / `ollama run` target. MUST satisfy
    /// `OllamaLauncherSupport.isValidModelTag` so it can be interpolated
    /// into a shell command without further escaping.
    public let tag: String

    /// Human-readable name for UI headers ("Llama 3.1 8B").
    public let displayName: String

    /// One-line use-case note; kept under 40 characters so a horizontal
    /// row layout doesn't wrap (Handley).
    public let useCase: String

    /// On-disk size estimate in GB. Ollama's registry sizes drift over
    /// time as layers are re-published; these are ball-park values
    /// surfaced in the pull-button disclosure.
    public let sizeGB: Double

    public var id: String { tag }

    /// Podmajersky: button copy discloses the size BEFORE the pull
    /// click. One decimal place reads as an estimate rather than a
    /// precise claim.
    public var pullButtonCopy: String {
        "Pull \(sizeLabel)"
    }

    public var sizeLabel: String {
        String(format: "%.1f GB", sizeGB)
    }

    public init(
        tag: String,
        displayName: String,
        useCase: String,
        sizeGB: Double
    ) {
        self.tag = tag
        self.displayName = displayName
        self.useCase = useCase
        self.sizeGB = sizeGB
    }
}

public enum OllamaModelCatalog {

    /// The curated list this round ships. Order is display order.
    /// Karpathy draft; operator-confirmed at backlog-framing time.
    ///
    /// Changing this list is a product decision, not a refactor —
    /// the Ollama-launcher pane's default model is always the first
    /// entry (see `OllamaLauncherSupport.defaultModelTag`).
    public static let curated: [OllamaCuratedModel] = [
        .init(tag: "llama3.1:8b",
              displayName: "Llama 3.1 8B",
              useCase: "General-purpose fallback",
              sizeGB: 4.7),
        .init(tag: "qwen2.5-coder:7b",
              displayName: "Qwen2.5 Coder 7B",
              useCase: "Code assistant",
              sizeGB: 4.4),
        .init(tag: "deepseek-r1:7b",
              displayName: "DeepSeek-R1 7B",
              useCase: "Reasoning",
              sizeGB: 4.7),
        .init(tag: "mistral:7b",
              displayName: "Mistral 7B",
              useCase: "General fast",
              sizeGB: 4.1),
        .init(tag: "gemma2:2b",
              displayName: "Gemma 2 2B",
              useCase: "Smallest viable default",
              sizeGB: 1.6),
    ]

    /// Convenience projection used by legacy call sites that only need
    /// the tags (the pre-curation default-selector list).
    public static var curatedTags: [String] { curated.map(\.tag) }

    /// Look up a curated entry by tag. Returns nil when the tag isn't
    /// curated — callers should handle the nil rather than synthesize
    /// a row (a custom tag path is FUTURE work).
    public static func entry(for tag: String) -> OllamaCuratedModel? {
        curated.first { $0.tag == tag }
    }
}

// MARK: - Pull state machine

/// Per-model status as seen by the drawer UI.
///
/// Transitions:
///   notPulled      → pulling(0)    on pull click
///   pulling(x)     → pulling(y)    as progress streams (y ≥ x)
///   pulling(_)     → pulled        on `ollama pull` → "success"
///   pulling(_)     → failed(msg)   on parse error / non-zero exit /
///                                  user cancel (cancel surfaces as
///                                  `.failed("Cancelled")` so the UI
///                                  can restore the pull button)
///   pulled         → notPulled     on user delete (future)
///
/// State never goes backwards through pulling → notPulled except via
/// the explicit cancel/failure path — the UI relies on that invariant.
public enum OllamaPullState: Equatable, Sendable {
    case notPulled
    case pulling(progress: Double)
    case pulled(digest: String?)
    case failed(String)

    public var isTerminal: Bool {
        switch self {
        case .pulled, .failed, .notPulled: return true
        case .pulling: return false
        }
    }

    public var isInFlight: Bool {
        if case .pulling = self { return true }
        return false
    }
}

// MARK: - Pull output parser

/// Parsed event from a single line of `ollama pull` stdout/stderr.
/// See `OllamaPullOutputParser` for canonical output fixtures.
public enum OllamaPullEvent: Equatable, Sendable {
    /// `pulling manifest` — the initial hand-shake line.
    case manifestStart
    /// `pulling <digest>... NN% ▕…▏ NN MB` — per-layer progress line.
    /// `percent` is the 0…100 integer Ollama reports (widened to Double
    /// for progress aggregation).
    case layerProgress(digest: String, percent: Double)
    /// `verifying sha256 digest`
    case verifying
    /// `writing manifest`
    case writing
    /// `success` — terminal.
    case success
    /// `Error: …` — terminal (usually preceded by nothing useful).
    case error(String)
    /// Any line that doesn't match the above. Not surfaced to UI;
    /// exists so tests can pin non-crashing behavior on junk input.
    case unknown
}

/// Incremental parser for `ollama pull` output. Call `feed(_:)` per
/// line received from the subprocess; read `state` at any time for the
/// aggregated view.
///
/// Ollama's stream uses carriage returns to redraw the same line at
/// each percent tick — callers should split on both `\n` and `\r`
/// before feeding, so this parser never sees a partial line.
public struct OllamaPullOutputParser: Sendable {

    public private(set) var maxPercent: Double = 0
    public private(set) var layerDigest: String?
    public private(set) var manifestVerified: Bool = false
    public private(set) var didSucceed: Bool = false
    public private(set) var errorMessage: String?

    public init() {}

    public var state: OllamaPullState {
        if let errorMessage { return .failed(errorMessage) }
        if didSucceed { return .pulled(digest: layerDigest) }
        if maxPercent > 0 || manifestVerified {
            return .pulling(progress: progressFraction)
        }
        return .notPulled
    }

    /// 0.0…1.0 aggregate progress. Layer percent is the dominant
    /// signal; verifying/writing bump to 100% only after success lands.
    public var progressFraction: Double {
        max(0, min(1, maxPercent / 100.0))
    }

    @discardableResult
    public mutating func feed(_ rawLine: String) -> OllamaPullEvent {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return .unknown }

        // Error path — surfaces before anything else so a mid-stream
        // failure beats a prior progress frame.
        let lower = line.lowercased()
        if lower.hasPrefix("error") || lower.hasPrefix("error:") {
            errorMessage = line
            return .error(line)
        }

        if line == "success" {
            didSucceed = true
            // Reaching success implies 100% even if we missed the tail
            // progress frame.
            maxPercent = max(maxPercent, 100)
            return .success
        }

        if line.hasPrefix("pulling manifest") {
            return .manifestStart
        }

        if line.hasPrefix("verifying") {
            manifestVerified = true
            return .verifying
        }

        if line.hasPrefix("writing") {
            return .writing
        }

        if line.hasPrefix("pulling "),
           let percent = Self.extractPercent(line) {
            let digest = Self.extractLayerDigest(line)
            if layerDigest == nil, let digest, !digest.isEmpty {
                layerDigest = digest
            }
            if percent >= maxPercent {
                maxPercent = percent
            }
            return .layerProgress(digest: digest ?? "", percent: percent)
        }

        return .unknown
    }

    /// Extract the integer percent from a progress line. Tolerates the
    /// fancy unicode progress bar Ollama prints between the percent and
    /// the size.
    static func extractPercent(_ line: String) -> Double? {
        // Look for " NN%" or "  N%" or "NNN%" (100%).
        guard let pctIdx = line.firstIndex(of: "%") else { return nil }
        var digits: [Character] = []
        var i = line.index(before: pctIdx)
        while i >= line.startIndex, line[i].isWhitespace {
            if i == line.startIndex { return nil }
            i = line.index(before: i)
        }
        while line[i].isNumber {
            digits.insert(line[i], at: 0)
            if i == line.startIndex { break }
            i = line.index(before: i)
        }
        guard !digits.isEmpty, let value = Double(String(digits)) else {
            return nil
        }
        return value
    }

    /// Extract the layer digest token after `pulling `. Ollama prints
    /// a short hash followed by `...`. Returns nil for `pulling manifest`.
    static func extractLayerDigest(_ line: String) -> String? {
        guard line.hasPrefix("pulling ") else { return nil }
        let rest = line.dropFirst("pulling ".count)
        // Cut at the first whitespace OR the `...` ollama appends.
        var token = ""
        for ch in rest {
            if ch.isWhitespace { break }
            if ch == "." { break }
            token.append(ch)
        }
        if token == "manifest" { return nil }
        let hex = Set("0123456789abcdefABCDEF")
        guard !token.isEmpty, token.allSatisfy({ hex.contains($0) }) else {
            return nil
        }
        return token
    }
}

// MARK: - Pull command builder

/// Builds the `ollama` CLI argv for a pull of the given tag. The Process
/// spawn itself lives in the app-target controller — Core stays free of
/// subprocess state so it remains pure-Foundation-testable.
public enum OllamaPullCommand {

    /// The binary we invoke. Deliberately not absolute — we let the
    /// user's PATH resolve it (ollama installs differently on Apple
    /// Silicon / Intel / Homebrew / direct DMG). The controller looks
    /// the path up via `which` before spawn.
    public static let binaryName: String = "ollama"

    public static func arguments(forPullingTag tag: String) -> [String]? {
        guard OllamaLauncherSupport.isValidModelTag(tag) else { return nil }
        return ["pull", tag]
    }

    public static func arguments(forListingInstalled: Void = ()) -> [String] {
        ["list"]
    }
}

// MARK: - ollama list parser

/// Parses `ollama list` tabular output into (tag, digest) pairs.
///
/// Example output (4-column, whitespace-aligned):
/// ```
/// NAME                    ID              SIZE      MODIFIED
/// llama3.1:8b             46e0c10c039e    4.9 GB    2 days ago
/// qwen2.5-coder:7b        2b0496514337    4.7 GB    3 days ago
/// ```
///
/// Usage: Seed the drawer's "installed" state on pane open, and refresh
/// after a pull completes so the digest surfaces to the UI.
public enum OllamaInstalledListParser {

    public struct Entry: Equatable, Sendable {
        public let tag: String
        public let digest: String
    }

    public static func parse(_ output: String) -> [Entry] {
        var results: [Entry] = []
        for rawLine in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("NAME") || line.hasPrefix("name") { continue }
            // First whitespace-separated token is tag, second is digest.
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
                .filter { !$0.isEmpty }
            guard fields.count >= 2 else { continue }
            let tag = fields[0]
            let digest = fields[1]
            guard OllamaLauncherSupport.isValidModelTag(tag) else { continue }
            // Digest must look like a short hash (hex, ≥8 chars).
            let hex = Set("0123456789abcdefABCDEF")
            guard digest.count >= 8, digest.allSatisfy({ hex.contains($0) }) else {
                continue
            }
            results.append(.init(tag: tag, digest: digest))
        }
        return results
    }

    public static func installedTags(_ output: String) -> Set<String> {
        Set(parse(output).map(\.tag))
    }
}
