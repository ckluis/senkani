# Security pack — context

This pack combines **secret-leak detection** with a
**dangerous-command guard**. It pairs a two-phase HandManifest skill
(`secret-leak-vocabulary` + `dangerous-command-vocabulary`) with a
HookRouter policy fragment that denies the three most common
credential-leak and dynamic-eval patterns:

- `API_KEY=` — hard-coded credential assignment.
- `password = "` — hard-coded password literal.
- `eval(` — dynamic-eval injection vector.

The secret-leak phase reuses Senkani's `SecretDetector` vocabulary
(Anthropic / OpenAI / AWS / Stripe / GitHub / HuggingFace / npm /
Twilio / GCP / Slack / generic API key + bearer token patterns) so
the pack stays in lockstep with the rest of the pipeline. The
dangerous-command phase blocks dynamic eval and dynamic SQL when
they appear in tool-call arguments.

Read-only operations on existing secrets (e.g. `senkani vault list`,
`senkani vault test`) are unaffected. To opt out of the deny rules,
run `senkani pack uninstall security`.
