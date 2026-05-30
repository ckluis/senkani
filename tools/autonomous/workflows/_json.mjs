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

export function parseAgentJSON(text, fallback) {
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
    return { ...fallback, _parseError: String(e && e.message || e), _raw: String(text).slice(0, 400) }
  }
}
