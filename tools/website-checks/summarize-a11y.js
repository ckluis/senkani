#!/usr/bin/env node
// Aggregate pa11y-ci + axe-core/cli JSON output into a Markdown summary
// suitable for paste into the closing-audit completed record for the
// active website-rebuild round (operator-local; the round-11 record
// lives under spec/autonomous/completed/2026/ — see the
// 2026-05-01-website-rebuild-11e-closing-audit-* file for the prior
// shape). Future rounds repeat the pattern in their own item.
const fs = require('fs');
const path = require('path');

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, v, i, arr) => {
    if (v.startsWith('--')) acc.push([v.slice(2), arr[i + 1]]);
    return acc;
  }, [])
);

const pa11yPath = args.pa11y;
const axePath   = args.axe;
const urlsPath  = args.urls;

const urls = fs.readFileSync(urlsPath, 'utf8').trim().split('\n');
const stripBase = (u) => u.replace(/^http:\/\/127\.0\.0\.1:\d+\//, '/');

const perPage = new Map();
for (const u of urls) perPage.set(u, { pa11yErrors: 0, pa11yWarnings: 0, pa11yNotices: 0, axeViolations: 0 });

// pa11y-ci shape: { results: { url: [issue, ...] } }
let pa11y = null;
try { pa11y = JSON.parse(fs.readFileSync(pa11yPath, 'utf8')); }
catch (e) { console.error(`pa11y read failed: ${e.message}`); }
if (pa11y && pa11y.results) {
  for (const [u, issues] of Object.entries(pa11y.results)) {
    if (!perPage.has(u)) perPage.set(u, { pa11yErrors: 0, pa11yWarnings: 0, pa11yNotices: 0, axeViolations: 0 });
    const row = perPage.get(u);
    for (const it of issues) {
      if (it.type === 'error') row.pa11yErrors++;
      else if (it.type === 'warning') row.pa11yWarnings++;
      else if (it.type === 'notice') row.pa11yNotices++;
    }
  }
}

// axe-core/cli shape: array of { url, violations, ... }
let axe = null;
try { axe = JSON.parse(fs.readFileSync(axePath, 'utf8')); }
catch (e) { console.error(`axe read failed: ${e.message}`); }
if (Array.isArray(axe)) {
  for (const r of axe) {
    if (!perPage.has(r.url)) perPage.set(r.url, { pa11yErrors: 0, pa11yWarnings: 0, pa11yNotices: 0, axeViolations: 0 });
    const row = perPage.get(r.url);
    row.axeViolations = (r.violations || []).reduce((acc, v) => acc + (v.nodes ? v.nodes.length : 1), 0);
    row.axeViolationRules = (r.violations || []).map(v => v.id);
  }
}

let totalErrors = 0, totalAxe = 0, totalWarnings = 0, pagesWithErrors = 0, pagesOverWarnLimit = 0;
const failingPages = [];
for (const [u, row] of perPage) {
  totalErrors += row.pa11yErrors;
  totalAxe += row.axeViolations;
  totalWarnings += row.pa11yWarnings;
  if (row.pa11yErrors > 0 || row.axeViolations > 0) { pagesWithErrors++; failingPages.push([u, row]); }
  if (row.pa11yWarnings > 3) pagesOverWarnLimit++;
}

const ts = new Date().toISOString().slice(0, 16).replace('T', ' ');
console.log(`### a11y sweep — ${ts}`);
console.log('');
console.log(`Pages audited: **${perPage.size}**`);
console.log(`pa11y-ci errors (AA): **${totalErrors}** across ${pagesWithErrors} pages`);
console.log(`pa11y-ci warnings:   **${totalWarnings}** (${pagesOverWarnLimit} pages over the ≤3 limit)`);
console.log(`axe-core violations: **${totalAxe}**`);
console.log('');

if (failingPages.length === 0) {
  console.log('✅ Zero AA violations on every page.');
} else {
  console.log('### Pages with AA violations');
  console.log('');
  console.log('| Page | pa11y errors | pa11y warnings | axe violations | axe rules |');
  console.log('|---|---|---|---|---|');
  for (const [u, row] of failingPages) {
    const rules = (row.axeViolationRules || []).join(', ') || '—';
    console.log(`| \`${stripBase(u)}\` | ${row.pa11yErrors} | ${row.pa11yWarnings} | ${row.axeViolations} | ${rules} |`);
  }
}

console.log('');
console.log('### Per-page warnings over ≤3 ceiling');
const overLimit = [...perPage].filter(([_, r]) => r.pa11yWarnings > 3);
if (overLimit.length === 0) {
  console.log('');
  console.log('None.');
} else {
  console.log('');
  console.log('| Page | pa11y warnings |');
  console.log('|---|---|');
  for (const [u, row] of overLimit) console.log(`| \`${stripBase(u)}\` | ${row.pa11yWarnings} |`);
}
