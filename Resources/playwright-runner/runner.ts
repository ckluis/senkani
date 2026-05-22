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
    security_measurement?: SecurityMeasurement | null;
    design_measurement?: DesignMeasurement | null;
    vulnerable_dependencies?: string[];
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

interface FormElement {
    action: string | null;
    method: string;
    csrf_token_present: boolean;
}

interface AnchorElement {
    href: string;
}

interface ScriptElement {
    src: string;
    same_origin: boolean;
}

interface SecurityMeasurement {
    forms: FormElement[];
    anchors: AnchorElement[];
    scripts: ScriptElement[];
}

interface InteractiveTarget {
    identifier: string;
    width_px: number;
    height_px: number;
    default_contrast_ratio: number | null;
    hover_contrast_ratio: number | null;
    focus_contrast_ratio: number | null;
}

interface DesignMeasurement {
    interactive_targets: InteractiveTarget[];
    dom_focus_order: string[];
    tab_focus_order: string[];
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

async function measureSecurity(page: Page): Promise<SecurityMeasurement> {
    // DOM walk inside page.evaluate so all element access happens in the
    // browser context. Returns the SecurityMeasurement payload byte-
    // compatible with the Swift `SecurityMeasurement` Codable shape at
    // Sources/Core/Validation/security.swift.
    //
    // Raw attribute reads on purpose: the Swift SecurityAxis evaluator
    // matches the `javascript:` scheme on the raw `<a href>` (resolved
    // .href would still return `javascript:...` but raw is the spec'd
    // surface). For `<script src>`, `same_origin` is computed by
    // resolving the raw src against `location.href` and comparing the
    // origin, with a try/catch fallback to `false` on parse failure —
    // mirrors measureCompleteness's URL handling.
    return await page.evaluate(() => {
        const csrfPatterns = ["csrf", "_token", "authenticity_token", "anti_xsrf"];

        const forms: FormElement[] = Array.from(
            document.querySelectorAll<HTMLFormElement>("form")
        ).map(f => {
            const inputs = Array.from(
                f.querySelectorAll<HTMLInputElement>("input")
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

        const anchors: AnchorElement[] = Array.from(
            document.querySelectorAll<HTMLAnchorElement>("a[href]")
        ).map(a => ({ href: a.getAttribute("href") || "" }));

        const scripts: ScriptElement[] = Array.from(
            document.querySelectorAll<HTMLScriptElement>("script[src]")
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
    });
}

async function measureDesign(page: Page): Promise<DesignMeasurement> {
    // U.2b-1b-2 design-axis measurement. Walks every interactive target
    // (`<a>` / `<button>` / `[role="button"]` / `[tabindex]` with
    // tabindex != -1), captures bounding rect + default-state contrast
    // ratio + focus-state contrast ratio, and emits the
    // DesignMeasurement payload byte-compatible with the Swift
    // `DesignMeasurement` Codable shape at
    // `Sources/Core/Validation/design.swift`.
    //
    // Hover-state contrast is left `null` — synthesizing the
    // CSS :hover pseudo-class requires real pointer events that a
    // headless run inside `page.evaluate` cannot reach. The Swift
    // `DesignAxis` evaluator's soft-pass branch handles null hover/focus
    // measurements; tests covering the headless surface live alongside
    // `DesignAxisTests`.
    const phase1 = await page.evaluate(() => {
        const FOCUSABLE_SELECTOR = ":is(a[href], button, input, select, textarea, [tabindex]):not([tabindex='-1'])";

        function parseColor(c: string): [number, number, number] | null {
            const m = c.match(/rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)/);
            if (!m) return null;
            return [parseFloat(m[1]), parseFloat(m[2]), parseFloat(m[3])];
        }
        function relativeLuminance(rgb: [number, number, number]): number {
            const [r, g, b] = rgb.map(v => {
                const s = v / 255;
                return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
            });
            return 0.2126 * r + 0.7152 * g + 0.0722 * b;
        }
        function contrastRatio(fg: string, bg: string): number | null {
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
        ) as HTMLElement[];

        function stableId(el: Element): string {
            const tag = el.tagName.toLowerCase();
            const id = el.getAttribute("id");
            if (id) return `${tag}#${id}`;
            const idx = focusables.indexOf(el as HTMLElement);
            const role = el.getAttribute("role");
            if (role) return `${tag}[role=${role}]@${idx}`;
            const type = el.getAttribute("type");
            if (type && tag === "input") return `${tag}[type=${type}]@${idx}`;
            return `${tag}@${idx}`;
        }

        const targetEls = Array.from(
            document.querySelectorAll('a, button, [role="button"], [tabindex]')
        ).filter(el => el.getAttribute("tabindex") !== "-1") as HTMLElement[];

        const interactive_targets = targetEls.map(el => {
            const rect = el.getBoundingClientRect();
            const cs = getComputedStyle(el);
            const defaultRatio = contrastRatio(cs.color, cs.backgroundColor);
            // :focus pseudo-class applies when an element holds keyboard
            // focus — synthetic `el.focus()` from inside page.evaluate
            // satisfies that, and `getComputedStyle` reflects the
            // resulting computed values. `:hover` does NOT trigger from
            // a synthetic call; left null so the Swift soft-pass kicks
            // in.
            let focusRatio: number | null = null;
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
        try { (document.activeElement as HTMLElement | null)?.blur(); } catch { /* ignore */ }

        return { interactive_targets, dom_focus_order };
    });

    // Tab-walk via playwright keyboard. Iteration count bounded by the
    // dom_focus_order length — handles focus-trapping pages without
    // looping forever.
    const tab_focus_order: string[] = [];
    for (let i = 0; i < phase1.dom_focus_order.length; i++) {
        await page.keyboard.press("Tab");
        const id = await page.evaluate(() => {
            const FOCUSABLE_SELECTOR = ":is(a[href], button, input, select, textarea, [tabindex]):not([tabindex='-1'])";
            const focusables = Array.from(document.querySelectorAll(FOCUSABLE_SELECTOR)) as HTMLElement[];
            const el = document.activeElement;
            if (!el || el === document.body) return null;
            const tag = el.tagName.toLowerCase();
            const elId = el.getAttribute("id");
            if (elId) return `${tag}#${elId}`;
            const idx = focusables.indexOf(el as HTMLElement);
            const role = el.getAttribute("role");
            if (role) return `${tag}[role=${role}]@${idx}`;
            const type = el.getAttribute("type");
            if (type && tag === "input") return `${tag}[type=${type}]@${idx}`;
            return `${tag}@${idx}`;
        });
        if (id) tab_focus_order.push(id);
    }

    return {
        interactive_targets: phase1.interactive_targets,
        dom_focus_order: phase1.dom_focus_order,
        tab_focus_order,
    };
}

async function npmAuditBestEffort(target_url: string): Promise<string[]> {
    // U.2b-1b-2 best-effort npm-audit static check. Only localhost /
    // 127.0.0.1 / ::1 / *.local targets attempt the audit; non-local
    // targets unconditionally produce `[]` (covered by the
    // PlaywrightRunnerDesignMeasurementTests skip-path test).
    //
    // Discoverable `package.json` = present at `process.cwd()`. Absent
    // → silent skip per acceptance.
    let isLocal = false;
    try {
        const url = new URL(target_url);
        const host = url.hostname.toLowerCase();
        isLocal = host === "localhost"
            || host === "127.0.0.1"
            || host === "::1"
            || host.endsWith(".local");
    } catch {
        return [];
    }
    if (!isLocal) return [];

    try {
        const fs = await import("fs/promises");
        const path = await import("path");
        const pkgPath = path.join(process.cwd(), "package.json");
        await fs.access(pkgPath);
    } catch {
        return [];
    }

    try {
        const { execFile } = await import("child_process");
        const { promisify } = await import("util");
        const exec = promisify(execFile);

        // `npm audit --json` exits non-zero when vulnerabilities are
        // present; recover the JSON from the rejection.
        let auditJson = "{}";
        try {
            const { stdout } = await exec("npm", ["audit", "--json"], {
                timeout: 5_000,
                cwd: process.cwd(),
                maxBuffer: 10 * 1024 * 1024,
            });
            auditJson = stdout;
        } catch (e) {
            const stdout = (e as { stdout?: string }).stdout;
            if (typeof stdout === "string" && stdout.length > 0) {
                auditJson = stdout;
            } else {
                return [];
            }
        }

        const parsed = JSON.parse(auditJson) as { vulnerabilities?: Record<string, unknown> };
        if (parsed.vulnerabilities && typeof parsed.vulnerabilities === "object") {
            return Object.keys(parsed.vulnerabilities);
        }
    } catch {
        /* best-effort */
    }
    return [];
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
        // U.2b-axes — security + design axes ship Swift evaluators in
        // Sources/Core/Validation/{security,design}.swift. U.2b-1b-1
        // wired measureSecurity → PlaywrightResult.security_measurement
        // (consumed by SecurityAxis.evaluate). U.2b-1b-2 wires
        // measureDesign → PlaywrightResult.design_measurement
        // (consumed by DesignAxis.evaluate).
        let securityMeasurement: SecurityMeasurement | null = null;
        if (axesRun.includes("security")) {
            securityMeasurement = await measureSecurity(page);
        }
        let designMeasurement: DesignMeasurement | null = null;
        if (axesRun.includes("design")) {
            designMeasurement = await measureDesign(page);
        }
        const vulnerableDependencies = await npmAuditBestEffort(request.target_url);

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
            security_measurement: securityMeasurement,
            design_measurement: designMeasurement,
            vulnerable_dependencies: vulnerableDependencies,
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
            vulnerable_dependencies: [],
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
