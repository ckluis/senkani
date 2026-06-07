# Quant-frontier review — 2026-Q2

**Cadence:** quarterly, first business day. **Next review:** 2026-07-01.
**Binding constraint:** Two Models, Not Ten — the on-device family stays Gemma 4 and MiniLM-L6. This review is a policy surface; routing changes do not land at review time.
**Promotion gate:** all five conditions from [`spec/ml_models.md` § Quantization Frontiers / Promotion gate (binding)](../spec/ml_models.md) must hold.

## Candidates reviewed

Three recipe drops surfaced between 2026-Q1 and 2026-Q2 with enough signal to warrant a pass against the gate:

1. **APEX recipe family** (mudler/* GGUFs, especially Qwen3.6-35B-A3B and the forward-signal `gemma-4-*-APEX-GGUF` family).
   See [`spec/inspirations/models-inference/qwen3-6-35b-a3b-apex-gguf.md`](../spec/inspirations/models-inference/qwen3-6-35b-a3b-apex-gguf.md).
2. **Ternary Bonsai** (1.58-bit ternary quantization, sub-2-bit footprint research drop).
   See [`spec/inspirations/models-inference/ternary-bonsai.md`](../spec/inspirations/models-inference/ternary-bonsai.md).
3. **dots.ocr** (OCR-specialist VLM with strong document-understanding behavior on benchmark slices).
   See [`spec/inspirations/models-inference/dots-ocr.md`](../spec/inspirations/models-inference/dots-ocr.md).

## Candidates promoted

**Zero.** No candidate swap lands this quarter. Both the architectural family rule and per-recipe metrics fall short of the binding gate for each candidate evaluated. This is the expected baseline outcome — Two Models, Not Ten is what makes Senkani's behavior stable across operator-machine variance, and the bar for replacing a tier's quant is intentionally high.

## Candidates rejected (with gate disposition)

### APEX — rejected as a swap, *absorbed as policy*

APEX is the most interesting recipe-class win this quarter. The `gemma-4-*-APEX-GGUF` line shows consistent KL-max improvements over baseline llama.cpp Q4_K_M at the same RAM footprint on the families where it ships today (initial signal from Qwen3.6-35B-A3B), and the imatrix calibration mix is closer to Senkani's tool-use surface than the typical pretrained-prompt mix.

| Gate | Verdict | Notes |
|---|---|---|
| (1) Quality (≥10 % KL-max win at equal-or-smaller RAM) | **Plausible on the forward signal, unmeasured on Gemma 4 today.** | `gemma-4-*-APEX-GGUF` artifacts are forward-signal — not yet shipped for the specific Gemma 4 26B A4B variants Senkani routes to. Without a real measurement against the incumbent quant on the operator's hardware, gate (1) cannot be claimed. |
| (2) Coverage (imatrix chat + code + tool-calling) | ✅ Close. APEX mixes weight chat + code generously; tool-calling coverage is implicit through the chat-with-tool-emit calibration set. | Best-in-class for our request shape; this is the durable take-away. |
| (3) Real-machine `senkani ml-eval` ≥ `acceptable` | **Not run.** | No `gemma-4-26B-A4B-APEX` artifact existed at review time for the operator to actually run the harness against. |
| (4) Same family (Gemma 4) under new recipe | ✅ Yes — Gemma 4, new quant recipe. | Architecturally legal. |
| (5) Permissive license | ✅ Apache-2.0 (Gemma terms). | Compatible. |

**Disposition:** Reject the *swap* (gates 1 and 3 are not provably cleared). **Absorb the recipe wins as policy** for the next review cycle:
- KL-max becomes the **headline metric** for future quant-frontier comparisons. Perplexity stays as supporting evidence; benchmark suites stay as second-order signal.
- **Imatrix calibration mix becomes the target** to beat — any future candidate's calibration mix is graded against APEX's coverage of chat + code + tool-calling at minimum.
- **Per-variant "best for" labels** become the documentation convention: each Gemma 4 quant Senkani routes to gets a one-line "best for: <surface>" hint that mirrors APEX's published convention. Cleaner than a single quality score across heterogeneous task surfaces.

If a `gemma-4-26B-A4B-APEX-GGUF` lands in 2026-Q3 with a measurable KL-max win on the operator's hardware, the swap becomes a 2026-Q3 build item — not a policy change, a routing change in `ModelRouter` / `TierScorer` (U.1), gated on `senkani ml-eval` against the live harness.

### Ternary Bonsai — rejected (gate 1 fails on quality drift), *kept as forward signal*

Bonsai's 1.58-bit ternary quantization is aggressive and the research drop demonstrates that sub-2-bit representations are viable for small reasoning models. The footprint is genuinely attractive — an M-Mini-tier (≤4 GB) Gemma 4 quant would unlock workflow tiers Senkani currently can't address on 16 GB hardware.

| Gate | Verdict | Notes |
|---|---|---|
| (1) Quality | ❌ FAIL. Published KL-max drift at 1.58 bits is substantially worse than Q4_K_M on Senkani's request surface (chat + code + tool-calling); the wins live in synthetic perplexity at smaller hidden-state widths than Gemma 4's. | Bonsai's headline result is on a *different model class* and doesn't transfer. |
| (2) Coverage | n/a — gate 1 already disqualifies. | — |
| (3) Real-machine eval | n/a. | — |
| (4) Family | ⚠ Bonsai is a *recipe*, not a family — would apply to Gemma 4. Legal in spirit. | — |
| (5) License | ✅ Permissive. | — |

**Disposition:** Reject this quarter, **track as forward signal** for any future Gemma 4 release that ships pre-trained for ≤2-bit quantization (similar to how the original Bonsai paper paired the recipe with model-side awareness). If Gemma 4.1 or a successor lands with quantization-aware training baked in, Bonsai (or its 2026-vintage successor recipe) gets a re-evaluation. Until then: forward-signal in next quarter's report opening.

### dots.ocr — rejected as a third family

dots.ocr posts compelling document-understanding numbers on benchmark slices Senkani cares about (document layout, OCR-on-scanned-PDF, structured-extraction-from-screenshots). The narrative around it as a routing target for `senkani_vision` is real — current vision routing leans on Gemma 4's general vision capability for OCR tasks where a specialist would outperform.

| Gate | Verdict | Notes |
|---|---|---|
| (4) Same family rule | ❌ **HARD REJECT.** dots.ocr is its own family — neither Gemma 4 nor the MiniLM line. Adding it to the on-device tier list violates Two Models, Not Ten by construction. | Gate (4) is binding regardless of any other gate's outcome. |

**Disposition:** Reject for the on-device tier list. **Flag as a candidate for the OCR-specialist path *inside* `senkani_vision`** — a sub-routing decision *within* the vision tool, not a top-level model family addition. That sub-routing surface is out of W.5 scope; the relevant follow-up item is a future `senkani_vision` enhancement that the routing surface (U.1) owns, not the quant-frontier surface.

If `senkani_vision` ever grows internal sub-routing for OCR-shaped intents, dots.ocr returns to the candidate list as the leading specialist — but always as a per-tool internal choice, never as a third top-level family.

## Forward signal — what to watch in 2026-Q3

- **Real `gemma-4-26B-A4B-APEX-GGUF` artifacts** on Hugging Face. The forward signal here is the most actionable; a measurable KL-max win on the operator's hardware turns gate (1) green and the swap becomes a build round.
- **Apple-Silicon MLX parity for any APEX-class recipe.** MLX is the primary path; Metal/MLX-vs-GGUF behavior parity has historically lagged on aggressive quant recipes. Improvement here lowers the conversion cost for any future swap.
- **Quantization-aware-trained Gemma 4 successor.** Would re-open the Bonsai (or successor) conversation immediately at the smaller tiers.
- **MoE expert-cluster routing.** Gemma 4 26B A4B's 128 routed experts with 8 active per token (see `spec/ml_models.md` "MoE routing insight") are a future routing enhancement orthogonal to quant-frontier — flagged here so the cross-impact stays visible.
- **Imatrix calibration mix benchmarking.** Now that APEX has set the bar, future quant candidates should publish their calibration mix breakdown the way APEX does. Reports without it become harder to evaluate.

## Process notes for next quarter

This is the durable first-report convention; subsequent quarters should follow the same shape:

1. **Candidates reviewed** — three to seven; more than seven and the cadence is becoming a routing-surface bypass.
2. **Promoted / rejected / forward-signal** — explicit per candidate, with the binding gate(s) that decided.
3. **Per-candidate inspiration link** under `spec/inspirations/models-inference/` so the audit trail compounds.
4. **Process notes section** at the bottom if a process tweak surfaced (e.g. "KL-max should be required, not optional" — landed in this report's APEX absorption).
5. **Audit-trail cross-link:** each promote (rare) writes a paired backlog item under `spec/autonomous/backlog/` so the routing follow-up is tracked end-to-end; rejected-as-forward-signal candidates earn a re-check entry on the next quarter's review agenda.

— Quant-frontier review 2026-Q2 closes here. Two Models, Not Ten holds. Next review 2026-07-01.
