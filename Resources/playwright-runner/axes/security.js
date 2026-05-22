// Security-axis measurement body — extracted from runner.ts
// measureSecurity during U.2b-1b-3 so child U.2b-1b-4 can load the
// same byte sequence via Swift's WKWebView.evaluateJavaScript. Do not
// edit in isolation — runner.ts loads this file at module init.
//
// IIFE expression form: page.evaluate(STRING) returns the
// SecurityMeasurement object directly (no Promise).
//
// Raw attribute reads on purpose: the Swift SecurityAxis evaluator
// matches the `javascript:` scheme on the raw `<a href>` (resolved
// .href would still return `javascript:...` but raw is the spec'd
// surface). For `<script src>`, `same_origin` is computed by
// resolving the raw src against `location.href` and comparing the
// origin, with a try/catch fallback to `false` on parse failure.
(() => {
    const csrfPatterns = ["csrf", "_token", "authenticity_token", "anti_xsrf"];

    const forms = Array.from(
        document.querySelectorAll("form")
    ).map(f => {
        const inputs = Array.from(
            f.querySelectorAll("input")
        );
        const csrfPresent = inputs.some(i => {
            const name = (i.getAttribute("name") || "").toLowerCase();
            return csrfPatterns.some(p => name.includes(p));
        });
        const rawMethod = f.getAttribute("method");
        return {
            action: f.getAttribute("action"),
            method: (rawMethod ?? "get").toLowerCase(),
            csrf_token_present: csrfPresent,
        };
    });

    const anchors = Array.from(
        document.querySelectorAll("a[href]")
    ).map(a => ({ href: a.getAttribute("href") || "" }));

    const scripts = Array.from(
        document.querySelectorAll("script[src]")
    ).map(s => {
        const src = s.getAttribute("src") || "";
        let sameOrigin = false;
        try {
            sameOrigin = new URL(src, location.href).origin === location.origin;
        } catch {
            sameOrigin = false;
        }
        return { src, same_origin: sameOrigin };
    });

    return { forms, anchors, scripts };
})()
