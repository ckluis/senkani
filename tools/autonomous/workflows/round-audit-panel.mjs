// round-audit-panel.mjs — parallel Luminary panel + synthesis for one autonomous round.
//
// Replaces the SEQUENTIAL role-play of SKILL.md build/groom/scope-groom/decompose
// phases 3-5 (independent audits -> red flags -> clash) and build phase 9 (re-audit)
// with GENUINELY independent subagents — one per roster member, each with a distinct
// lens, run concurrently — then a synthesis agent that resolves clashes into a
// P0/P1/P2 table. Separate contexts beat one model pretending to be three people:
// no anchoring, no self-consistency bias.
//
// The skill stays the orchestrator. This workflow owns ONLY the parallel "body" of
// the audit; the serial "spine" (state lock, pick, branch-integrity, commit, mv,
// index regen) never enters here. See spec/autonomous/PROCESS.md
// `## Ultracode execution model — serial spine vs parallel body`.
//
// PORTABILITY: SCHEMA-FREE. Agents return JSON as text; parseAgentJSON (inlined) parses
// it. The Workflow `schema:` option is intentionally avoided — it depends on a
// StructuredOutput tool not wired into every harness. See ./_json.mjs for rationale.
//
// Invoke from the skill via:  Workflow({ scriptPath: "tools/autonomous/workflows/round-audit-panel.mjs", args: {...} })
//
// args = {
//   itemId:  string,                       // backlog item id, for labels
//   mode:    'build'|'groom'|'scope-groom'|'decompose',
//   stage:   'audit' | 'reaudit',          // audit = before build; reaudit = against shipped diff
//   target:  string,                       // the PLAN text (audit) OR unified diff + test output (reaudit)
//   roster:  string[],                     // e.g. ['Torvalds','Evans','Kleppmann']; falls back to default
//   lenses:  { [member]: string }          // optional per-member lens override
// }
// returns { itemId, stage, panel:[{member,verdict,redFlags,concerns,oneLine}], synthesis:{...} }

export const meta = {
  name: 'senkani-round-audit-panel',
  description: 'Parallel Luminary audit panel + clash synthesis for one autonomous round',
  phases: [
    { title: 'Panel', detail: 'one independent subagent per roster member, distinct lens' },
    { title: 'Synthesis', detail: 'merge verdicts, resolve red flags, emit P0/P1/P2' },
  ],
}

// --- inlined parseAgentJSON (canonical copy at ./_json.mjs — keep behaviour-identical; ---
// --- _json.test.mjs has a parity test that fails on drift) ---
// PARITY:json-extract-start  (do not remove — _json.test.mjs evals between these markers)
// ONE O(n) string-aware brace-stack pass records every OUTERMOST balanced {...}
// object (robust to an unbalanced leading brace in prose; no O(n^2) rescan), then
// pick the object owning the MOST expected fallback keys (full-shape verdict beats
// a fenced schema example or a 1-key sign-off; ties → later = reconsideration).
// Keyless stray objects never stand in for a verdict. AMBIGUITY GUARD: two distinct
// top-score objects, or a dangling `{` after the last complete object (truncated
// trailing verdict), attach _raw + _ambiguous so a verdict is never returned as
// definitive when another may have been intended. See ./_json.mjs for the full contract.
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
  spans.sort((a, b) => a[0] - b[0])
  const outer = []
  let maxEnd = -1
  for (const span of spans) {
    if (span[1] > maxEnd) { outer.push(span); maxEnd = span[1] }
  }
  const danglingPos = stack.length ? stack[stack.length - 1] : -1
  return { objects: outer.map(([i, j]) => s.slice(i, j + 1)), spans: outer, danglingPos }
}
function balancedObjects(s) { return scanObjects(s).objects }
function parseAgentJSON(text, fallback) {
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
  const topAtBest = new Set()
  objects.forEach((slice, idx) => {
    if (spans[idx]) lastObjectEnd = Math.max(lastObjectEnd, spans[idx][1])
    let v
    try { v = JSON.parse(slice) } catch (e) { lastError = String((e && e.message) || e); return }
    if (!isObject(v)) return
    const sc = score(v)
    if (sc > bestScore) { best = v; bestScore = sc; topAtBest.clear(); topAtBest.add(JSON.stringify(v)) }
    else if (sc === bestScore) { best = v; topAtBest.add(JSON.stringify(v)) }
  })
  if (best && (expectedKeys.length === 0 || bestScore >= 1)) {
    const truncatedTail = danglingPos > lastObjectEnd
    if (topAtBest.size > 1 || truncatedTail) return { ...best, _ambiguous: true, _raw: original }
    return best
  }
  return { ...fallback, _parseError: best ? 'no object carried an expected key' : lastError, _raw: original }
}
// PARITY:json-extract-end

// The Workflow runtime may deliver `args` as a JSON-encoded STRING rather than a
// parsed object (observed 2026-05-30). Normalize defensively so both forms work.
const a = (typeof args === 'string' ? (() => { try { return JSON.parse(args) } catch { return {} } })() : (args || {}))
const roster = a.roster && a.roster.length ? a.roster : ['Torvalds', 'Evans', 'Kleppmann']
const stage = a.stage === 'reaudit' ? 'reaudit' : 'audit'

// Default lenses keep the panel DIVERSE, not redundant. Override per-member via args.lenses.
const DEFAULT_LENS = {
  Torvalds: 'correctness, regressions, hidden coupling, "will this break userspace" — be ruthless about edge cases',
  Evans: 'API / UX clarity and conceptual integrity — does this fit the model the user already holds',
  Kleppmann: 'data + state correctness, failure modes, idempotency, behaviour under partial failure',
}
const lensFor = (m) => (a.lenses && a.lenses[m]) || DEFAULT_LENS[m] || 'correctness, risk, and completeness'

const what = stage === 'reaudit' ? 'SHIPPED change (diff + test output)' : 'PLAN'

// Stage semantics — keep audit-stage members from grading the (unbuilt) code.
// At stage=audit the implementation does NOT exist yet: its absence is the build
// round's OUTPUT, NOT a finding. Members were FAILing/BLOCKing on "grep returns
// zero hits / empty git diff / no commit" — auditing code that was never the
// subject. (process-gap-audit-panel-stage-confusion-grades-unbuilt-code-2026-06-01)
const stageGuidance = stage === 'reaudit'
  ? 'This is a RE-AUDIT of the SHIPPED change: audit the actual diff + test output below — verify what was built.'
  : 'This is a PLAN / design / envelope audit. The implementation does NOT exist yet, and its absence is NOT a finding: do NOT grep for, or FAIL / flag / BLOCK on, unbuilt or uncommitted code, an empty `git diff`, a missing commit/branch/worktree, or a missing file/symbol — those are the build round\'s OUTPUT, not a defect in the plan. Evaluate the PROPOSED design itself: its correctness and security properties, failure modes, and whether it fits the stated envelope.'

phase('Panel')
const verdicts = await parallel(
  roster.map((member) => () =>
    agent(
      `You are ${member}, auditing autonomous item "${a.itemId}" (mode: ${a.mode}, stage: ${stage}).\n` +
        `${stageGuidance}\n` +
        `Audit ONLY through your lens: ${lensFor(member)}.\n` +
        `Do not hedge; if it ships clean say PASS.\n\n` +
        `Emit a JSON object of EXACTLY this shape as the LAST thing in your reply. ` +
        `Any reasoning MUST come BEFORE the JSON; the object must be the final token so it parses even if you think out loud first:\n` +
        `{"verdict":"PASS|CONCERNS|FAIL","redFlags":["genuine blockers only — empty if none"],"concerns":["..."],"oneLine":"one-sentence rationale"}\n\n` +
        `=== ${what} ===\n${a.target || '(no target supplied)'}`,
      { label: `${stage}:${member}`, phase: 'Panel' },
    ).then((txt) => ({ member, ...parseAgentJSON(txt, { verdict: 'CONCERNS', redFlags: [], concerns: [], oneLine: '' }) })),
  ),
)
const panel = verdicts.filter(Boolean)

phase('Synthesis')
const synthesisTxt = await agent(
  `Synthesize this ${panel.length}-member ${stage} panel for item "${a.itemId}" into one decision.\n` +
    `${stageGuidance}` +
    `${stage === 'audit' ? ' A member red flag that reduces to "no code exists / empty diff / file or symbol missing" is NOT a real P0 and must NOT drive gate=BLOCK — discount it and gate on PLAN/design defects only.' : ''}\n` +
    `Resolve every redFlag via steelman + rebuttal. gate = BLOCK only if a real P0 correctness/security/data ` +
    `flag is unresolved; PASS_WITH_GAPS if concerns are genuine but acceptable-as-documented-risk; PASS_CLEAN otherwise. ` +
    `P2 items become mandatory follow-up filings.\n\n` +
    `Emit a JSON object of EXACTLY this shape as the LAST thing in your reply. ` +
    `Any reasoning MUST come BEFORE the JSON; the object must be the final token so it parses even if you think out loud first:\n` +
    `{"gate":"PASS_CLEAN|PASS_WITH_GAPS|BLOCK","p0":["..."],"p1":["..."],"p2":["..."],"clashResolutions":["steelman+rebuttal per red flag"],"summary":"..."}\n\n` +
    `PANEL JSON:\n${JSON.stringify(panel, null, 2)}`,
  { label: 'synthesis', phase: 'Synthesis' },
)
const synthesis = parseAgentJSON(synthesisTxt, { gate: 'PASS_WITH_GAPS', p0: [], p1: [], p2: [], clashResolutions: [], summary: '' })

return { itemId: a.itemId, stage, panel, synthesis }
