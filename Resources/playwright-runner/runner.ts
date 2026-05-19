// Senkani Playwright subprocess runner — U.2a-1 scaffold.
//
// Reads a single JSON object `{plan: ValidationStep[], target_url: string}`
// from stdin, drives the Playwright Chromium browser against `target_url`,
// dispatches each plan step to its per-axis assertion library, and
// writes a single JSON object `PlaywrightResult` to stdout. Exits 0 on
// success / non-zero on a plan parse error.
//
// U.2a-1 ships the I/O scaffold + plan parser + stub dispatcher. U.2a-2
// adds the perf + completeness assertion libraries; U.2b-axes adds the
// security + design libraries. The dispatcher's switch arm for each axis
// stays inside this file so axis additions don't fork the framing
// contract.
//
// Run via `node Resources/playwright-runner/runner.ts` after
// `npx playwright install chromium` populates the cache.

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
}

interface PlaywrightResult {
    result_status: "pass" | "fail" | "partial";
    axes_run: string[];
    assertions_passed: number;
    assertions_failed: number;
    screenshot_path: string | null;
    advisory: string | null;
}

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

    // U.2a-1 stub dispatcher — returns a pass with zero assertions run.
    // U.2a-2 wires perf + completeness; U.2b-axes wires security + design.
    const axesRun = Array.from(new Set(request.plan.map(s => s.axis))).sort();
    const result: PlaywrightResult = {
        result_status: "pass",
        axes_run: axesRun,
        assertions_passed: 0,
        assertions_failed: 0,
        screenshot_path: null,
        advisory: "u2a-1 scaffold: no axis assertion libraries wired yet",
    };
    emit(result);
    process.exit(0);
}

main().catch(err => {
    process.stderr.write(`runner: unhandled error: ${err}\n`);
    process.exit(1);
});
