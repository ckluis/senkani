// Completeness-axis measurement body — extracted from runner.ts
// measureCompleteness during U.2b-1b-3 so child U.2b-1b-4 can load
// the same byte sequence via Swift's WKWebView.evaluateJavaScript.
// Do not edit in isolation — runner.ts loads this file at module
// init.
//
// IIFE expression form: page.evaluate(STRING) returns the DOM-walk
// portion { title, metaDescription, sameOriginLinks, images }. The
// HEAD-probe loop that resolves internal_links is performed by
// runner.ts outside page.evaluate (uses page.request.fetch, which
// has no WKWebView counterpart in this form) — child #4's Swift
// loader will compose its own probe path.
(() => {
    const title = document.title || null;
    const metaEl = document.querySelector('meta[name="description"]');
    const metaDescription = metaEl?.content ?? null;

    const sameOriginLinks = Array.from(
        document.querySelectorAll("a[href]")
    )
        .map(a => a.href)
        .filter(href => {
            try {
                return new URL(href).origin === location.origin;
            } catch {
                return false;
            }
        });

    const images = Array.from(
        document.querySelectorAll("img")
    ).map(img => ({
        src: img.src,
        alt: img.getAttribute("alt"),
    }));

    return { title, metaDescription, sameOriginLinks, images };
})()
