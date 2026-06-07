// Perf-axis measurement body — extracted from runner.ts measurePerf
// during U.2b-1b-3 so child U.2b-1b-4 can load the same byte sequence
// via Swift's WKWebView.evaluateJavaScript. Do not edit in isolation —
// runner.ts loads this file at module init; child #6's parity corpus
// will diff Playwright vs WKWebView outputs against the SAME source.
//
// IIFE expression form: page.evaluate(STRING) executes the source and
// awaits the resolved value (a Promise<PerfMeasurement> here).
(() => {
    return new Promise((resolve) => {
        let lcpMs = null;
        try {
            const po = new PerformanceObserver((list) => {
                const entries = list.getEntries();
                if (entries.length > 0) {
                    const last = entries[entries.length - 1];
                    const ts = last.renderTime ?? last.startTime;
                    if (typeof ts === "number") {
                        lcpMs = Math.round(ts);
                    }
                }
            });
            po.observe({ type: "largest-contentful-paint", buffered: true });
        } catch (_e) {
            // PerformanceObserver not available — leave lcpMs null.
        }
        // Give the browser ~500ms to flush LCP candidates.
        setTimeout(() => {
            resolve({ inp_ms: null, lcp_ms: lcpMs });
        }, 500);
    });
})()
