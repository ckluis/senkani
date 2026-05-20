import Foundation

/// Browser-measured design payload. The TS runner walks interactive
/// targets in `page.evaluate(...)`, captures computed styles, and
/// simulates a Tab walk to record focus order; the Swift evaluator
/// consumes the resulting shape. U.2b-axes ships the Swift evaluator
/// + measurement types; full TS-side measurement is tracked under the
/// mandatory-follow-up item filed at U.2b-axes close.
public struct DesignMeasurement: Codable, Sendable, Equatable {
    /// Every interactive element on the page (anchors, buttons,
    /// `role="button"`).
    public let interactiveTargets: [InteractiveTarget]
    /// DOM order of focusable elements (every focusable element in
    /// document order). The Tab-walk sequence asserted to match this.
    public let domFocusOrder: [String]
    /// Tab-walk capture: `document.activeElement` (or its stable id)
    /// after each Tab press, in order. Compared against `domFocusOrder`.
    public let tabFocusOrder: [String]

    public init(
        interactiveTargets: [InteractiveTarget] = [],
        domFocusOrder: [String] = [],
        tabFocusOrder: [String] = []
    ) {
        self.interactiveTargets = interactiveTargets
        self.domFocusOrder = domFocusOrder
        self.tabFocusOrder = tabFocusOrder
    }

    /// One interactive target. `identifier` is a stable id the TS-side
    /// produces (e.g. `"a#main-cta"` / `"button[type=submit]@3"`).
    /// `widthPx` / `heightPx` are bounding-box dimensions in CSS
    /// pixels; the evaluator compares against the HIG ≥44×44 pt
    /// baseline (1 CSS pixel ≈ 1 pt at default DPR for evaluation
    /// purposes). `defaultContrastRatio` / `hoverContrastRatio` /
    /// `focusContrastRatio` are WCAG-style contrast ratios computed
    /// TS-side; the evaluator asserts the hover / focus state differs
    /// from default by at least the configured delta.
    public struct InteractiveTarget: Codable, Sendable, Equatable {
        public let identifier: String
        public let widthPx: Int
        public let heightPx: Int
        public let defaultContrastRatio: Double?
        public let hoverContrastRatio: Double?
        public let focusContrastRatio: Double?

        public init(
            identifier: String,
            widthPx: Int,
            heightPx: Int,
            defaultContrastRatio: Double? = nil,
            hoverContrastRatio: Double? = nil,
            focusContrastRatio: Double? = nil
        ) {
            self.identifier = identifier
            self.widthPx = widthPx
            self.heightPx = heightPx
            self.defaultContrastRatio = defaultContrastRatio
            self.hoverContrastRatio = hoverContrastRatio
            self.focusContrastRatio = focusContrastRatio
        }

        enum CodingKeys: String, CodingKey {
            case identifier
            case widthPx = "width_px"
            case heightPx = "height_px"
            case defaultContrastRatio = "default_contrast_ratio"
            case hoverContrastRatio = "hover_contrast_ratio"
            case focusContrastRatio = "focus_contrast_ratio"
        }
    }

    enum CodingKeys: String, CodingKey {
        case interactiveTargets = "interactive_targets"
        case domFocusOrder = "dom_focus_order"
        case tabFocusOrder = "tab_focus_order"
    }
}

/// Caller-supplied overrides for design assertions. Decoded from
/// `ValidationStep.expected` (TEXT, JSON) when present.
public struct DesignExpected: Codable, Sendable, Equatable {
    /// Minimum interactive-target dimension in CSS pixels. Default 44
    /// (Apple HIG baseline; WCAG SC 2.5.5 minimum-44 also matches).
    public let minTargetPx: Int?
    /// Minimum delta between hover/focus state contrast ratio and the
    /// default state's contrast ratio. WCAG SC 1.4.11 (Non-text
    /// Contrast) targets 3:1 — when the *default* state is itself at
    /// 3:1 the hover/focus state must be visually distinguishable.
    /// Default 3 (WCAG AA-large baseline).
    public let minContrastDelta: Double?

    public init(minTargetPx: Int? = nil, minContrastDelta: Double? = nil) {
        self.minTargetPx = minTargetPx
        self.minContrastDelta = minContrastDelta
    }

    enum CodingKeys: String, CodingKey {
        case minTargetPx = "min_target_px"
        case minContrastDelta = "min_contrast_delta"
    }
}

/// Design axis evaluator. Pure function over a `DesignMeasurement`
/// payload. Returns three `AssertionResult` rows:
///
///   - `design.target_size` — every interactive target's bounding-box
///     is at least `min_target_px` × `min_target_px` (HIG ≥44×44 pt).
///   - `design.hover_focus_contrast` — for every interactive target
///     with a measured default + hover or default + focus contrast
///     ratio, the hover/focus ratio differs from default by at least
///     `min_contrast_delta` (WCAG AA-large baseline). Targets missing
///     measurements soft-pass with an informational advisory (same
///     pattern as `perf.inp` headless soft-pass).
///   - `design.focus_order` — the Tab-walk sequence
///     (`tab_focus_order`) matches the DOM natural-order sequence
///     (`dom_focus_order`) element-for-element.
public enum DesignAxis {
    public static let defaultMinTargetPx: Int = 44
    public static let defaultMinContrastDelta: Double = 3.0

    public static func evaluate(
        measurement: DesignMeasurement,
        expected: DesignExpected? = nil
    ) -> [AssertionResult] {
        let minTarget = expected?.minTargetPx ?? defaultMinTargetPx
        let minDelta = expected?.minContrastDelta ?? defaultMinContrastDelta
        var results: [AssertionResult] = []

        // 1) Target-size ≥ minTarget × minTarget
        let undersized = measurement.interactiveTargets.filter { t in
            t.widthPx < minTarget || t.heightPx < minTarget
        }
        let sizePass = undersized.isEmpty
        let sizeAdvisory: String?
        if sizePass {
            sizeAdvisory = nil
        } else {
            let preview = undersized.prefix(5).map { t in
                "\(t.identifier) (\(t.widthPx)×\(t.heightPx)px)"
            }.joined(separator: ", ")
            sizeAdvisory = "\(undersized.count) interactive target(s) under \(minTarget)×\(minTarget)px: \(preview)"
        }
        results.append(AssertionResult(
            assertionId: "design.target_size",
            passed: sizePass,
            measured: measurement.interactiveTargets.count,
            threshold: minTarget,
            advisory: sizeAdvisory
        ))

        // 2) Hover/focus contrast delta ≥ minDelta — soft-pass when
        //    measurement is absent (headless reality: hover/focus
        //    states often unmeasurable without real pointer/keyboard
        //    events; missing-measurement isn't a regression).
        let measuredTargets = measurement.interactiveTargets.filter { $0.defaultContrastRatio != nil }
        let contrastFailures = measuredTargets.filter { t in
            guard let baseline = t.defaultContrastRatio else { return false }
            if let hover = t.hoverContrastRatio, abs(hover - baseline) < minDelta {
                return true
            }
            if let focus = t.focusContrastRatio, abs(focus - baseline) < minDelta {
                return true
            }
            return false
        }
        let contrastPass = contrastFailures.isEmpty
        let contrastAdvisory: String?
        if measuredTargets.isEmpty {
            contrastAdvisory = "hover/focus contrast not measured for any target — headless run with no synthetic pointer/keyboard events"
        } else if contrastPass {
            contrastAdvisory = nil
        } else {
            let preview = contrastFailures.prefix(5).map { t in
                let h = t.hoverContrastRatio.map { String(format: "%.2f", $0) } ?? "n/a"
                let f = t.focusContrastRatio.map { String(format: "%.2f", $0) } ?? "n/a"
                let d = t.defaultContrastRatio.map { String(format: "%.2f", $0) } ?? "n/a"
                return "\(t.identifier) (default=\(d) hover=\(h) focus=\(f))"
            }.joined(separator: ", ")
            contrastAdvisory = "\(contrastFailures.count) target(s) with hover/focus contrast delta < \(minDelta): \(preview)"
        }
        results.append(AssertionResult(
            assertionId: "design.hover_focus_contrast",
            passed: contrastPass,
            measured: measuredTargets.count,
            threshold: Int(minDelta),
            advisory: contrastAdvisory
        ))

        // 3) Focus-order matches DOM order
        let focusPass = measurement.tabFocusOrder == measurement.domFocusOrder
        let focusAdvisory: String?
        if focusPass {
            focusAdvisory = nil
        } else if measurement.tabFocusOrder.isEmpty && measurement.domFocusOrder.isEmpty {
            // Both empty — no focusable elements on the page (rare but
            // valid; passes by definition).
            focusAdvisory = nil
        } else {
            // Show the first divergence point to help debugging without
            // dumping the full DOM (Schneier side-channel guard).
            var divergeIdx = -1
            let len = min(measurement.tabFocusOrder.count, measurement.domFocusOrder.count)
            for i in 0..<len where measurement.tabFocusOrder[i] != measurement.domFocusOrder[i] {
                divergeIdx = i
                break
            }
            if divergeIdx == -1 {
                divergeIdx = len  // one sequence is a prefix of the other
            }
            let tabSample = measurement.tabFocusOrder.dropFirst(divergeIdx).prefix(3).joined(separator: " → ")
            let domSample = measurement.domFocusOrder.dropFirst(divergeIdx).prefix(3).joined(separator: " → ")
            focusAdvisory = "focus order diverges from DOM order at index \(divergeIdx); tab-walk continues with [\(tabSample)], dom-order continues with [\(domSample)]"
        }
        results.append(AssertionResult(
            assertionId: "design.focus_order",
            passed: focusPass,
            measured: measurement.tabFocusOrder.count,
            threshold: measurement.domFocusOrder.count,
            advisory: focusAdvisory
        ))

        return results
    }
}
