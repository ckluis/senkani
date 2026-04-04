# Senkani Testing — Acceptance Criteria Index

Every feature has testable acceptance criteria. Tests are organized by module and phase.
Run `testing/run-all.sh` to execute everything, or run individual scripts.

---

## Test Scripts

| Script | Module | Tests | Time |
|--------|--------|-------|------|
| `test-01-cli-commands.sh` | CLI | 11 commands exist and respond | ~10s |
| `test-02-filter-engine.sh` | Filter | 44 rules produce expected output | ~15s |
| `test-03-secret-detection.sh` | Core | 7 secret patterns detected and redacted | ~5s |
| `test-04-symbol-indexer.sh` | Indexer | Index, search, fetch, explore work | ~10s |
| `test-05-validators.sh` | Core | Auto-detect + validate across languages | ~15s |
| `test-06-mcp-server.sh` | MCP | Server starts, responds to all 10 tools | ~30s |
| `test-07-hooks.sh` | Hooks | Intercept Read/Bash/Grep, respect toggles | ~10s |
| `test-08-compare.sh` | CLI | A/B comparison table renders correctly | ~10s |
| `test-09-gui-launch.sh` | GUI | App launches, stays running, renders window | ~10s |
| `test-10-metrics-flow.sh` | MCP+GUI | Metrics JSONL written and readable | ~10s |
| `test-11-toggles.sh` | All | Feature toggles work at all layers | ~15s |
| `test-12-ml-models.sh` | MCP | Embedding + vision model download and inference | ~5min |

---

## Acceptance Criteria by Feature

### CLI Commands (test-01)
- [ ] `senkani --help` prints help with all 11 subcommands listed
- [ ] `senkani --version` prints "0.1.0"
- [ ] `senkani exec -- echo hello` returns "hello" with exit code 0
- [ ] `senkani exec -- false` returns exit code 1
- [ ] `senkani exec --no-filter -- git status` passes through unfiltered
- [ ] `senkani exec --stats-only -- git status` measures without modifying
- [ ] `senkani init --global` creates hook file at ~/.claude/hooks/
- [ ] `senkani stats --file /tmp/test.jsonl` reads and displays metrics
- [ ] `senkani stats --compare` compares two session files
- [ ] `senkani validate --list dummy` shows installed validators
- [ ] `senkani mcp-install` creates .mcp.json with correct binary path

### Filter Engine (test-02)
- [ ] ANSI escape codes stripped from colored git output
- [ ] Blank line runs collapsed (max 1)
- [ ] `git clone` progress bars stripped (Receiving objects, Resolving deltas)
- [ ] `git log` truncated to 50 lines
- [ ] `git diff` truncated to 16KB
- [ ] `npm install` noise stripped (WARN, added lines grouped)
- [ ] `cat` large file truncated at 10KB
- [ ] `find` output limited to 100 results
- [ ] `grep`/`rg` output limited to 100 results + 16KB
- [ ] Unknown commands pass through unchanged
- [ ] Empty output passes through unchanged
- [ ] FilterResult tracks rawBytes and filteredBytes correctly
- [ ] savingsPercent calculated correctly (0% for no savings, never negative)

### Secret Detection (test-03)
- [ ] `sk-ant-api03-xxxxx...` detected as ANTHROPIC_API_KEY
- [ ] `sk-proj-xxxxx...` detected as OPENAI_API_KEY
- [ ] `AKIAIOSFODNN7EXAMPLE` detected as AWS_ACCESS_KEY_ID
- [ ] `ghp_xxxxx...` detected as GITHUB_TOKEN
- [ ] `Bearer eyJxxx...` detected as BEARER_TOKEN
- [ ] `api_key = 'xxxxx...'` detected as GENERIC_API_KEY
- [ ] Clean text returns unchanged with empty patterns list
- [ ] Redacted text contains `[REDACTED:PATTERN_NAME]`
- [ ] Warning printed to stderr when secret found

### Symbol Indexer (test-04)
- [ ] `senkani index` creates .senkani/index.json
- [ ] Index contains correct symbol count (should find 150+ symbols in senkani project)
- [ ] `senkani search FilterEngine` finds the struct
- [ ] `senkani search --kind function process` finds process() method
- [ ] `senkani fetch FilterEngine` returns only the struct's lines (not whole file)
- [ ] `senkani fetch FilterEngine` shows "XX% saved" header
- [ ] `senkani explore Sources/Core` shows symbols grouped by file
- [ ] Incremental update: modify a file, re-index, only that file re-indexed
- [ ] Non-existent symbol returns helpful error with suggestions

### Validators (test-05)
- [ ] `senkani validate --list dummy` shows at least 5 installed validators
- [ ] Valid Swift file: "✓ [type] swift-typecheck"
- [ ] Invalid Swift file (type error): "✗ [type] swift-typecheck" + error message
- [ ] Valid JSON: "✓ [syntax] json-check"
- [ ] Invalid JSON: "✗ [syntax] json-check" + error location
- [ ] Invalid Python: "✗ [syntax] python-compile" + SyntaxError
- [ ] Non-existent file: error message
- [ ] Unsupported extension: shows available validators

### MCP Server (test-06)
- [ ] Server starts without crashing
- [ ] `initialize` returns capabilities and server info
- [ ] `tools/list` returns exactly 10 tools
- [ ] `senkani_session(stats)` returns session stats
- [ ] `senkani_read(Package.swift)` returns file content with savings header
- [ ] `senkani_read(Package.swift)` second call returns "cached" (if cache enabled)
- [ ] `senkani_exec(echo hello)` returns "hello" with savings header
- [ ] `senkani_search(Filter)` returns matching symbols
- [ ] `senkani_fetch(FilterEngine)` returns symbol source
- [ ] `senkani_explore(Sources/Core)` returns symbol tree
- [ ] `senkani_validate(file.swift)` runs local validator
- [ ] `senkani_parse(test output)` extracts structured results
- [ ] `senkani_session(config: {filter: false})` disables filtering
- [ ] `senkani_session(reset)` clears cache and metrics

### Hooks (test-07)
- [ ] Hook script is executable
- [ ] Read tool call → blocked with senkani_read redirect reason
- [ ] Bash read-only command → blocked with senkani_exec redirect reason
- [ ] Bash write command (git commit) → passes through unblocked
- [ ] Bash with redirect (echo > file) → passes through unblocked
- [ ] Grep with simple word → blocked with senkani_search redirect
- [ ] Grep with regex → passes through unblocked
- [ ] `SENKANI_MODE=passthrough` → all pass through
- [ ] `SENKANI_INTERCEPT=off` → all pass through
- [ ] `SENKANI_INTERCEPT_READ=off` → Read passes, Bash/Grep still intercepted

### Compare (test-08)
- [ ] `senkani compare -- git log --oneline -10` shows 4-row comparison table
- [ ] Table has passthrough, filter only, secrets only, all features rows
- [ ] Savings percentages are non-negative
- [ ] Bar chart renders (█ characters)
- [ ] Large output (72KB) doesn't hang (pipe deadlock fixed)

### GUI Launch (test-09)
- [ ] `swift run SenkaniApp` launches without crashing
- [ ] App stays running for at least 5 seconds
- [ ] Window appears on screen
- [ ] App terminates cleanly on SIGTERM

### Metrics Flow (test-10)
- [ ] `senkani exec` with SENKANI_METRICS_FILE writes to specified path
- [ ] Metrics file contains valid JSONL
- [ ] Each line has: command, rawBytes, filteredBytes, savedBytes, timestamp
- [ ] `senkani stats --file` reads and displays the metrics correctly

### Feature Toggles (test-11)
- [ ] `SENKANI_MODE=passthrough senkani exec -- git status` returns raw output
- [ ] `senkani exec --no-filter -- git -c color.ui=always log` preserves ANSI
- [ ] `senkani exec --no-secrets -- cat secret-file.txt` shows raw secrets
- [ ] MCP server respects env vars at startup
- [ ] MCP `senkani_session(config)` changes toggles at runtime

### ML Models (test-12)
- [ ] `senkani_embed` first call downloads MiniLM-L6 model
- [ ] Embedding search returns relevant files (score > 0.5 for exact match)
- [ ] `senkani_vision` first call downloads vision model
- [ ] Vision tool returns text description of a screenshot
- [ ] Models cached after first download (second call is fast)
