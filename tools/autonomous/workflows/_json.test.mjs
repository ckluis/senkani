// _json.test.mjs — unit coverage for the schema-free panel JSON extractor.
//
// Run:  node --test tools/autonomous/workflows/_json.test.mjs
//
// Regression target: round-audit-panel.mjs panel/re-audit agents sometimes lead
// with multi-paragraph reasoning PROSE and emit the verdict JSON last (or never
// close it). The OLD parser sliced first-`{`..last-`}` and truncated _raw to 400
// chars, so a prose-then-JSON reply (or any prose containing braces) lost the
// structured verdict and the evidence. These tests pin the hardened contract.
// (process-gap-round-audit-panel-agent-json-truncation-2026-05-31)

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import * as canon from './_json.mjs'
import { parseAgentJSON, lastBalancedObject, balancedObjects } from './_json.mjs'

const FALLBACK = { verdict: 'CONCERNS', redFlags: [], concerns: [], oneLine: '' }
const SHAPE = '{"verdict":"PASS","redFlags":[],"concerns":["minor"],"oneLine":"ok"}'
const EXPECTED = { verdict: 'PASS', redFlags: [], concerns: ['minor'], oneLine: 'ok' }
const FAIL_SHAPE = '{"verdict":"FAIL","redFlags":["real blocker"],"concerns":[],"oneLine":"bad"}'
const FAIL_EXPECTED = { verdict: 'FAIL', redFlags: ['real blocker'], concerns: [], oneLine: 'bad' }

test('bare JSON parses', () => {
  assert.deepEqual(parseAgentJSON(SHAPE, FALLBACK), EXPECTED)
})

test('fenced ```json``` block parses', () => {
  assert.deepEqual(parseAgentJSON('```json\n' + SHAPE + '\n```', FALLBACK), EXPECTED)
})

test('prose-THEN-JSON: trailing object wins (the truncation-class case)', () => {
  // The prose even contains a stray balanced `{...}` — the real verdict is last.
  const reply = 'After weighing the {hypothetical} edge cases, my verdict is:\n' + SHAPE
  assert.deepEqual(parseAgentJSON(reply, FALLBACK), EXPECTED)
})

test('JSON-THEN-prose: leading object is recovered', () => {
  const reply = SHAPE + '\n\nNote: I also considered the partial-failure path above.'
  assert.deepEqual(parseAgentJSON(reply, FALLBACK), EXPECTED)
})

test('multiple objects: the FULLER-shape object wins over a 1-key earlier one', () => {
  const reply = '{"verdict":"FAIL"}\nactually, on reflection:\n' + SHAPE
  assert.deepEqual(parseAgentJSON(reply, FALLBACK), EXPECTED)
})

test('truncated JSON (never closes): fallback verdict + FULL raw preserved', () => {
  const truncated = 'long reasoning... {"verdict":"PASS","redFlags":["a","b'
  const out = parseAgentJSON(truncated, FALLBACK)
  assert.equal(out.verdict, 'CONCERNS') // fallback, not a coerced wrong verdict
  assert.ok(out._parseError)
  assert.equal(out._raw, truncated) // FULL, not sliced to a prefix
})

test('parse failure preserves raw beyond the old 400-char cap', () => {
  const long = 'x'.repeat(1200) + ' {not valid json'
  const out = parseAgentJSON(long, FALLBACK)
  assert.equal(out._raw.length, long.length)
  assert.ok(out._raw.length > 400)
})

test('null input returns empty marker', () => {
  assert.equal(parseAgentJSON(null, FALLBACK)._parseError, 'empty')
})

test('lastBalancedObject ignores braces inside strings', () => {
  assert.equal(lastBalancedObject('{"a":"}{"}'), '{"a":"}{"}')
  assert.equal(lastBalancedObject('no object here'), null)
})

// --- regression: a verdict followed by a trailing balanced object must NOT be
// shadowed by that trailing object (the P0 the re-audit panel caught: returning
// the last balanced object dropped the real FAIL silently). The real verdict
// carries an expected key (verdict/gate); the trailing snippet does not. ---

test('verdict THEN trailing empty object {}: the real verdict is returned, not {}', () => {
  const reply = FAIL_SHAPE + '\n\nApproved for follow-up. {}'
  assert.deepEqual(parseAgentJSON(reply, FALLBACK), FAIL_EXPECTED)
})

test('verdict THEN trailing config object: the real verdict wins over the snippet', () => {
  const reply = FAIL_SHAPE + '\nSuggested retry config: {"timeout":30,"retries":2}'
  assert.deepEqual(parseAgentJSON(reply, FALLBACK), FAIL_EXPECTED)
})

test('synthesis gate shape: trailing object does not shadow the gate verdict', () => {
  const gateFallback = { gate: 'PASS_WITH_GAPS', p0: [], p1: [], p2: [], clashResolutions: [], summary: '' }
  const gate = '{"gate":"BLOCK","p0":["x"],"p1":[],"p2":[],"clashResolutions":[],"summary":"s"}'
  const out = parseAgentJSON(gate + '\n\nsign-off {}', gateFallback)
  assert.equal(out.gate, 'BLOCK')
  assert.deepEqual(out.p0, ['x'])
})

test('a keyless-only reply falls back durably (verdict NOT silently replaced)', () => {
  // No object carries verdict/redFlags/etc — must NOT return the stray object;
  // return fallback + full raw so the orchestrator can recover.
  const reply = 'I cannot complete this. {"unrelated":true}'
  const out = parseAgentJSON(reply, FALLBACK)
  assert.equal(out.verdict, 'CONCERNS') // fallback
  assert.equal(out._raw, reply) // full reply preserved
  assert.ok(out._parseError)
})

test('balancedObjects returns every outermost object in document order', () => {
  assert.deepEqual(balancedObjects('a {1} b {2} c'), ['{1}', '{2}'])
  assert.deepEqual(balancedObjects('{"x":{"y":1}}'), ['{"x":{"y":1}}']) // nested → one outermost
})

// --- residuals caught by the 3-member re-audit (round 2 of this item); each is a
// distinct way a REAL verdict was being silently dropped/substituted. ---

test('Carmack: an UNBALANCED leading brace in prose must not swallow the real verdict', () => {
  // "the set { a, b, c" opens a brace that never closes; the OLD single-depth
  // scanner consumed the real verdict object as if nested, masking FAIL→fallback.
  const reply = 'Consider the set { a, b, c — weighing those, my verdict:\n' + FAIL_SHAPE
  assert.deepEqual(parseAgentJSON(reply, FALLBACK), FAIL_EXPECTED)
})

test('Kleppmann: a trailing KEYED sign-off snippet must not substitute for the full verdict', () => {
  // The full verdict owns all 4 keys; "P.S. {verdict:PASS}" owns 1 → full wins.
  const reply = FAIL_SHAPE + '\n\nP.S. for the record {"verdict":"PASS"}'
  assert.deepEqual(parseAgentJSON(reply, FALLBACK), FAIL_EXPECTED)
})

test('Torvalds: a fenced schema EXAMPLE before the real verdict must not shadow it', () => {
  const reply = 'Schema:\n```json\n{"verdict":"PASS|FAIL"}\n```\nMy actual verdict:\n' + FAIL_SHAPE
  assert.deepEqual(parseAgentJSON(reply, FALLBACK), FAIL_EXPECTED)
})

test('synthesis-shape variant of the unbalanced-leading-brace case', () => {
  const gateFallback = { gate: 'PASS_WITH_GAPS', p0: [], p1: [], p2: [], clashResolutions: [], summary: '' }
  const gate = '{"gate":"BLOCK","p0":["x"],"p1":[],"p2":[],"clashResolutions":[],"summary":"s"}'
  const reply = 'Given the set { a, b — I conclude:\n' + gate
  assert.equal(parseAgentJSON(reply, gateFallback).gate, 'BLOCK')
})

// --- residuals caught by the 3-member round-3 re-audit; ambiguity guard ensures a
// verdict is never SILENTLY substituted/dropped when the answer is genuinely
// uncertain (two full objects, or a truncated trailing verdict). ---

test('Kleppmann case 1: two full-shape objects → ambiguity flagged with FULL raw (not silent)', () => {
  // Real FAIL first, then an illustrative full PASS appended last. Later-wins still
  // picks the trailing one, but _ambiguous + _raw mean the real verdict is never lost.
  const reply = FAIL_SHAPE + '\nHad it passed it would read:\n' + SHAPE
  const out = parseAgentJSON(reply, FALLBACK)
  assert.equal(out._ambiguous, true)
  assert.equal(out._raw, reply) // full reply preserved — both verdicts recoverable
})

test('Kleppmann case 2: an earlier full object + a TRUNCATED trailing verdict flags ambiguity', () => {
  // Earlier full object parses; the real last verdict is truncated mid-emission
  // (dangling `{` after the last complete object). Must NOT return the earlier one silently.
  const reply = SHAPE + '\nOn reflection: {"verdict":"FAIL","redFlags":["the real one'
  const out = parseAgentJSON(reply, FALLBACK)
  assert.equal(out._ambiguous, true)
  assert.equal(out._raw, reply)
})

test('a clean single verdict with a balanced trailing brace is NOT flagged ambiguous', () => {
  // Guard against over-flagging: balanced trailing content (even an empty object)
  // leaves the single verdict definitive.
  assert.equal(parseAgentJSON(FAIL_SHAPE + '\n\nApproved. {}', FALLBACK)._ambiguous, undefined)
})

test('O(n) scan: a huge unbalanced-brace prose reply still extracts the verdict fast', () => {
  // 50k stray opening braces (the verbose-reasoning threat) before the real verdict.
  // The old O(n^2) per-`{` rescan measured ~2.2s here; the stack pass is instant.
  // Dangling opens are all BEFORE the verdict (leading), so extraction is clean and
  // NOT over-flagged — only a dangling brace AFTER the last object means truncation.
  const reply = '{ '.repeat(50000) + '\nfinal verdict:\n' + FAIL_SHAPE
  const out = parseAgentJSON(reply, FALLBACK)
  assert.equal(out.verdict, 'FAIL') // verdict recovered
  assert.equal(out._ambiguous, undefined) // leading dangling braces are not trailing-truncation
})

test('O(n) scan: many BALANCED sibling objects stay near-linear (outermost dedup is not O(m^2))', () => {
  // The prior huge-input case used UNBALANCED braces (zero spans), so it never
  // exercised the outermost-dedup step — the O(m^2) filter/some was invisible.
  // 40k balanced sibling objects measured ~2.6s with the quadratic filter and
  // ~instant with the start-sorted sweep. Assert both correctness and a generous
  // wall-clock ceiling that the quadratic would blow through.
  const reply = '{} '.repeat(40000) + '\nverdict:\n' + FAIL_SHAPE
  const t0 = process.hrtime.bigint()
  const out = parseAgentJSON(reply, FALLBACK)
  const ms = Number(process.hrtime.bigint() - t0) / 1e6
  assert.equal(out.verdict, 'FAIL') // the full-shape verdict still wins over 40k empty {}
  assert.ok(ms < 1000, `expected near-linear (<1s) for 40k balanced objects, got ${ms.toFixed(0)}ms`)
})

// --- drift guard: the inlined copy in round-audit-panel.mjs MUST behave exactly
// like the canonical functions here (Kleppmann's parity-assertion recommendation). ---

test('inlined round-audit-panel.mjs copy is behaviour-identical to canonical', () => {
  const panelPath = fileURLToPath(new URL('./round-audit-panel.mjs', import.meta.url))
  const src = readFileSync(panelPath, 'utf8')
  const startMark = 'PARITY:json-extract-start'
  const endMark = 'PARITY:json-extract-end'
  const a = src.indexOf(startMark)
  const b = src.indexOf(endMark)
  assert.ok(a >= 0 && b > a, 'PARITY markers not found in round-audit-panel.mjs')
  const region = src.slice(src.indexOf('\n', a) + 1, src.lastIndexOf('\n', b))
  const inlined = new Function(region + '\nreturn { parseAgentJSON, balancedObjects }')()

  const FB = FALLBACK
  const GB = { gate: 'X', p0: [], p1: [], p2: [], clashResolutions: [], summary: '' }
  const battery = [
    [SHAPE, FB], ['```json\n' + SHAPE + '\n```', FB], ['pre {hypothetical}\n' + SHAPE, FB],
    [SHAPE + '\ntrailing note', FB], [FAIL_SHAPE + '\n\nok {}', FB],
    [FAIL_SHAPE + '\nP.S. {"verdict":"PASS"}', FB], ['set { a,b\n' + FAIL_SHAPE, FB],
    ['nope {"unrelated":true}', FB], ['reason {"verdict":"PASS","x', FB], [null, FB],
    ['Given the set { a — :\n{"gate":"BLOCK","p0":["x"]}', GB],
    // Two FULL-shape objects with DIFFERING values — exercises the later-wins
    // tie-break so a `>=`→`>` (later→earlier) inlined drift is caught by parity.
    [FAIL_SHAPE + '\nreconsidered:\n' + SHAPE, FB],
  ]
  for (const [inp, fb] of battery) {
    assert.deepEqual(inlined.parseAgentJSON(inp, fb), canon.parseAgentJSON(inp, fb), 'parseAgentJSON drift on ' + JSON.stringify(inp))
  }
  assert.deepEqual(inlined.balancedObjects('a {1} b {{2}} c'), canon.balancedObjects('a {1} b {{2}} c'))
})
