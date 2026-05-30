// console-preflight.mjs — parallel PREP for the operator-console human queue.
//
// The autonomous backlog's binding constraint is the OPERATOR's time, not Claude's
// build throughput: the queue is dominated by groomed test plans awaiting
// Cowork/human execution, decompose-parents awaiting confirmation, and
// scope-decisions needing an interview. This workflow does all the parallel,
// no-human PREP up front so the skill can then serve the operator ONE item at a
// time with a complete, correct, unambiguous card (see SKILL.md `## The round —
// Console mode` and PROCESS.md `## Operator console mode`).
//
// CRITICAL: this workflow performs NO operator interaction. It never calls
// AskUserQuestion (the operator is a single serial human — interviews belong to the
// skill's serve loop). It only freshness-checks plans and DRAFTS interview material.
//
// PORTABILITY: this workflow is SCHEMA-FREE. Agents return JSON as text and the
// script parses it defensively (parseAgentJSON, inlined below). The Workflow `schema:`
// option is intentionally NOT used — it depends on a StructuredOutput tool that is not
// wired into every harness. See tools/autonomous/workflows/_json.mjs for the rationale.
//
// Invoke from the skill via: Workflow({ scriptPath: "tools/autonomous/workflows/console-preflight.mjs", args: {...} })
//
// args = {
//   items: [ { id, path, kind } ],   // kind ∈ 'groomed-plan'|'decompose-parent'|'scope-groomable'|'decomposable'|'operator-only'
// }
// returns {
//   servingOrder: { confirms[], decisions[], groomedPlans[], operatorOnly[] },
//   freshness:  [ { id, stale, reasons[], recommend } ],
//   interviews: [ { id, shippedAlready, questions:[{header,question,options[]}], context } ],
//   confirms:    [ { id, path, ... } ],
//   operatorOnly:[ { id, path } ]
// }

export const meta = {
  name: 'senkani-console-preflight',
  description: 'Parallel freshness-check + interview prep for the operator console (no operator interaction)',
  phases: [
    { title: 'Freshness', detail: 'Explore agents validate each groomed plan vs current code' },
    { title: 'InterviewPrep', detail: 'pre-audit + adjacent-read + draft questions per decision item' },
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
const items = a.items || []
const byKind = (k) => items.filter((i) => i.kind === k)

const groomed = byKind('groomed-plan')
const confirms = byKind('decompose-parent')
const decisions = [...byKind('scope-groomable'), ...byKind('decomposable')]
const operatorOnly = byKind('operator-only')

log(
  `console-preflight: ${items.length} items — ${groomed.length} groomed, ${confirms.length} confirm-splits, ` +
    `${decisions.length} decisions, ${operatorOnly.length} operator-only`,
)

phase('Freshness')
const freshness = await parallel(
  groomed.map((it) => () =>
    agent(
      `Read the groomed test plan at ${it.path}. Then verify it still matches the CURRENT codebase: ` +
        `do the features-under-test still exist at the referenced paths/symbols? Do the setup commands, ` +
        `execution steps, and acceptance checks still reflect today's behaviour (not the design at groom time)?\n\n` +
        `Respond with ONLY a JSON object (no prose, no code fence) of exactly this shape:\n` +
        `{"id":"${it.id}","stale":<true|false>,"reasons":["..."],"recommend":"run-as-is|re-groom-first|route-to-cowork|operator-hands"}\n` +
        `Set stale=true if any step references code that moved/renamed/changed semantics. ` +
        `recommend route-to-cowork if the plan is GUI-driven, operator-hands if it needs TCC/hardware/credentials.`,
      { label: `fresh:${it.id}`, phase: 'Freshness', agentType: 'Explore' },
    ).then((txt) => parseAgentJSON(txt, { id: it.id, stale: null, reasons: [], recommend: 'run-as-is' })),
  ),
)

phase('InterviewPrep')
const interviews = await parallel(
  decisions.map((it) => () =>
    agent(
      `Prepare — do NOT run — an operator interview for autonomous item "${it.id}" at ${it.path} (kind: ${it.kind}).\n` +
        `1) Pre-audit the codebase to confirm it isn't already shipped.\n` +
        `2) Read its blocked_by chain and any adjacent items the body references.\n` +
        `3) Draft 3-7 questions that, once answered, let a build/decompose round proceed with NO further operator contact.\n` +
        `4) Write a 2-3 sentence context brief the operator reads first.\n\n` +
        `Respond with ONLY a JSON object (no prose, no code fence) of exactly this shape:\n` +
        `{"id":"${it.id}","shippedAlready":<true|false>,"context":"...","questions":[{"header":"<=12 chars","question":"...","options":["...","..."]}]}\n` +
        `Prefer finite option sets over free-text. header must be <=12 chars.`,
      { label: `prep:${it.id}`, phase: 'InterviewPrep' },
    ).then((txt) => parseAgentJSON(txt, { id: it.id, shippedAlready: null, context: '', questions: [] })),
  ),
)

return {
  // Serve order = cheapest operator decision first: confirm splits, then interviews,
  // then run-ready plans, then operator-only hands-on items.
  servingOrder: {
    confirms: confirms.map((c) => c.id),
    decisions: decisions.map((d) => d.id),
    groomedPlans: groomed.map((g) => g.id),
    operatorOnly: operatorOnly.map((o) => o.id),
  },
  freshness: freshness.filter(Boolean),
  interviews: interviews.filter(Boolean),
  confirms,
  operatorOnly,
}
