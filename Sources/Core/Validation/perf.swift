import Foundation

/// A single assertion outcome from an axis evaluator. Ships in U.2a-2a as
/// the shared shape both `PerfAxis` and `CompletenessAxis` return; U.2b-axes
/// will add `SecurityAxis` + `DesignAxis` over the same shape.
///
/// `measured` and `threshold` are axis-specific (often nil for axes that
/// don't measure a scalar — e.g. `completeness.title_meta` is a binary
/// presence check). `advisory` carries human-readable remediation text on
/// fail; nil on pass.
public struct AssertionResult: Codable, Sendable, Equatable {
    public let assertionId: String
    public let passed: Bool
    public let measured: Int?
    public let threshold: Int?
    public let advisory: String?

    public init(
        assertionId: String,
        passed: Bool,
        measured: Int? = nil,
        threshold: Int? = nil,
        advisory: String? = nil
    ) {
        self.assertionId = assertionId
        self.passed = passed
        self.measured = measured
        self.threshold = threshold
        self.advisory = advisory
    }

    enum CodingKeys: String, CodingKey {
        case assertionId = "assertion_id"
        case passed
        case measured
        case threshold
        case advisory
    }
}

/// Browser-measured perf payload. The TS runner emits this shape into
/// `page.evaluate(...)` results; the Swift evaluator consumes it. Both
/// fields are optional because INP requires a qualifying interaction
/// event (often absent in a headless run) and LCP can be absent on pages
/// that never render a contentful element.
public struct PerfMeasurement: Codable, Sendable, Equatable {
    public let inpMs: Int?
    public let lcpMs: Int?

    public init(inpMs: Int? = nil, lcpMs: Int? = nil) {
        self.inpMs = inpMs
        self.lcpMs = lcpMs
    }

    enum CodingKeys: String, CodingKey {
        case inpMs = "inp_ms"
        case lcpMs = "lcp_ms"
    }
}

/// Caller-supplied threshold overrides. Decoded from `ValidationStep.expected`
/// (TEXT, JSON) when present; nil falls through to `PerfAxis.defaultInpMs`
/// and `PerfAxis.defaultLcpMs`.
public struct PerfExpected: Codable, Sendable, Equatable {
    public let inpMs: Int?
    public let lcpMs: Int?

    public init(inpMs: Int? = nil, lcpMs: Int? = nil) {
        self.inpMs = inpMs
        self.lcpMs = lcpMs
    }

    enum CodingKeys: String, CodingKey {
        case inpMs = "inp_ms"
        case lcpMs = "lcp_ms"
    }
}

/// Perf axis evaluator. Pure function over a `PerfMeasurement` payload and
/// optional `PerfExpected` thresholds. Returns one `AssertionResult` per
/// threshold (`perf.inp`, `perf.lcp`).
///
/// Default thresholds match Web Vitals "good" buckets:
///   - INP ≤ 200 ms (Interaction to Next Paint)
///   - LCP ≤ 2500 ms (Largest Contentful Paint)
///
/// When a measurement is nil:
///   - `inpMs == nil` → `perf.inp` passes with advisory "INP not measured"
///     (headless runs with no interaction events are common; not a fail).
///   - `lcpMs == nil` → `perf.lcp` fails with advisory "LCP not measured"
///     (a page that renders nothing contentful is a regression).
public enum PerfAxis {
    public static let defaultInpMs: Int = 200
    public static let defaultLcpMs: Int = 2500

    public static func evaluate(
        measurement: PerfMeasurement,
        expected: PerfExpected? = nil
    ) -> [AssertionResult] {
        let inpThreshold = expected?.inpMs ?? defaultInpMs
        let lcpThreshold = expected?.lcpMs ?? defaultLcpMs
        var results: [AssertionResult] = []

        if let inp = measurement.inpMs {
            let passed = inp <= inpThreshold
            results.append(AssertionResult(
                assertionId: "perf.inp",
                passed: passed,
                measured: inp,
                threshold: inpThreshold,
                advisory: passed
                    ? nil
                    : "INP \(inp)ms exceeds threshold \(inpThreshold)ms — Interaction to Next Paint should stay under threshold for a responsive feel."
            ))
        } else {
            results.append(AssertionResult(
                assertionId: "perf.inp",
                passed: true,
                measured: nil,
                threshold: inpThreshold,
                advisory: "INP not measured (no qualifying interaction events captured)"
            ))
        }

        if let lcp = measurement.lcpMs {
            let passed = lcp <= lcpThreshold
            results.append(AssertionResult(
                assertionId: "perf.lcp",
                passed: passed,
                measured: lcp,
                threshold: lcpThreshold,
                advisory: passed
                    ? nil
                    : "LCP \(lcp)ms exceeds threshold \(lcpThreshold)ms — Largest Contentful Paint should stay under threshold for good page experience."
            ))
        } else {
            results.append(AssertionResult(
                assertionId: "perf.lcp",
                passed: false,
                measured: nil,
                threshold: lcpThreshold,
                advisory: "LCP not measured — page may not have rendered any contentful element."
            ))
        }

        return results
    }
}
