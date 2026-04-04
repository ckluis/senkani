# Senkani Testing — Quality Evals Index

Evals measure the QUALITY and EFFECTIVENESS of Senkani's compression, not just "does it work."
These are the metrics that prove the thesis. Run after every significant change.

---

## Eval Scripts

| Script | Measures | Baseline | Target |
|--------|----------|----------|--------|
| `eval-01-filter-savings.sh` | Byte savings per command family | 0% (passthrough) | >60% avg |
| `eval-02-cache-hit-rate.sh` | Cache effectiveness across session | 0% | >50% on real session |
| `eval-03-symbol-accuracy.sh` | Symbol indexer precision/recall | N/A | >90% on known codebase |
| `eval-04-validator-coverage.sh` | Validators found vs installed | N/A | >80% detection rate |
| `eval-05-secret-precision.sh` | False positive/negative rate on secrets | N/A | 0 false negatives |
| `eval-06-parse-accuracy.sh` | Structured extraction accuracy | N/A | >90% field extraction |
| `eval-07-mcp-latency.sh` | Tool call response time | N/A | <100ms for deterministic, <2s for ML |
| `eval-08-session-savings.sh` | End-to-end token savings in simulated session | $0 | >$2 saved per 100 commands |
| `eval-09-compare-consistency.sh` | Reproducibility of compare results | N/A | <1% variance across runs |
| `eval-10-self-improvement.sh` | Autoresearch-style: tweak rules, measure, keep/revert | Baseline | Monotonic improvement |

---

## Eval 01: Filter Savings by Command

**Purpose:** Measure how much each filter rule saves on real command output.

**Method:**
1. Run each command with `SENKANI_MODE=passthrough` → capture raw bytes
2. Run same command with `SENKANI_MODE=filter` → capture filtered bytes
3. Calculate savings percentage per command

**Expected baselines:**

| Command | Raw (est) | Target Savings | Why |
|---------|-----------|----------------|-----|
| `git status` (colored) | ~500B | >10% | ANSI stripping + blank runs |
| `git log --oneline -50` (colored) | ~3KB | >15% | ANSI stripping |
| `git clone` (progress) | ~50KB | >80% | Progress bar stripping |
| `npm install` (verbose) | ~100KB | >85% | Download noise, WARN lines |
| `cargo build` (verbose) | ~50KB | >70% | Compiling lines grouped |
| `cat large-file.txt` (>10KB) | ~50KB | >80% | 10KB truncation |
| `find . -name "*.swift"` (deep) | ~10KB | >50% | 100-line tail |
| `swift test` (verbose) | ~20KB | >30% | ANSI + group similar |

**Self-improvement loop:** If a command family consistently saves <20%, investigate whether the rule is too conservative. Propose a rule adjustment, re-run eval, keep if savings improve without losing important output.

---

## Eval 02: Cache Hit Rate

**Purpose:** Measure how often ReadCache prevents re-reading unchanged files.

**Method:**
1. Start MCP session
2. Read 10 files via senkani_read
3. Read same 10 files again
4. Check senkani_session(stats) for cache hit rate

**Expected:** 100% hit rate on second read (all files unchanged).

**Degraded test:** Modify 3 of 10 files between reads. Expected: 70% hit rate (7 cached, 3 re-read).

---

## Eval 03: Symbol Accuracy

**Purpose:** Measure precision and recall of the regex symbol indexer.

**Method:**
1. Index the senkani project itself
2. Compare against a manually curated "ground truth" list of key symbols
3. Calculate: precision = (correct results / total results), recall = (found symbols / total symbols)

**Ground truth symbols (manually verified):**

```
FilterEngine (class, Sources/Shared/TokenFilter/FilterEngine.swift)
FilterPipeline (struct, Sources/Core/FilterPipeline.swift)
SecretDetector (enum, Sources/Core/SecretDetector.swift)
SessionMetrics (class, Sources/Core/SessionMetrics.swift)
SymbolIndex (struct, Sources/Indexer/SymbolIndex.swift)
ValidatorRegistry (class, Sources/Core/ValidatorRegistry.swift)
MCPSession (class, Sources/MCP/Session/MCPSession.swift)
ReadCache (class, Sources/MCP/Session/ReadCache.swift)
ANSIStripper (enum, Sources/Shared/TokenFilter/ANSIStripper.swift)
CommandMatcher (enum, Sources/Shared/TokenFilter/CommandMatcher.swift)
```

**Target:** All 10 found, correct file + kind. Precision >90%, Recall >85%.

---

## Eval 04: Validator Coverage

**Purpose:** Measure how many installed tools the validator registry actually finds.

**Method:**
1. Manually check which validators are installed: `which swiftc tsc python3 node go ruff mypy`
2. Run `senkani validate --list dummy`
3. Compare: does the registry find all installed tools?

**Target:** 100% of manually-found tools also found by registry.

---

## Eval 05: Secret Detection Precision

**Purpose:** Zero false negatives (never miss a real secret). Low false positives.

**Method:**
1. Feed known secrets through SecretDetector → must all be caught
2. Feed normal code through → should have zero false positives

**Test corpus:**
```
# True positives (must detect):
sk-ant-api03-abcdefghijklmnopqrstuvwxyz1234567890
sk-proj-abcdefghijklmnopqrstuvwxyz1234567890
AKIAIOSFODNN7EXAMPLE
ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij
Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abcdef

# True negatives (must NOT detect):
let sketch = "sk-etch-a-sketch"
let task = "ask-anything"
git push origin main
npm install express
```

**Target:** 100% true positive rate, <5% false positive rate.

---

## Eval 06: Parse Accuracy

**Purpose:** Measure how accurately senkani_parse extracts structured data from build/test output.

**Method:** Feed known outputs with known structures, verify extraction.

**Test cases:**
1. Swift Testing output with 3 passed, 1 failed → must extract correct counts + failure details
2. swiftc error output with 2 errors, 1 warning → must extract all with file:line
3. Python traceback → must categorize as correct error type
4. npm test output with Jest results → must extract pass/fail counts

**Target:** >90% field extraction accuracy across all test cases.

---

## Eval 07: MCP Tool Latency

**Purpose:** Ensure tools respond within acceptable time budgets.

**Method:** Time each tool call via JSON-RPC, measure p50 and p99.

**Budgets:**

| Tool | p50 Target | p99 Target |
|------|-----------|-----------|
| senkani_session | <10ms | <50ms |
| senkani_read (cached) | <5ms | <20ms |
| senkani_read (uncached) | <50ms | <200ms |
| senkani_exec (echo) | <100ms | <500ms |
| senkani_search | <20ms | <100ms |
| senkani_fetch | <30ms | <150ms |
| senkani_explore | <30ms | <150ms |
| senkani_validate | <1s | <5s |
| senkani_parse | <10ms | <50ms |
| senkani_embed | <2s | <5s |
| senkani_vision | <3s | <10s |

---

## Eval 08: Session Savings Simulation

**Purpose:** Estimate real-world savings from a full coding session.

**Method:**
1. Record a sequence of 100 typical commands from a real Claude Code session
2. Run them through senkani with filter mode → measure total savings
3. Run same sequence with passthrough mode → measure baseline
4. Calculate: dollars saved = (raw tokens - filtered tokens) / 1M * $3

**Simulated session (100 commands):**
```
20x git status
15x cat file.swift (various files, ~5KB avg)
10x git diff
5x git log --oneline -20
10x swift build
5x swift test
10x grep/rg for symbols
5x npm install (in a JS subproject)
5x cat large-file (>10KB)
5x senkani_read (re-reads of cached files)
10x misc (ls, echo, etc.)
```

**Target:** >$2 saved per simulated session (at $3/M input tokens).

---

## Eval 09: Compare Consistency

**Purpose:** Verify that `senkani compare` produces consistent results across runs.

**Method:** Run `senkani compare -- git log --oneline -50` five times, compare the savings percentages.

**Target:** <1% variance between runs (deterministic filtering).

---

## Eval 10: Self-Improvement Loop (pi-autoresearch pattern)

**Purpose:** Use the eval results to automatically improve filter rules.

**Method:**
1. Run eval-01 (filter savings) → record baseline per command
2. For each command with savings <50%:
   a. Analyze the raw output to identify patterns that could be filtered
   b. Propose a new filter rule or rule adjustment
   c. Apply the change
   d. Re-run eval-01 for that command
   e. If savings improved AND no important content lost → keep
   f. If savings didn't improve OR content was lost → revert
3. Repeat until convergence (no further improvements found)

**Safeguards:**
- Never auto-apply changes to existing rules (only propose new rules)
- Always keep a "before" snapshot to revert
- Human reviews accumulated changes before committing
- Maximum 10 iterations per improvement cycle

**Metrics tracked:**
- Total savings before/after cycle
- Number of rules added/modified
- Content loss incidents (any important line removed by filtering)

This is the foundation for making Senkani self-improving: measure → adjust → verify → keep.
