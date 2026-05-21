# reports/

Process artifacts that need cross-quarter audit-trail durability live
here. The directory is tracked in git, so a fresh clone has every
report and `senkani uninstall` / clean-install cycles do not drop the
trail (unlike `~/.senkani/`, which is correctly wiped — process
artifacts stored there have a lifecycle problem).

## Quant-frontier quarterly reports

`reports/quant-frontier-<year>-<quarter>.md` — one file per quarter,
authored on the first business day from `spec/ml_models.md` § Quantization
Frontiers policy + the candidate review against the binding 5-condition
promotion gate.

Each report names:

- **Candidates reviewed** — family, size, license, quant recipe, KL-max,
  imatrix calibration mix, MLX availability, distribution channel.
- **Candidates promoted** — usually zero per quarter; the promotion gate
  is binding.
- **Candidates rejected** — with the specific gate condition(s) that
  failed; re-evaluable next quarter if the gating criterion plausibly
  flips.
- **Forward signal** — which recipe trends to watch next quarter
  (mudler/* APEX cadence, sub-2-bit Gemma 4 quants, ternary research).

The policy surface — what gets tracked, the promotion gate, the
once-per-quarter cadence — lives in `spec/ml_models.md` § Quantization
Frontiers (which is *the* durable spec; this README points back to it).

The 2026-Q2 report is the seed-of-record. The 2026-07-01 review extends
the directory with `quant-frontier-2026-Q3.md`, etc.

## Convention history

- **2026-04-29** — `spec/ml_models.md` § Quantization Frontiers shipped
  with `~/.senkani/reports/quant-frontier-<year>-<quarter>.md` named as
  the canonical path. The 2026-Q2 report was authored there.
- **2026-05-18** — release-v0-3-0 surface-pass walk found the file
  absent on the operator's machine (lost to clean-install cycles 2026-
  05-02/03 + 2026-05-13/14 — the uninstall scanner correctly covers
  `~/.senkani/`). Re-authored to `reports/quant-frontier-2026-Q2.md` at
  the repo root for durability.
- **2026-05-21** — `quant-frontier-report-location-convention-2026-05-18`
  closed: `spec/ml_models.md` policy text updated to name the new path,
  this README added, CHANGELOG entry recorded. Convention durable for
  the 2026-07-01 review and beyond.
