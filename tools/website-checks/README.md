# tools/website-checks

Local harness for the Senkani docs site. Runs WCAG 2.1 AA + Lighthouse
sweeps via Puppeteer's bundled Chrome for Testing — no /Applications
chrome required, no global npm installs.

The Bash entry points live in `../../scripts/`:

```bash
# Start a static server for the repo root.
./scripts/site-serve.sh start          # default port 8765

# AA sweep — pa11y-ci (HTML_CodeSniffer) + axe-core 4.x via puppeteer.
./scripts/a11y-check.sh                # all 99 pages
./scripts/a11y-check.sh sample         # 18-page representative subset

# Lighthouse perf sweep — mid-tier mobile (Moto G Power, 1638 Kbps, 4× CPU).
./scripts/perf-check.sh                # all 99 pages
./scripts/perf-check.sh sample

./scripts/site-serve.sh stop
```

Results land under `results/a11y/` and `results/perf/` with timestamped
filenames; the most recent `summary-*.md` is suitable for paste into
the closing-audit completed record for the active website-rebuild
round (operator-local; the round-11 record lives under
`spec/autonomous/completed/2026/2026-05-01-website-rebuild-11e-closing-audit-*`).

`run-axe.js` drives `@axe-core/puppeteer` (axe-core 4.11.x). The
JSON shape matches `@axe-core/cli`'s output so `summarize-a11y.js`
can consume either.

`summarize-{a11y,perf}.js` aggregate raw JSON into the appendix-style
Markdown the website-rebuild audit doc takes.

## Why a local harness, not CI?

The site is static GitHub Pages — there's no per-PR perf regression
risk that needs CI gating. The harness is run-on-demand: a release
gate before flipping a website-rebuild umbrella row, or as part of
a `website-rebuild-11*` autonomous round. CI integration is a
follow-up.

## Versions pinned

- `puppeteer ^24.42`
- `@axe-core/puppeteer ^4.11`
- `pa11y-ci ^4.1`
- `lighthouse ^13.2`

The first run downloads Chrome for Testing into
`~/.cache/puppeteer/`. Subsequent runs reuse it.
