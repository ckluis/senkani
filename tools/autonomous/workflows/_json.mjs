// _json.mjs — defensive JSON extraction for schema-free workflow agents.
//
// The Workflow runtime's `schema:` option forces subagents to call a
// StructuredOutput tool, which is NOT wired in on every harness (some expose it as
// StructuredOutputTool, some not at all). To stay portable, the senkani workflows
// ask agents to RETURN JSON AS TEXT and parse it here instead of using schema mode.
//
// NOTE: workflow scripts run inline (the Workflow tool reads the file as one script);
// this helper's source is INLINED into each workflow rather than imported, because the
// runtime does not resolve cross-file imports. Kept here as the canonical reference.
// When you change these functions here, mirror the edit into the inlined copy in
// `round-audit-panel.mjs`. `_json.test.mjs` has a parity test that fails on drift.
//
// EXTRACTION CONTRACT (hardened over four re-audit rounds of
// process-gap-round-audit-panel-agent-json-truncation-2026-05-31):
// a panel member may reason in prose and emit the verdict object anywhere, with
// stray braces / fenced schema examples / sign-off snippets around it. We must
// return the INTENDED verdict object and NEVER silently substitute a stray object
// or mask a real verdict into the fallback. The strategy:
//   1. ONE O(n) string-aware pass with a brace stack records every balanced
//      {...} object (innermost on each close). This is robust to an UNBALANCED
//      leading brace in prose (e.g. "the set { a, b") — the real object still
//      closes and is recorded — without the O(n^2) per-`{` rescan an earlier
//      attempt used (Carmack's availability flag).
//   2. Keep only OUTERMOST objects (drop ones nested inside a larger candidate).
//   3. Among objects that parse, pick the one owning the MOST expected fallback
//      keys (the full-shape verdict beats a 1-key sign-off or fenced schema
//      example); ties break to the LATER object (an honest reconsideration).
//   4. AMBIGUITY GUARD: if two DISTINCT objects tie at the top score, or a
//      dangling unmatched `{` AFTER the last complete object suggests a truncated
//      trailing verdict, attach the FULL reply as `_raw` and set `_ambiguous` so a
//      verdict is never returned as definitive when another may have been intended
//      (Kleppmann's two-full-shape / truncation residual).
//   5. If no parsed object owns an expected key, return the durable fallback with
//      the FULL reply in `_raw` (never a 400-char prefix, never a stray object).

// Single O(n) pass: returns every OUTERMOST balanced object (document order) plus
// the position of the latest dangling unmatched `{` (or -1). String/escape aware.
function scanObjects(s) {
  const spans = []
  const stack = []
  let inStr = false, esc = false
  for (let i = 0; i < s.length; i++) {
    const c = s[i]
    if (inStr) {
      if (esc) esc = false
      else if (c === '\\') esc = true
      else if (c === '"') inStr = false
      continue
    }
    if (c === '"') inStr = true
    else if (c === '{') stack.push(i)
    else if (c === '}') { if (stack.length) spans.push([stack.pop(), i]) }
  }
  // Keep only outermost spans via a start-sorted linear sweep (O(m log m), not the
  // O(m^2) filter/some an earlier attempt used): brace starts are distinct, so once
  // sorted by start a span is outermost iff its end exceeds every prior span's end.
  spans.sort((a, b) => a[0] - b[0])
  const outer = []
  let maxEnd = -1
  for (const span of spans) {
    if (span[1] > maxEnd) { outer.push(span); maxEnd = span[1] }
  }
  // stack is strictly increasing (pushes happen at increasing i); its top is the
  // latest unmatched open. -1 when every brace was balanced.
  const danglingPos = stack.length ? stack[stack.length - 1] : -1
  return { objects: outer.map(([i, j]) => s.slice(i, j + 1)), spans: outer, danglingPos }
}

// Public: outermost balanced {...} objects in document order.
export function balancedObjects(s) { return scanObjects(s).objects }

// Back-compat helper: the LAST outermost balanced object, or null.
export function lastBalancedObject(s) {
  const o = balancedObjects(s)
  return o.length ? o[o.length - 1] : null
}

export function parseAgentJSON(text, fallback) {
  if (text == null) return { ...fallback, _parseError: 'empty' }
  const original = String(text)
  const expectedKeys = (fallback && typeof fallback === 'object') ? Object.keys(fallback) : []
  const isObject = (v) => v && typeof v === 'object' && !Array.isArray(v)
  const score = (v) => (expectedKeys.length === 0
    ? 1
    : expectedKeys.reduce((n, k) => n + (Object.prototype.hasOwnProperty.call(v, k) ? 1 : 0), 0))

  const { objects, spans, danglingPos } = scanObjects(original)
  let best = null, bestScore = -1, lastError = 'no JSON object found'
  let lastObjectEnd = -1
  const topAtBest = new Set() // canonical strings of objects tying at the top score
  objects.forEach((slice, idx) => {
    if (spans[idx]) lastObjectEnd = Math.max(lastObjectEnd, spans[idx][1])
    let v
    try { v = JSON.parse(slice) } catch (e) { lastError = String((e && e.message) || e); return }
    if (!isObject(v)) return
    const sc = score(v)
    if (sc > bestScore) { best = v; bestScore = sc; topAtBest.clear(); topAtBest.add(JSON.stringify(v)) }
    else if (sc === bestScore) { best = v; topAtBest.add(JSON.stringify(v)) } // later wins
  })

  if (best && (expectedKeys.length === 0 || bestScore >= 1)) {
    // Truncated trailing verdict: a dangling `{` AFTER the last complete object
    // (not merely an unbalanced brace BEFORE it, which extracts cleanly).
    const truncatedTail = danglingPos > lastObjectEnd
    if (topAtBest.size > 1 || truncatedTail) {
      return { ...best, _ambiguous: true, _raw: original }
    }
    return best
  }
  return {
    ...fallback,
    _parseError: best ? 'no object carried an expected key' : lastError,
    _raw: original,
  }
}
