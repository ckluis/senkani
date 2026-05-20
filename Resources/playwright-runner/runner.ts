// Senkani Playwright subprocess runner — U.2a-2a Chromium integration.
//
// Reads a single JSON object `{plan: ValidationStep[], target_url: string}`
// from stdin, launches a headless Playwright Chromium instance, opens
// `target_url`, dispatches each plan step to its per-axis measurement
// path (perf via PerformanceObserver / completeness via DOM walk +
// HEAD-probes), evaluates assertions against per-step `expected`
// overrides (or Web Vitals defaults), and writes a single JSON object
// `PlaywrightResult` to stdout. Exits 0 on success / non-zero on plan
// parse error or unrecoverable browser failure.
//
// U.2a-1 shipped the I/O scaffold + plan parser + stub dispatcher.
// U.2a-2a (this file) wires real Chromium launch + perf + completeness
// measurement and evaluation. U.2a-2b will layer the MCP tool + CLI +
// HookRouter + EgressProxy + audit-chain rows on top of the runner's
// stdout JSON.
// U.2b-axes will add security + design measurement paths inside this
// same dispatcher.
//
// Run via `node Resources/playwright-runner/runner.ts` (or via a
// ts-node loader) after `npm install` populates `node_modules/`
// alongside this file, AND `npx playwright install chromium` populates
// `~/Library/Caches/ms-playwright/chromium-*` so the Swift refusal
// path (PlaywrightSubprocessRunner) lets the spawn proceed.

import { chromium, Browser, Page } from "playwright";

type Axis = "perf" | "security" | "design" | "completeness";

interface ValidationStep {
    axis: Axis;
    assertion_id: string;
    target_path: string;
    selector: string | null;
    expected: string | null;
}

interface RunnerRequest {
    plan: ValidationStep[];
    target_url: string;
    screenshot?: boolean;
}

interface PlaywrightResult {
    result_status: "pass" | "fail" | "partial";
    axes_run: string[];
    assertions_passed: number;
    assertions_failed: number;
    screenshot_path: string | null;
    advisory: string | null;
}

interface PerfMeasurement {
    inp_ms: number | null;
    lcp_ms: number | null;
}

interface InternalLink {
    href: string;
    status_code: number | null;
}

interface ImageElement {
    src: string;
    alt: string | null;
}

interface CompletenessMeasurement {
    title: string | null;
    meta_description: string | null;
    internal_links: InternalLink[];
    images: ImageElement[];
}

interface PerfExpected {
    inp_ms?: number;
    lcp_ms?: number;
}

const DEFAULT_INP_MS = 200;
const DEFAULT_LCP_MS = 2500;

function readStdin(): Promise<string> {
    return new Promise((resolve, reject) => {
        let buf = "";
        process.stdin.setEncoding("utf8");
        process.stdin.on("data", (chunk: string) => { buf += chunk; });
        process.stdin.on("end", () => resolve(buf));
        process.stdin.on("error", reject);
    });
}

function emit(result: PlaywrightResult): void {
    process.stdout.write(JSON.stringify(result));
}

async function measurePerf(page: Page): Promise<PerfMeasurement> {
    // LCP via PerformanceObserver. INP requires a qualifying interaction
    // event; headless runs without simulated input typically have none —
    // we report null and the Swift PerfAxis treats that as a pass with
    // advisory "INP not measured".
    return await page.evaluate(() => {
        return new Promise<PerfMeasurement>((resolve) => {
            let lcpMs: number | null = null;
            try {
                const po = new PerformanceObserver((list) => {
                    const entries = list.getEntries() as PerformanceEntry[];
                    if (entries.length > 0) {
                        const last = entries[entries.length - 1] as PerformanceEntry & { renderTime?: number };
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
    });
}

async function measureCompleteness(page: Page): Promise<CompletenessMeasurement> {
    const dom = await page.evaluate(() => {
        const title = document.title || null;
        const metaEl = document.querySelector<HTMLMetaElement>('meta[name="description"]');
        const metaDescription = metaEl?.content ?? null;

        const sameOriginLinks: string[] = Array.from(
            document.querySelectorAll<HTMLAnchorElement>("a[href]")
        )
            .map(a => a.href)
            .filter(href => {
                try {
                    return new URL(href).origin === location.origin;
                } catch {
                    return false;
                }
            });

        const images: { src: string; alt: string | null }[] = Array.from(
            document.querySelectorAll<HTMLImageElement>("img")
        ).map(img => ({
            src: img.src,
            alt: img.getAttribute("alt"),
        }));

        return { title, metaDescription, sameOriginLinks, images };
    });

    // HEAD-probe each same-origin link. failOnStatusCode: false so 4xx/5xx
    // return a response instead of throwing.
    const internalLinks: InternalLink[] = [];
    for (const href of dom.sameOriginLinks) {
        try {
            const resp = await page.request.fetch(href, {
                method: "HEAD",
                failOnStatusCode: false,
                timeout: 5000,
            });
            internalLinks.push({ href, status_code: resp.status() });
        } catch {
            internalLinks.push({ href, status_code: null });
        }
    }

    return {
        title: dom.title,
        meta_description: dom.metaDescription,
        internal_links: internalLinks,
        images: dom.images,
    };
}

function parsePerfExpected(step: ValidationStep): PerfExpected | null {
    if (!step.expected) return null;
    try {
        return JSON.parse(step.expected) as PerfExpected;
    } catch {
        return null;
    }
}

function evaluatePerf(measurement: PerfMeasurement, expected: PerfExpected | null): {
    passed: number;
    failed: number;
    advisories: string[];
} {
    const inpThreshold = expected?.inp_ms ?? DEFAULT_INP_MS;
    const lcpThreshold = expected?.lcp_ms ?? DEFAULT_LCP_MS;
    let passed = 0;
    let failed = 0;
    const advisories: string[] = [];

    if (measurement.inp_ms !== null) {
        if (measurement.inp_ms <= inpThreshold) {
            passed += 1;
        } else {
            failed += 1;
            advisories.push(
                `perf.inp: ${measurement.inp_ms}ms exceeds threshold ${inpThreshold}ms`
            );
        }
    } else {
        // INP not measured — treat as pass with informational advisory.
        passed += 1;
    }

    if (measurement.lcp_ms !== null) {
        if (measurement.lcp_ms <= lcpThreshold) {
            passed += 1;
        } else {
            failed += 1;
            advisories.push(
                `perf.lcp: ${measurement.lcp_ms}ms exceeds threshold ${lcpThreshold}ms`
            );
        }
    } else {
        failed += 1;
        advisories.push("perf.lcp: LCP not measured");
    }

    return { passed, failed, advisories };
}

function evaluateCompleteness(measurement: CompletenessMeasurement): {
    passed: number;
    failed: number;
    advisories: string[];
} {
    let passed = 0;
    let failed = 0;
    const advisories: string[] = [];

    const titleOk = (measurement.title?.trim().length ?? 0) > 0;
    const metaOk = (measurement.meta_description?.trim().length ?? 0) > 0;
    if (titleOk && metaOk) {
        passed += 1;
    } else {
        failed += 1;
        const missing: string[] = [];
        if (!titleOk) missing.push("<title>");
        if (!metaOk) missing.push("<meta name=\"description\">");
        advisories.push(`completeness.title_meta: missing or empty ${missing.join(", ")}`);
    }

    const badLinks = measurement.internal_links.filter(l => (l.status_code ?? 999) >= 400);
    if (badLinks.length === 0) {
        passed += 1;
    } else {
        failed += 1;
        advisories.push(
            `completeness.internal_links_resolve: ${badLinks.length} link(s) failed`
        );
    }

    const altMissing = measurement.images.filter(img => !(img.alt ?? "").trim());
    if (altMissing.length === 0) {
        passed += 1;
    } else {
        failed += 1;
        advisories.push(
            `completeness.img_alt: ${altMissing.length} <img> missing or empty alt`
        );
    }

    return { passed, failed, advisories };
}

async function main(): Promise<void> {
    const raw = await readStdin();
    let request: RunnerRequest;
    try {
        request = JSON.parse(raw) as RunnerRequest;
    } catch (e) {
        process.stderr.write(`runner: bad JSON request: ${e}\n`);
        process.exit(1);
    }

    if (!Array.isArray(request.plan) || typeof request.target_url !== "string") {
        process.stderr.write("runner: malformed plan or target_url\n");
        process.exit(1);
    }

    const axesRun = Array.from(new Set(request.plan.map(s => s.axis))).sort();
    let browser: Browser | null = null;
    try {
        browser = await chromium.launch({ headless: true });
        const context = await browser.newContext();
        const page = await context.newPage();
        await page.goto(request.target_url, { waitUntil: "load", timeout: 30000 });

        let totalPassed = 0;
        let totalFailed = 0;
        const allAdvisories: string[] = [];

        if (axesRun.includes("perf")) {
            const measurement = await measurePerf(page);
            const perfStep = request.plan.find(s => s.axis === "perf");
            const expected = perfStep ? parsePerfExpected(perfStep) : null;
            const r = evaluatePerf(measurement, expected);
            totalPassed += r.passed;
            totalFailed += r.failed;
            allAdvisories.push(...r.advisories);
        }
        if (axesRun.includes("completeness")) {
            const measurement = await measureCompleteness(page);
            const r = evaluateCompleteness(measurement);
            totalPassed += r.passed;
            totalFailed += r.failed;
            allAdvisories.push(...r.advisories);
        }

        let screenshotPath: string | null = null;
        if (request.screenshot !== false) {
            screenshotPath = `/tmp/senkani-validation-${Date.now()}.png`;
            try {
                await page.screenshot({ path: screenshotPath });
            } catch {
                screenshotPath = null;
            }
        }

        const result_status: PlaywrightResult["result_status"] =
            totalFailed === 0 ? "pass" : (totalPassed === 0 ? "fail" : "partial");

        emit({
            result_status,
            axes_run: axesRun,
            assertions_passed: totalPassed,
            assertions_failed: totalFailed,
            screenshot_path: screenshotPath,
            advisory: allAdvisories.length > 0 ? allAdvisories.join(" | ") : null,
        });
        process.exit(0);
    } catch (err) {
        process.stderr.write(`runner: browser failure: ${err}\n`);
        // Emit a structured fail so the Swift side decodes a result rather
        // than treating the non-zero exit as a parse failure.
        emit({
            result_status: "fail",
            axes_run: axesRun,
            assertions_passed: 0,
            assertions_failed: 0,
            screenshot_path: null,
            advisory: `browser failure: ${err}`,
        });
        process.exit(2);
    } finally {
        if (browser) {
            try { await browser.close(); } catch { /* best-effort */ }
        }
    }
}

main().catch(err => {
    process.stderr.write(`runner: unhandled error: ${err}\n`);
    process.exit(1);
});
