// Design-axis measurement body (phase1) — extracted from runner.ts
// measureDesign during U.2b-1b-3 so child U.2b-1b-4 can load the
// same byte sequence via Swift's WKWebView.evaluateJavaScript. Do not
// edit in isolation — runner.ts loads this file at module init.
//
// IIFE expression form: page.evaluate(STRING) returns
// { interactive_targets, dom_focus_order } directly. The Tab-walk
// loop that populates `tab_focus_order` is auxiliary to this body
// and remains inline in runner.ts — it uses playwright's
// page.keyboard.press("Tab") which has no WKWebView counterpart and
// is not part of the byte-shared measurement surface.
//
// Hover-state contrast is left null — synthesizing the CSS :hover
// pseudo-class requires real pointer events that a headless run
// inside page.evaluate cannot reach. The Swift DesignAxis evaluator's
// soft-pass branch handles null hover/focus measurements.
(() => {
    const FOCUSABLE_SELECTOR = ":is(a[href], button, input, select, textarea, [tabindex]):not([tabindex='-1'])";

    function parseColor(c) {
        const m = c.match(/rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)/);
        if (!m) return null;
        return [parseFloat(m[1]), parseFloat(m[2]), parseFloat(m[3])];
    }
    function relativeLuminance(rgb) {
        const [r, g, b] = rgb.map(v => {
            const s = v / 255;
            return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
        });
        return 0.2126 * r + 0.7152 * g + 0.0722 * b;
    }
    function contrastRatio(fg, bg) {
        const f = parseColor(fg);
        const b = parseColor(bg);
        if (!f || !b) return null;
        const lf = relativeLuminance(f);
        const lb = relativeLuminance(b);
        const [light, dark] = lf > lb ? [lf, lb] : [lb, lf];
        return (light + 0.05) / (dark + 0.05);
    }

    const focusables = Array.from(
        document.querySelectorAll(FOCUSABLE_SELECTOR)
    );

    function stableId(el) {
        const tag = el.tagName.toLowerCase();
        const id = el.getAttribute("id");
        if (id) return `${tag}#${id}`;
        const idx = focusables.indexOf(el);
        const role = el.getAttribute("role");
        if (role) return `${tag}[role=${role}]@${idx}`;
        const type = el.getAttribute("type");
        if (type && tag === "input") return `${tag}[type=${type}]@${idx}`;
        return `${tag}@${idx}`;
    }

    const targetEls = Array.from(
        document.querySelectorAll('a, button, [role="button"], [tabindex]')
    ).filter(el => el.getAttribute("tabindex") !== "-1");

    const interactive_targets = targetEls.map(el => {
        const rect = el.getBoundingClientRect();
        const cs = getComputedStyle(el);
        const defaultRatio = contrastRatio(cs.color, cs.backgroundColor);
        // :focus pseudo-class applies when an element holds keyboard
        // focus — synthetic el.focus() from inside page.evaluate
        // satisfies that, and getComputedStyle reflects the resulting
        // computed values. :hover does NOT trigger from a synthetic
        // call; left null so the Swift soft-pass kicks in.
        let focusRatio = null;
        try {
            el.focus();
            if (document.activeElement === el) {
                const fcs = getComputedStyle(el);
                focusRatio = contrastRatio(fcs.color, fcs.backgroundColor);
            }
            el.blur();
        } catch {
            focusRatio = null;
        }
        return {
            identifier: stableId(el),
            width_px: Math.round(rect.width),
            height_px: Math.round(rect.height),
            default_contrast_ratio: defaultRatio,
            hover_contrast_ratio: null,
            focus_contrast_ratio: focusRatio,
        };
    });

    const dom_focus_order = focusables.map(el => stableId(el));

    // Clear current focus so the playwright keyboard Tab walk starts
    // from a known baseline.
    try { document.activeElement?.blur(); } catch { /* ignore */ }

    return { interactive_targets, dom_focus_order };
})()
