#!/usr/bin/env node
// Drive @axe-core/puppeteer over a list of URLs and emit a JSON array
// matching @axe-core/cli's shape ({ url, violations[], ... } per page)
// for the summarize-a11y.js aggregator.
const fs = require('fs');
const puppeteer = require('puppeteer');
const { AxePuppeteer } = require('@axe-core/puppeteer');

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, v, i, arr) => {
    if (v.startsWith('--')) acc.push([v.slice(2), arr[i + 1]]);
    return acc;
  }, [])
);

(async () => {
  const urls = fs.readFileSync(args.urls, 'utf8').trim().split('\n').filter(Boolean);
  const out  = args.out;

  const browser = await puppeteer.launch({
    headless: 'new',
    args: ['--no-sandbox', '--disable-setuid-sandbox'],
  });
  const results = [];
  for (const url of urls) {
    process.stderr.write(`  axe ${url}\n`);
    const page = await browser.newPage();
    try {
      await page.goto(url, { waitUntil: 'networkidle0', timeout: 30000 });
      const r = await new AxePuppeteer(page).withTags(['wcag2a', 'wcag2aa']).analyze();
      results.push({
        url,
        violations: r.violations,
        passes: (r.passes || []).length,
        incomplete: (r.incomplete || []).length,
      });
    } catch (e) {
      results.push({ url, violations: [], error: e.message });
    } finally {
      await page.close();
    }
  }
  await browser.close();
  fs.writeFileSync(out, JSON.stringify(results, null, 2));
  process.stderr.write(`wrote ${out}\n`);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
