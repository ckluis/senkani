import Testing
import Foundation
@testable import Core

/// U.2b-axes contract tests for `DesignAxis.evaluate`. Pure evaluator
/// over a `DesignMeasurement` payload. Three assertions:
///
///   - `design.target_size` — interactive bounding boxes ≥44×44 px (HIG).
///   - `design.hover_focus_contrast` — hover/focus state differs from
///     default contrast by ≥3.0 (WCAG AA-large). Soft-pass when no
///     target has a measured baseline (headless reality).
///   - `design.focus_order` — Tab walk sequence matches DOM order.
@Suite("DesignAxis — U.2b-axes evaluator")
struct DesignAxisTests {

    @Test("target_size: all pass default ≥44×44; fail when one undersized; override min_target_px")
    func targetSizeBranches() {
        // Branch 1 — all targets meet 44×44 default → pass.
        do {
            let m = DesignMeasurement(interactiveTargets: [
                .init(identifier: "a#cta", widthPx: 80, heightPx: 44),
                .init(identifier: "button#submit", widthPx: 120, heightPx: 50),
            ])
            let r = DesignAxis.evaluate(measurement: m)
            let s = r.first { $0.assertionId == "design.target_size" }
            #expect(s?.passed == true)
            #expect(s?.threshold == 44)
            #expect(s?.advisory == nil)
        }
        // Branch 2 — one undersized target → fail; advisory names it.
        do {
            let m = DesignMeasurement(interactiveTargets: [
                .init(identifier: "a#cta", widthPx: 80, heightPx: 44),
                .init(identifier: "a#tiny", widthPx: 30, heightPx: 30),
            ])
            let r = DesignAxis.evaluate(measurement: m)
            let s = r.first { $0.assertionId == "design.target_size" }
            #expect(s?.passed == false)
            #expect(s?.advisory?.contains("a#tiny") == true)
            #expect(s?.advisory?.contains("30×30") == true)
        }
        // Branch 3 — caller-provided min_target_px override (e.g. 64).
        do {
            let m = DesignMeasurement(interactiveTargets: [
                .init(identifier: "a#cta", widthPx: 50, heightPx: 50),
            ])
            let e = DesignExpected(minTargetPx: 64)
            let r = DesignAxis.evaluate(measurement: m, expected: e)
            let s = r.first { $0.assertionId == "design.target_size" }
            #expect(s?.passed == false)
            #expect(s?.threshold == 64)
            #expect(s?.advisory?.contains("under 64×64px") == true)
        }
    }

    @Test("hover_focus_contrast: soft-pass on missing measurements; fail when delta < 3.0; pass when delta ≥ 3.0")
    func hoverFocusContrastBranches() {
        // Branch 1 — no target has a measured baseline → soft-pass.
        do {
            let m = DesignMeasurement(interactiveTargets: [
                .init(identifier: "a#cta", widthPx: 80, heightPx: 44),
            ])
            let r = DesignAxis.evaluate(measurement: m)
            let s = r.first { $0.assertionId == "design.hover_focus_contrast" }
            #expect(s?.passed == true)
            #expect(s?.advisory?.contains("not measured") == true)
        }
        // Branch 2 — hover contrast delta < 3.0 → fail.
        do {
            let m = DesignMeasurement(interactiveTargets: [
                .init(identifier: "a#cta", widthPx: 80, heightPx: 44,
                      defaultContrastRatio: 4.5, hoverContrastRatio: 5.0, focusContrastRatio: nil),
            ])
            let r = DesignAxis.evaluate(measurement: m)
            let s = r.first { $0.assertionId == "design.hover_focus_contrast" }
            #expect(s?.passed == false)
            #expect(s?.advisory?.contains("a#cta") == true)
        }
        // Branch 3 — hover contrast delta ≥ 3.0 → pass.
        do {
            let m = DesignMeasurement(interactiveTargets: [
                .init(identifier: "a#cta", widthPx: 80, heightPx: 44,
                      defaultContrastRatio: 4.5, hoverContrastRatio: 8.0, focusContrastRatio: nil),
            ])
            let r = DesignAxis.evaluate(measurement: m)
            let s = r.first { $0.assertionId == "design.hover_focus_contrast" }
            #expect(s?.passed == true)
            #expect(s?.advisory == nil)
        }
        // Branch 4 — focus state delta < 3.0 even with hover passing → fail.
        do {
            let m = DesignMeasurement(interactiveTargets: [
                .init(identifier: "a#cta", widthPx: 80, heightPx: 44,
                      defaultContrastRatio: 4.5, hoverContrastRatio: 8.0, focusContrastRatio: 5.0),
            ])
            let r = DesignAxis.evaluate(measurement: m)
            let s = r.first { $0.assertionId == "design.hover_focus_contrast" }
            #expect(s?.passed == false)
        }
    }

    @Test("focus_order: pass when tab-walk matches DOM order; fail with divergence index in advisory")
    func focusOrderBranches() {
        // Branch 1 — tab walk matches DOM order → pass.
        do {
            let m = DesignMeasurement(
                interactiveTargets: [],
                domFocusOrder: ["#a", "#b", "#c"],
                tabFocusOrder: ["#a", "#b", "#c"]
            )
            let r = DesignAxis.evaluate(measurement: m)
            let s = r.first { $0.assertionId == "design.focus_order" }
            #expect(s?.passed == true)
            #expect(s?.advisory == nil)
        }
        // Branch 2 — diverges at index 1 → fail; advisory points there.
        do {
            let m = DesignMeasurement(
                interactiveTargets: [],
                domFocusOrder: ["#a", "#b", "#c", "#d"],
                tabFocusOrder: ["#a", "#c", "#b", "#d"]
            )
            let r = DesignAxis.evaluate(measurement: m)
            let s = r.first { $0.assertionId == "design.focus_order" }
            #expect(s?.passed == false)
            #expect(s?.advisory?.contains("index 1") == true)
            #expect(s?.advisory?.contains("#c") == true)
        }
        // Branch 3 — both sequences empty → trivially pass (no focusables).
        do {
            let m = DesignMeasurement(
                interactiveTargets: [],
                domFocusOrder: [], tabFocusOrder: []
            )
            let r = DesignAxis.evaluate(measurement: m)
            let s = r.first { $0.assertionId == "design.focus_order" }
            #expect(s?.passed == true)
            #expect(s?.advisory == nil)
        }
        // Branch 4 — tab walk is a proper prefix of DOM order (missed
        // tail) → fail; advisory points at the divergence index past
        // the prefix.
        do {
            let m = DesignMeasurement(
                interactiveTargets: [],
                domFocusOrder: ["#a", "#b", "#c"],
                tabFocusOrder: ["#a", "#b"]
            )
            let r = DesignAxis.evaluate(measurement: m)
            let s = r.first { $0.assertionId == "design.focus_order" }
            #expect(s?.passed == false)
            #expect(s?.advisory?.contains("index 2") == true)
        }
    }
}
