import Foundation

/// Soft-flag fragmentation detector — Phase U.4a round 1.
///
/// Watches a sliding window of HookRouter events keyed on
/// `(sessionId, paneId)` and emits `FragmentationFlag`s when a
/// suspicious cross-input correlation pattern is observed. The
/// detector is **non-blocking by design**: it never returns a deny
/// signal. Callers decide whether to persist the flag, surface it in
/// the UI, or feed it into `TrustScorer`. Promotion-to-blocking is
/// the U.4b round, gated on operator-collected FP labels.
///
/// Concurrency: NSLock-guarded. Safe to call from any thread; the
/// hot path is two array mutations + an O(window) scan that costs
/// well under 100 µs at the windows we use.
public final class FragmentationDetector: @unchecked Sendable {

    /// One observed event from `HookRouter`. `fragment` is an optional
    /// short snippet of the prompt or tool input — used for stitch
    /// detection. Pass `nil` if the event has no usable fragment.
    public struct Observation: Sendable, Equatable {
        public let timestamp: Date
        public let sessionId: String
        public let paneId: String?
        public let toolName: String
        public let fragment: String?

        public init(
            timestamp: Date = Date(),
            sessionId: String,
            paneId: String? = nil,
            toolName: String,
            fragment: String? = nil
        ) {
            self.timestamp = timestamp
            self.sessionId = sessionId
            self.paneId = paneId
            self.toolName = toolName
            self.fragment = fragment
        }
    }

    /// One emitted soft flag. Persisted in `trust_audits` (kind=flag).
    public struct Flag: Sendable, Equatable {
        public let createdAt: Date
        public let sessionId: String
        public let paneId: String?
        public let toolName: String
        public let reason: Reason
        /// Number of correlated events that triggered the flag.
        public let correlationCount: Int

        public init(
            createdAt: Date,
            sessionId: String,
            paneId: String?,
            toolName: String,
            reason: Reason,
            correlationCount: Int
        ) {
            self.createdAt = createdAt
            self.sessionId = sessionId
            self.paneId = paneId
            self.toolName = toolName
            self.reason = reason
            self.correlationCount = correlationCount
        }
    }

    /// Why the detector flagged. Persisted by `rawValue` — renaming a
    /// case is a schema break.
    public enum Reason: String, Sendable, Equatable, CaseIterable {
        /// ≥`burstThreshold` events of the same `toolName` in the same
        /// session inside `burstWindow`. Suggests fragmented retry /
        /// scattered control flow that could be coalesced.
        case toolBurst = "tool_burst"
        /// One observation's `fragment` is a substring (or superstring)
        /// of another observation in the same session inside
        /// `stitchWindow`. Suggests a multi-step prompt being
        /// reassembled across tool calls.
        case fragmentStitch = "fragment_stitch"
        /// Same `toolName` fires in two different panes inside the same
        /// session inside `crossPaneWindow`. Suggests a session
        /// straddling panes — a known compound-learning anti-pattern.
        case crossPane = "cross_pane"
    }

    /// Tunables. Defaults match the U.4a roadmap and are deliberately
    /// conservative — too-noisy detectors poison the FP/TP labelling
    /// pool and make the U.4b promotion gate impossible to evaluate.
    public struct Config: Sendable, Equatable {
        public var burstThreshold: Int
        public var burstWindow: TimeInterval
        public var stitchWindow: TimeInterval
        public var stitchMinFragmentLength: Int
        public var crossPaneWindow: TimeInterval
        /// Hard cap on stored observations per session — prevents
        /// long-lived sessions from accumulating an unbounded buffer.
        public var maxBufferPerSession: Int

        public init(
            burstThreshold: Int = 3,
            burstWindow: TimeInterval = 10,
            stitchWindow: TimeInterval = 30,
            stitchMinFragmentLength: Int = 12,
            crossPaneWindow: TimeInterval = 30,
            maxBufferPerSession: Int = 64
        ) {
            self.burstThreshold = burstThreshold
            self.burstWindow = burstWindow
            self.stitchWindow = stitchWindow
            self.stitchMinFragmentLength = stitchMinFragmentLength
            self.crossPaneWindow = crossPaneWindow
            self.maxBufferPerSession = maxBufferPerSession
        }

        public static let `default` = Config()
    }

    private let lock = NSLock()
    private var buffers: [String: [Observation]] = [:]
    private var config: Config

    public init(config: Config = .default) {
        self.config = config
    }

    /// Replace the runtime config — used by tests + future operator
    /// tuning. Buffers are NOT cleared; the new thresholds apply to
    /// subsequent `record` calls.
    public func updateConfig(_ config: Config) {
        lock.lock(); defer { lock.unlock() }
        self.config = config
    }

    /// Drop all buffered observations. Tests use this between cases.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        buffers.removeAll()
    }

    /// Record an observation and return any flags it triggered. The
    /// detector is purely additive — every observation is buffered,
    /// even ones that fire flags.
    @discardableResult
    public func record(_ obs: Observation) -> [Flag] {
        lock.lock(); defer { lock.unlock() }
        var buf = buffers[obs.sessionId, default: []]
        buf.append(obs)
        // Prune by oldest-first up to the per-session cap.
        if buf.count > config.maxBufferPerSession {
            buf.removeFirst(buf.count - config.maxBufferPerSession)
        }
        // Also prune anything older than the longest window we care
        // about — stitch window is the widest by default.
        let oldestRelevant = obs.timestamp.addingTimeInterval(
            -max(config.burstWindow, max(config.stitchWindow, config.crossPaneWindow))
        )
        buf.removeAll { $0.timestamp < oldestRelevant }
        buffers[obs.sessionId] = buf

        var flags: [Flag] = []

        // 1. Tool burst.
        let burstSlice = buf.filter {
            $0.toolName == obs.toolName &&
            obs.timestamp.timeIntervalSince($0.timestamp) <= config.burstWindow
        }
        if burstSlice.count >= config.burstThreshold {
            flags.append(Flag(
                createdAt: obs.timestamp,
                sessionId: obs.sessionId,
                paneId: obs.paneId,
                toolName: obs.toolName,
                reason: .toolBurst,
                correlationCount: burstSlice.count
            ))
        }

        // 2. Fragment stitch.
        if let frag = obs.fragment, frag.count >= config.stitchMinFragmentLength {
            let stitchHit = buf.contains { other in
                guard other != obs else { return false }
                guard let otherFrag = other.fragment,
                      otherFrag.count >= config.stitchMinFragmentLength else { return false }
                guard obs.timestamp.timeIntervalSince(other.timestamp) <= config.stitchWindow else { return false }
                return frag.contains(otherFrag) || otherFrag.contains(frag)
            }
            if stitchHit {
                flags.append(Flag(
                    createdAt: obs.timestamp,
                    sessionId: obs.sessionId,
                    paneId: obs.paneId,
                    toolName: obs.toolName,
                    reason: .fragmentStitch,
                    correlationCount: 2
                ))
            }
        }

        // 3. Cross-pane.
        if let pid = obs.paneId {
            let otherPane = buf.first { other in
                guard other != obs else { return false }
                guard let otherPid = other.paneId, otherPid != pid else { return false }
                guard other.toolName == obs.toolName else { return false }
                return obs.timestamp.timeIntervalSince(other.timestamp) <= config.crossPaneWindow
            }
            if otherPane != nil {
                flags.append(Flag(
                    createdAt: obs.timestamp,
                    sessionId: obs.sessionId,
                    paneId: obs.paneId,
                    toolName: obs.toolName,
                    reason: .crossPane,
                    correlationCount: 2
                ))
            }
        }

        return flags
    }

    /// Snapshot the current buffer for a session — diagnostics + tests.
    public func bufferSnapshot(sessionId: String) -> [Observation] {
        lock.lock(); defer { lock.unlock() }
        return buffers[sessionId] ?? []
    }
}
