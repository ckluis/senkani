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

// --- inlined parseAgentJSON (canonical copy at ./_json.mjs) ---------------------
function parseAgentJSON(text, fallback) {
  if (text == null) return { ...fallback, _parseError: 'empty' }
  let s = String(text).trim()
  const fence = s.match(/```(?:json)?\s*([\s\S]*?)```/i)
  if (fence) s = fence[1].trim()
  const start = s.indexOf('{')
  const end = s.lastIndexOf('}')
  if (start >= 0 && end > start) s = s.slice(start, end + 1)
  try {
    return JSON.parse(s)
  } catch (e) {
    return { ...fallback, _parseError: String((e && e.message) || e), _raw: String(text).slice(0, 400) }
  }
}

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

phase('Panel')
const verdicts = await parallel(
  roster.map((member) => () =>
    agent(
      `You are ${member}, auditing autonomous item "${a.itemId}" (mode: ${a.mode}, stage: ${stage}).\n` +
        `Audit ONLY through your lens: ${lensFor(member)}.\n` +
        `Do not hedge; if it ships clean say PASS.\n\n` +
        `Respond with ONLY a JSON object (no prose, no code fence) of exactly this shape:\n` +
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
    `Resolve every redFlag via steelman + rebuttal. gate = BLOCK only if a real P0 correctness/security/data ` +
    `flag is unresolved; PASS_WITH_GAPS if concerns are genuine but acceptable-as-documented-risk; PASS_CLEAN otherwise. ` +
    `P2 items become mandatory follow-up filings.\n\n` +
    `Respond with ONLY a JSON object (no prose, no code fence) of exactly this shape:\n` +
    `{"gate":"PASS_CLEAN|PASS_WITH_GAPS|BLOCK","p0":["..."],"p1":["..."],"p2":["..."],"clashResolutions":["steelman+rebuttal per red flag"],"summary":"..."}\n\n` +
    `PANEL JSON:\n${JSON.stringify(panel, null, 2)}`,
  { label: 'synthesis', phase: 'Synthesis' },
)
const synthesis = parseAgentJSON(synthesisTxt, { gate: 'PASS_WITH_GAPS', p0: [], p1: [], p2: [], clashResolutions: [], summary: '' })

return { itemId: a.itemId, stage, panel, synthesis }
