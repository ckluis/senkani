#!/usr/bin/env node
// Aggregate Lighthouse JSON output into a Markdown summary suitable
// for paste into the closing-audit completed record for the active
// website-rebuild round (operator-local; round-11 lives under
// spec/autonomous/completed/2026/2026-05-01-website-rebuild-11e-*).
const fs = require('fs');
const path = require('path');

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, v, i, arr) => {
    if (v.startsWith('--')) acc.push([v.slice(2), arr[i + 1]]);
    return acc;
  }, [])
);

const dir = args.dir;
const urlsPath = args.urls;
const urls = fs.readFileSync(urlsPath, 'utf8').trim().split('\n');
const stripBase = (u) => u.replace(/^http:\/\/127\.0\.0\.1:\d+\//, '/');
const slugFor = (u) =>
  u.replace(/^http:\/\/127\.0\.0\.1:\d+\//, '').replace(/[\/\.]/g, '_').replace(/_html$/, '') || 'root';

const rows = [];
let missing = 0;
for (const u of urls) {
  const slug = slugFor(u);
  const file = path.join(dir, `${slug}.json`);
  if (!fs.existsSync(file)) { missing++; rows.push({ u, score: null, lcp: null, cls: null, tbt: null }); continue; }
  let lh;
  try { lh = JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (e) { rows.push({ u, score: null, lcp: null, cls: null, tbt: null, err: e.message }); continue; }
  const score = Math.round((lh.categories?.performance?.score ?? 0) * 100);
  const lcp = lh.audits?.['largest-contentful-paint']?.numericValue;
  const cls = lh.audits?.['cumulative-layout-shift']?.numericValue;
  const tbt = lh.audits?.['total-blocking-time']?.numericValue;
  rows.push({ u, score, lcp, cls, tbt });
}

const valid = rows.filter(r => r.score != null);
const passing = valid.filter(r => r.score >= 90);
const failing = valid.filter(r => r.score < 90);
const avg = valid.length ? Math.round(valid.reduce((a, r) => a + r.score, 0) / valid.length) : null;
const min = valid.length ? valid.reduce((a, r) => Math.min(a, r.score), 100) : null;
const max = valid.length ? valid.reduce((a, r) => Math.max(a, r.score), 0) : null;

const ts = new Date().toISOString().slice(0, 16).replace('T', ' ');
console.log(`### Lighthouse perf sweep — ${ts}`);
console.log('');
console.log(`Throttling: Moto G Power (4× CPU, 1638 Kbps, 150 ms RTT) · headless Chrome for Testing`);
console.log('');
console.log(`Pages audited: **${valid.length}** of ${urls.length}` + (missing ? ` (${missing} missing)` : ''));
console.log(`Score range: ${min} – ${max} · mean **${avg}** · pages ≥90: **${passing.length} / ${valid.length}**`);
console.log('');

if (failing.length === 0) {
  console.log('✅ Every page scored ≥90.');
} else {
  console.log('### Pages below the 90 ceiling');
  console.log('');
  console.log('| Page | Perf | LCP (ms) | CLS | TBT (ms) |');
  console.log('|---|---|---|---|---|');
  for (const r of failing.sort((a, b) => a.score - b.score)) {
    console.log(`| \`${stripBase(r.u)}\` | **${r.score}** | ${Math.round(r.lcp || 0)} | ${(r.cls ?? 0).toFixed(3)} | ${Math.round(r.tbt || 0)} |`);
  }
}

console.log('');
console.log('### All pages — perf score');
console.log('');
console.log('| Page | Perf | LCP (ms) | CLS | TBT (ms) |');
console.log('|---|---|---|---|---|');
for (const r of rows.sort((a, b) => stripBase(a.u).localeCompare(stripBase(b.u)))) {
  if (r.score == null) {
    console.log(`| \`${stripBase(r.u)}\` | _missing_ | — | — | — |`);
  } else {
    console.log(`| \`${stripBase(r.u)}\` | ${r.score} | ${Math.round(r.lcp || 0)} | ${(r.cls ?? 0).toFixed(3)} | ${Math.round(r.tbt || 0)} |`);
  }
}
