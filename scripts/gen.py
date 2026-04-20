#!/usr/bin/env python3
"""
senkani website page generator.

Run from repo root: python3 scripts/gen.py

Generates every templated page (MCP tool refs, CLI command refs, pane refs)
from in-file data tables + shared HTML skeletons. Hand-written pages
(landing, what-is-senkani, concept pages, guide pages, hub indexes) live
alongside and are NOT overwritten — the generator only writes to paths
under /reference/mcp/<tool>/, /reference/cli/<cmd>/, and
/reference/panes/<type>/.

Zero dependencies. Stdlib only.
"""

from __future__ import annotations
import os
import html
import sys
from pathlib import Path
from textwrap import dedent

ROOT = Path(__file__).resolve().parent.parent

HEAD = '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{title}</title>
<meta name="description" content="{desc}">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800;900&family=JetBrains+Mono:wght@400;500;600;700&display=swap" rel="stylesheet">
<link rel="stylesheet" href="__BASE__assets/theme.css">
</head>
<body>
<a href="#main" class="skip-nav">Skip to main content</a>
<nav class="topnav" aria-label="Primary navigation">
  <a class="wordmark" href="__BASE__">sen<span class="accent">kani</span><small>compression layer for AI coding agents</small></a>
  <button class="topnav-hamburger" aria-label="Open navigation menu" aria-expanded="false" aria-controls="topnav-links"><span></span><span></span><span></span></button>
  <div class="topnav-links" id="topnav-links">
    <a href="__BASE__docs/what-is-senkani.html">What is it?</a>
    <a href="__BASE__docs/concepts/">Concepts</a>
    <a href="__BASE__docs/reference/">Reference</a>
    <a href="__BASE__docs/guides/">Guides</a>
    <a href="__BASE__docs/status.html">Status</a>
    <div class="topnav-search"><input type="search" id="site-search" placeholder="Search · /" aria-label="Search the site"></div>
    <a href="https://github.com/ckluis/senkani" class="btn-nav">GitHub →</a>
  </div>
</nav>
'''

FOOT = '''<footer class="site-foot">
  <div class="foot-grid">
    <div>
      <div class="foot-wordmark">sen<span class="accent">kani</span></div>
      <p class="foot-tagline"><span lang="zh">閃蟹</span> — "fast claw." A native macOS binary written in Swift.</p>
    </div>
    <div class="foot-col"><h4>Product</h4><ul><li><a href="__BASE__docs/what-is-senkani.html">What is it?</a></li><li><a href="__BASE__docs/concepts/">Concepts</a></li><li><a href="__BASE__docs/reference/">Reference</a></li><li><a href="__BASE__docs/guides/">Guides</a></li><li><a href="__BASE__docs/status.html">Status</a></li></ul></div>
    <div class="foot-col"><h4>Reference</h4><ul><li><a href="__BASE__docs/reference/mcp/">MCP tools</a></li><li><a href="__BASE__docs/reference/cli/">CLI commands</a></li><li><a href="__BASE__docs/reference/options/">Options &amp; env</a></li><li><a href="__BASE__docs/reference/panes/">Panes</a></li><li><a href="__BASE__docs/changelog.html">Changelog</a></li></ul></div>
    <div class="foot-col"><h4>Project</h4><ul><li><a href="https://github.com/ckluis/senkani">GitHub repo</a></li><li><a href="__BASE__docs/guides/install.html">Install</a></li><li><a href="__BASE__docs/guides/troubleshooting.html">Troubleshooting</a></li><li><a href="__BASE__docs/about.html">About &amp; license</a></li></ul></div>
  </div>
  <div class="foot-meta">
    <span>© 2026 · MIT licensed core · Apple Silicon native · macOS 14+</span>
    <span><a href="__BASE__docs/changelog.html">v0.2.0 changelog</a></span>
  </div>
</footer>
<script src="__BASE__assets/app.js" defer></script>
</body>
</html>
'''

# ============================================================
# MCP TOOLS DATA
# ============================================================
MCP_TOOLS = [
    dict(
        slug="senkani_read", name="senkani_read", status="live",
        replaces="Read", savings="50–99%",
        overview="Compressed file reads with session caching, outline-by-default, and secret redaction. The single most-called tool in a typical session.",
        what="Returns an outline (symbols + line numbers) by default — ~99% smaller than the raw file. Pass `full: true` for the complete content. Every read passes through ANSI stripping, blank-line collapse, SecretDetector, and the ReadCache keyed on (path, mtime).",
        inputs=[
            ("path", "string", "—", "Absolute path to the file. Paths are validated against the workspace root."),
            ("full", "boolean", "false", "If true, return the full file content. If false, return outline only (symbols + line numbers)."),
            ("offset", "integer", "0", "Line offset to start reading from. Ignored when full is false."),
            ("limit", "integer", "2000", "Max lines to return. Ignored when full is false."),
        ],
        output="Outline mode: list of `{{name, kind, line_start, line_end, container}}` entries. Full mode: the file content with secrets redacted and ANSI stripped.",
        example='''<span class="c">// outline mode (default)</span>
{<span class="k">"tool"</span>: <span class="v">"senkani_read"</span>, <span class="k">"args"</span>: {<span class="k">"path"</span>: <span class="v">"/repo/src/OrderRepo.ts"</span>}}
<span class="c">// returns ~50 tokens:</span>
[
  {<span class="k">"name"</span>: <span class="v">"OrderRepository"</span>, <span class="k">"kind"</span>: <span class="v">"class"</span>, <span class="k">"line_start"</span>: <span class="e">12</span>, <span class="k">"line_end"</span>: <span class="e">94</span>},
  {<span class="k">"name"</span>: <span class="v">"findByUser"</span>,      <span class="k">"kind"</span>: <span class="v">"method"</span>, <span class="k">"line_start"</span>: <span class="e">18</span>, <span class="k">"line_end"</span>: <span class="e">31</span>}
]''',
        behavior="Cache key is `(path, mtime)` — unchanged files return instantly from memory. The SecretDetector short-circuits on no-match inputs (1 MB benign file: ~25 ms). When the outline is empty (file not in index), falls back to reading full content up to `limit`.",
        security="All text-returning tools pass through SecretDetector. 13 secret families + entropy-based fallback.",
        related=[("senkani_fetch", "__BASE__docs/reference/mcp/senkani_fetch.html", "Read a single symbol's lines instead of the whole file."),
                 ("senkani_outline", "__BASE__docs/reference/mcp/senkani_outline.html", "Just the outline, no content toggle."),
                 ("senkani_search", "__BASE__docs/reference/mcp/senkani_search.html", "Find where a symbol is defined before reading."),
                 ("cache (C toggle)", "__BASE__docs/reference/options/cache.html", "Disable the read cache per-pane.")],
        source="Sources/MCPServer/Tools/ReadTool.swift"
    ),
    dict(
        slug="senkani_exec", name="senkani_exec", status="live",
        replaces="Bash", savings="60–90%",
        overview="Shell execution with 24+ command-specific filter rules applied to output. Mutating commands pass through unchanged; read commands (git status, npm install, make, curl) get heavily compressed.",
        what="FilterEngine matches `(command, subcommand)` pairs to rule chains. Read-only commands route through the filter; mutating commands (`git commit`, `rm`, `docker run`, `terraform apply`, ...) bypass it so the tool never hides a destructive effect. Adaptive truncation for long outputs; background mode for long builds via `background: true`.",
        inputs=[
            ("cmd", "string", "—", "The shell command to run. Single string, parsed by the shell."),
            ("background", "boolean", "false", "If true, returns a job handle. Poll with `action:\"poll\"`; kill with `action:\"kill\"`."),
            ("cwd", "string", "workspace root", "Working directory; must be within the workspace."),
            ("timeout", "integer", "120", "Seconds before forced kill (foreground only)."),
        ],
        output="stdout + stderr (filtered) + exit code + a `compressed_from` byte count so the agent sees the ratio. Background mode returns a `job_id` and the starting tail.",
        example='''<span class="c">// filtered npm install</span>
{<span class="k">"tool"</span>: <span class="v">"senkani_exec"</span>, <span class="k">"args"</span>: {<span class="k">"cmd"</span>: <span class="v">"npm install"</span>}}
<span class="c">// raw output: 428 lines · returned: 2 lines</span>
<span class="ok">added 312 packages in 4.8s (0 vulnerabilities)</span>
<span class="c">// savings: 99.5%</span>''',
        behavior="Rule set covers git (status/diff/log/clone/pull), npm/yarn/pnpm install, pip, make, cargo, swift build, curl, ssh, docker pull, terraform plan, and ~14 more. Each rule is tested under `Tests/FilterTests/`. Rules are a pure function of `(cmd, stdout, stderr)` — no side effects.",
        security="Commands and their output pass through SecretDetector before the agent sees them. The `event_counters` row `command_redactions` increments on each redaction (visible via `senkani stats --security`).",
        related=[("Filter toggle (F)", "__BASE__docs/reference/options/filter.html", "Disable the filter pipeline per-pane."),
                 ("senkani exec CLI", "__BASE__docs/reference/cli/senkani-exec.html", "Same filter, scriptable from the shell."),
                 ("Compound learning", "__BASE__docs/concepts/compound-learning.html", "New filter rules learned from your own sessions.")],
        source="Sources/MCPServer/Tools/ExecTool.swift + Sources/Filter/FilterEngine.swift"
    ),
    dict(
        slug="senkani_search", name="senkani_search", status="live",
        replaces="Grep",
        savings="99%",
        overview="Symbol lookup from the local tree-sitter index, BM25-ranked and FTS5-backed. Returns `file:line`, kind, container — ~50 tokens vs ~5,000 for grepping.",
        what="In-memory `IndexEntry` array backed by FTS5 + optional RRF fusion with MiniLM file embeddings. Substring match on symbol names; `--kind`/`--file`/`--container` filters narrow results. The hook intercepts plain-identifier Grep calls and routes them here automatically.",
        inputs=[
            ("query", "string", "—", "Symbol name or prefix. Supports substring match; not a full regex."),
            ("kind", "string", "any", "Filter: `class`, `function`, `method`, `struct`, `enum`, `type`, `constant`, `variable`."),
            ("file", "string", "any", "Restrict results to files matching this glob."),
            ("container", "string", "any", "Restrict to symbols inside this container (e.g., class name)."),
            ("limit", "integer", "20", "Max results."),
        ],
        output="List of `{{name, kind, file, line, end_line, container, score}}`. Sorted by BM25+RRF score.",
        example='''{<span class="k">"tool"</span>: <span class="v">"senkani_search"</span>, <span class="k">"args"</span>: {<span class="k">"query"</span>: <span class="v">"OrderRepository"</span>}}
<span class="c">// returns ~50 tokens:</span>
[{<span class="k">"name"</span>:<span class="v">"OrderRepository"</span>,<span class="k">"file"</span>:<span class="v">"src/orders/repo.ts"</span>,<span class="k">"line"</span>:<span class="e">12</span>,<span class="k">"kind"</span>:<span class="v">"class"</span>}]''',
        behavior="FTS5 operator syntax is stripped from the query before execution (prevents FTS injection). The index rebuilds incrementally via FSEvents; cold search < 5 ms, cached < 1 ms. 25 tree-sitter grammars supply the symbol extraction.",
        security="Search queries never reach the model — only sanitized outputs do.",
        related=[("senkani_fetch", "__BASE__docs/reference/mcp/senkani_fetch.html", "Read a symbol's source after finding it."),
                 ("senkani_outline", "__BASE__docs/reference/mcp/senkani_outline.html", "All symbols in a file, no query."),
                 ("Indexer toggle (I)", "__BASE__docs/reference/options/indexer.html", "Disable the indexer per-pane."),
                 ("Symbol indexer concept", "__BASE__docs/concepts/mcp-intelligence.html", "How the index is built.")],
        source="Sources/MCPServer/Tools/SearchTool.swift + Sources/Indexer/"
    ),
    dict(
        slug="senkani_fetch", name="senkani_fetch", status="live",
        replaces="Read", savings="50–99%",
        overview="Read only a symbol's exact source lines, not the entire file. Token cost is proportional to the symbol, not to the file.",
        what="Uses `startLine`/`endLine` from the IndexEntry to slice the symbol's lines from the ReadCache (warm) or disk (cold). Ideal after a `senkani_search` that located a function you want to read.",
        inputs=[
            ("symbol", "string", "—", "Exact symbol name. Use `senkani_search` first if unsure."),
            ("file", "string", "—", "File the symbol lives in. Disambiguates if the symbol name is not unique."),
            ("container", "string", "any", "Container (e.g., class name) for further disambiguation."),
        ],
        output="The symbol's source lines as a string, plus `{{line_start, line_end, file}}` metadata.",
        example='''{<span class="k">"tool"</span>:<span class="v">"senkani_fetch"</span>,<span class="k">"args"</span>:{<span class="k">"symbol"</span>:<span class="v">"OrderRepository"</span>,<span class="k">"file"</span>:<span class="v">"src/orders/repo.ts"</span>}}
<span class="c">// returns only lines 12–94, not the full file</span>''',
        behavior="SecretDetector + ANSI strip applied to the slice. If the symbol resolves to multiple candidates, returns the highest-scoring match and a note about alternatives.",
        security="Path validated against workspace root. SecretDetector scans output.",
        related=[("senkani_search", "__BASE__docs/reference/mcp/senkani_search.html", "Find the symbol first."),
                 ("senkani_read", "__BASE__docs/reference/mcp/senkani_read.html", "Full file read when you need more than one symbol."),
                 ("senkani_outline", "__BASE__docs/reference/mcp/senkani_outline.html", "See all symbols in a file.")],
        source="Sources/MCPServer/Tools/FetchTool.swift"
    ),
    dict(
        slug="senkani_explore", name="senkani_explore", status="live",
        replaces="Read ×N", savings="90%+",
        overview="Navigate a codebase via the bidirectional import/dependency graph. Returns a subgraph from a starting file — not a file list.",
        what="`DependencyExtractor` builds edges during indexing. Given an entry point, returns a bounded subgraph (both imports-of and imported-by) up to a depth limit. Ideal for first-contact exploration without reading every file.",
        inputs=[
            ("entry", "string", "—", "File path or symbol to start from."),
            ("depth", "integer", "2", "Hops in each direction (imports + imported-by)."),
            ("limit", "integer", "30", "Max nodes in the returned subgraph."),
        ],
        output="Nodes (file paths) + edges (source, target, kind). ~500 tokens for a typical entry point.",
        example='''{<span class="k">"tool"</span>:<span class="v">"senkani_explore"</span>,<span class="k">"args"</span>:{<span class="k">"entry"</span>:<span class="v">"src/server.ts"</span>,<span class="k">"depth"</span>:<span class="e">2</span>}}''',
        behavior="Graph is built from tree-sitter AST at index time; 15+ languages supply import parsers. Incremental updates via FSEvents.",
        related=[("senkani_deps", "__BASE__docs/reference/mcp/senkani_deps.html", "Direct edge queries instead of a subgraph."),
                 ("senkani_search", "__BASE__docs/reference/mcp/senkani_search.html", "Find a starting symbol first.")],
        source="Sources/Indexer/DependencyExtractor.swift"
    ),
    dict(
        slug="senkani_deps", name="senkani_deps", status="live",
        replaces="Read ×N",
        overview="Query the bidirectional dependency graph: what imports X, what does X import.",
        what="Direct lookup in the edge set built by `DependencyExtractor`. No traversal — returns the immediate neighbors. For multi-hop exploration, use `senkani_explore`.",
        inputs=[
            ("file", "string", "—", "File to query."),
            ("direction", "string", "both", "One of `imports`, `imported_by`, or `both`."),
        ],
        output="List of file paths with import-kind annotation.",
        example='''{<span class="k">"tool"</span>:<span class="v">"senkani_deps"</span>,<span class="k">"args"</span>:{<span class="k">"file"</span>:<span class="v">"src/auth.ts"</span>,<span class="k">"direction"</span>:<span class="v">"imported_by"</span>}}''',
        behavior="Edge kinds: `static-import`, `dynamic-import`, `re-export`, `require`. Swift imports include the module name.",
        related=[("senkani_explore", "__BASE__docs/reference/mcp/senkani_explore.html", "Multi-hop subgraph instead of direct neighbors."),
                 ("senkani_outline", "__BASE__docs/reference/mcp/senkani_outline.html", "What's inside a file, not who uses it.")],
        source="Sources/Indexer/DependencyExtractor.swift"
    ),
    dict(
        slug="senkani_outline", name="senkani_outline", status="live",
        replaces="Read",
        overview="File-level structure: all top-level functions, classes, types. Names + line numbers only.",
        what="Queries `IndexEntry` for entries matching the file path. Returns names + line numbers with no bodies. ~10× smaller than reading the file.",
        inputs=[
            ("file", "string", "—", "Absolute path."),
            ("kinds", "array", "all", "Filter kinds: `class`, `function`, `method`, etc."),
        ],
        output="Array of `{{name, kind, line_start, line_end, container}}`.",
        example='''{<span class="k">"tool"</span>:<span class="v">"senkani_outline"</span>,<span class="k">"args"</span>:{<span class="k">"file"</span>:<span class="v">"src/repo.ts"</span>}}''',
        behavior="Orders results by `line_start`. Container hierarchy preserved for nested classes/modules.",
        related=[("senkani_read", "__BASE__docs/reference/mcp/senkani_read.html", "Same outline in `full: false` mode + content toggle."),
                 ("senkani_fetch", "__BASE__docs/reference/mcp/senkani_fetch.html", "Read a specific symbol's source.")],
        source="Sources/MCPServer/Tools/OutlineTool.swift"
    ),
    dict(
        slug="senkani_validate", name="senkani_validate", status="live",
        replaces="Bash build", savings="100%",
        overview="Local syntax validation across 25 languages. Catch typos without running a build.",
        what="Passes source to the tree-sitter parser for the detected language; parse errors → structured error list. Success → zero API calls consumed. `full: true` returns complete error details; default returns summary.",
        inputs=[
            ("file", "string", "—", "File to validate. Language auto-detected from extension."),
            ("full", "boolean", "false", "Return complete error detail instead of summary."),
            ("lang", "string", "auto", "Override language detection."),
        ],
        output="Pass or a list of `{{line, column, kind, message}}` errors.",
        example='''{<span class="k">"tool"</span>:<span class="v">"senkani_validate"</span>,<span class="k">"args"</span>:{<span class="k">"file"</span>:<span class="v">"src/api.ts"</span>}}
<span class="ok">// ok — 0 errors</span>''',
        behavior="Validation is pure parse — not type-check. Doesn't catch type errors, semantic bugs, or lint issues. Fast (~50 ms for a 2k-line file).",
        related=[("senkani_parse", "__BASE__docs/reference/mcp/senkani_parse.html", "Full AST dump for deeper analysis."),
                 ("senkani validate CLI", "__BASE__docs/reference/cli/senkani-validate.html", "Scriptable from the shell.")],
        source="Sources/MCPServer/Tools/ValidateTool.swift + Sources/Indexer/TreeSitterBackends/"
    ),
    dict(
        slug="senkani_parse", name="senkani_parse", status="live",
        overview="Return the tree-sitter AST for a file or snippet as structured JSON.",
        what="Runs the appropriate tree-sitter parser and returns the node tree. Useful for agent tasks that need to reason about code structure explicitly (rather than by regex or text match).",
        inputs=[
            ("file", "string", "—", "File to parse. Alternatively pass `source` + `lang`."),
            ("source", "string", "—", "Source text if not reading from file."),
            ("lang", "string", "auto", "Language name; required if using `source`."),
            ("max_depth", "integer", "∞", "Limit AST depth."),
        ],
        output="JSON: `{{type, range, children[]}}` recursively.",
        example='''{<span class="k">"tool"</span>:<span class="v">"senkani_parse"</span>,<span class="k">"args"</span>:{<span class="k">"file"</span>:<span class="v">"src/api.ts"</span>,<span class="k">"max_depth"</span>:<span class="e">3</span>}}''',
        behavior="Output can be large; use `max_depth` aggressively. For symbol-level needs prefer `senkani_outline` or `senkani_fetch`.",
        related=[("senkani_validate", "__BASE__docs/reference/mcp/senkani_validate.html", "Same parser, but returns pass/errors only."),
                 ("senkani_outline", "__BASE__docs/reference/mcp/senkani_outline.html", "Pre-extracted symbol list.")],
        source="Sources/MCPServer/Tools/ParseTool.swift"
    ),
    dict(
        slug="senkani_embed", name="senkani_embed", status="live",
        replaces="API call", savings="$0/call",
        overview="Text embeddings on Apple Silicon via MLX. MiniLM-L6-v2 → 384-dim Float32. Zero API cost.",
        what="Runs on the Neural Engine through MLX. Sub-200 ms per call on M-series. Shared `MLXInferenceLock` FIFO-serializes every MLX call and drops loaded model containers on macOS memory-pressure warnings.",
        inputs=[
            ("texts", "array<string>", "—", "Batch of strings to embed."),
            ("normalize", "boolean", "true", "L2-normalize the output vectors."),
        ],
        output="Array of 384-dim Float32 vectors, one per input.",
        example='''{<span class="k">"tool"</span>:<span class="v">"senkani_embed"</span>,<span class="k">"args"</span>:{<span class="k">"texts"</span>:[<span class="v">"orders"</span>,<span class="v">"payments"</span>]}}''',
        behavior="First call loads the model (~80 MB) into unified memory; subsequent calls reuse it. Idle models drop on memory pressure.",
        security="Fully offline once the model is downloaded. No outbound traffic.",
        related=[("senkani_vision", "__BASE__docs/reference/mcp/senkani_vision.html", "Local vision inference via Gemma."),
                 ("Model Manager pane", "__BASE__docs/reference/panes/model-manager.html", "Download and inspect local models.")],
        source="Sources/MCPServer/Tools/EmbedTool.swift + Sources/MLX/"
    ),
    dict(
        slug="senkani_vision", name="senkani_vision", status="live",
        replaces="API call", savings="$0/call",
        overview="Vision model on Apple Silicon via MLX (Gemma). OCR, UI analysis, screenshot reading. Zero API cost.",
        what="Input: image path or base64 PNG. Output: text or structured JSON. Sub-500 ms on M-series. Fully offline after model download. Same `MLXInferenceLock` + memory-pressure semantics as `senkani_embed`.",
        inputs=[
            ("image", "string", "—", "File path OR `data:image/png;base64,...` URI."),
            ("prompt", "string", "\"Describe the image.\"", "Vision prompt."),
            ("format", "string", "text", "`text` or `json`."),
        ],
        output="Text or a JSON object matching your prompt's schema.",
        example='''{<span class="k">"tool"</span>:<span class="v">"senkani_vision"</span>,<span class="k">"args"</span>:{<span class="k">"image"</span>:<span class="v">"/tmp/screenshot.png"</span>,<span class="k">"prompt"</span>:<span class="v">"Extract UI text."</span>}}''',
        behavior="Gemma model loads on first call; idle drops on memory pressure.",
        related=[("senkani_embed", "__BASE__docs/reference/mcp/senkani_embed.html", "Local text embeddings."),
                 ("Model Manager pane", "__BASE__docs/reference/panes/model-manager.html", "Manage local models.")],
        source="Sources/MCPServer/Tools/VisionTool.swift"
    ),
    dict(
        slug="senkani_watch", name="senkani_watch", status="live",
        overview="Query recently-changed files via an FSEvents ring buffer, filtered by cursor + glob.",
        what="500-entry ring buffer on `MCPSession`. Query by timestamp cursor + glob pattern; returns changed file paths since last check. Zero polling cost — the buffer fills from FSEvents in the background.",
        inputs=[
            ("since", "string", "\"session_start\"", "Cursor — ISO timestamp or `session_start`."),
            ("glob", "string", "\"**/*\"", "Filter by path."),
            ("limit", "integer", "100", "Max entries."),
        ],
        output="List of `{{path, kind, timestamp}}`. Advances cursor in the response so the next call picks up exactly where this left off.",
        example='''{<span class="k">"tool"</span>:<span class="v">"senkani_watch"</span>,<span class="k">"args"</span>:{<span class="k">"glob"</span>:<span class="v">"src/**/*.ts"</span>}}''',
        behavior="Ring buffer drops oldest on overflow — for long sessions, poll more often or widen the limit.",
        related=[("senkani_session", "__BASE__docs/reference/mcp/senkani_session.html", "Other per-session state.")],
        source="Sources/MCPServer/Tools/WatchTool.swift"
    ),
    dict(
        slug="senkani_web", name="senkani_web", status="live", savings="~99% vs raw HTML",
        overview="Render http:// / https:// pages with full JavaScript and return an AXTree-style Markdown extraction.",
        what="Uses WKWebView + semantic DOM walk. Returns headings, links, buttons, form fields — not the raw HTML. SSRF guard: DNS-resolves the host via `getaddrinfo` before fetch and blocks any address in private/link-local/CGNAT/multicast ranges (including IPv4-mapped IPv6 and octal/hex IPv4). `decidePolicyFor` re-validates every redirect. A `WKContentRuleList` blocks subresource requests (`<img>`, `<script>`, `<xhr>`) to the same private ranges — a hostile page embedding `<img src=\"http://169.254.169.254/...\">` cannot reach cloud metadata through WebKit's auto-rendering. `file://` scheme is NOT accepted — use `senkani_read` for local files.",
        inputs=[
            ("url", "string", "—", "Absolute http:// or https:// URL. file:// rejected."),
            ("wait_ms", "integer", "2000", "Ms to wait after load for JS to settle."),
            ("viewport", "object", "{{\"w\":1280,\"h\":800}}", "Render viewport."),
        ],
        output="Markdown-formatted AXTree: headings, text blocks, links, interactive controls.",
        example='''{<span class="k">"tool"</span>:<span class="v">"senkani_web"</span>,<span class="k">"args"</span>:{<span class="k">"url"</span>:<span class="v">"https://docs.example.com"</span>}}''',
        security="SSRF guard applies to the main nav AND every subresource. Override for internal doc servers: `SENKANI_WEB_ALLOW_PRIVATE=on`. Bypassing this is on the operator.",
        related=[("senkani_read", "__BASE__docs/reference/mcp/senkani_read.html", "For local files; file:// not accepted here."),
                 ("senkani_repo", "__BASE__docs/reference/mcp/senkani_repo.html", "Structured GitHub repo access (allowlisted)."),
                 ("Security env vars", "__BASE__docs/reference/options/security.html", "All SENKANI_WEB_* overrides.")],
        source="Sources/MCPServer/Tools/WebTool.swift"
    ),
    dict(
        slug="senkani_pane", name="senkani_pane", status="live",
        overview="Control the workspace panes from a tool call — open, close, focus, resize.",
        what="Sends IPC messages to the SwiftUI app via a local Unix-domain socket (`~/.senkani/sockets/pane.sock`). Pane mutations execute on the app's main thread.",
        inputs=[
            ("action", "string", "—", "`open`, `close`, `focus`, `resize`, `list`."),
            ("pane_type", "string", "—", "For `open`: Terminal, Analytics, Browser, etc."),
            ("pane_id", "string", "—", "For `close` / `focus` / `resize`."),
        ],
        output="Updated pane state. `list` returns the full pane tree for the current workspace.",
        example='''{<span class="k">"tool"</span>:<span class="v">"senkani_pane"</span>,<span class="k">"args"</span>:{<span class="k">"action"</span>:<span class="v">"open"</span>,<span class="k">"pane_type"</span>:<span class="v">"Analytics"</span>}}''',
        behavior="Requires the app to be running. If the socket is absent or the app is not a managed target, returns an error.",
        security="Socket auth via `SENKANI_SOCKET_AUTH=on` requires a handshake frame matching `~/.senkani/.token` (mode 0600, rotated on start).",
        related=[("Pane reference", "__BASE__docs/reference/panes/", "What pane types exist."),
                 ("Socket auth option", "__BASE__docs/reference/options/security.html", "Enable the handshake.")],
        source="Sources/MCPServer/Tools/PaneTool.swift + SenkaniApp/IPC/"
    ),
    dict(
        slug="senkani_session", name="senkani_session", status="live",
        overview="Query session metrics, toggle features, and manage session state from within a tool call.",
        what="Actions: `stats`, `toggle`, `pane-list`, `clear-cache`, `pin`, `unpin`, `pins`. Writes to `SessionDatabase` and live MCP session state.",
        inputs=[
            ("action", "string", "—", "One of stats, toggle, pane-list, clear-cache, pin, unpin, pins."),
            ("feature", "string", "—", "For `toggle`: `filter`, `cache`, `secrets`, `indexer`, `terse`."),
            ("symbol", "string", "—", "For `pin`/`unpin`."),
        ],
        output="Depends on action. `stats` returns lifetime + session metrics; `pins` returns the pinned symbol list.",
        example='''{<span class="k">"tool"</span>:<span class="v">"senkani_session"</span>,<span class="k">"args"</span>:{<span class="k">"action"</span>:<span class="v">"stats"</span>}}''',
        behavior="Toggle changes persist to `~/.senkani/panes/{{paneId}}.env` and take effect immediately — no restart.",
        related=[("FCSIT toggles", "__BASE__docs/reference/options/fcsit.html", "Same controls, UI surface."),
                 ("senkani stats CLI", "__BASE__docs/reference/cli/senkani-stats.html", "CLI version for scripting.")],
        source="Sources/MCPServer/Tools/SessionTool.swift"
    ),
    dict(
        slug="senkani_knowledge", name="senkani_knowledge", status="live",
        overview="Query and update the project knowledge graph — entities, links, decisions, FTS5 search.",
        what="Seven actions: `upsert_entity`, `get_entity`, `list_entities`, `upsert_link`, `search_knowledge` (FTS5), `list_decisions`, `graph`. The knowledge base is stored at `.senkani/knowledge/*.md` with a rebuilt SQLite index.",
        inputs=[
            ("action", "string", "—", "One of the seven actions."),
            ("full", "boolean", "false", "Return complete entity detail instead of summary."),
            ("query", "string", "—", "For `search_knowledge`."),
        ],
        output="Entity or link records; search returns BM25-ranked hits.",
        example='''{<span class="k">"tool"</span>:<span class="v">"senkani_knowledge"</span>,<span class="k">"args"</span>:{<span class="k">"action"</span>:<span class="v">"search_knowledge"</span>,<span class="k">"query"</span>:<span class="v">"auth middleware"</span>}}''',
        behavior="SQLite index is rebuilt if corrupt (`KBLayer1Coordinator`). Markdown at `.senkani/knowledge/` is the source of truth — hand-edits are safe.",
        related=[("Knowledge base concept", "__BASE__docs/concepts/knowledge-base.html", "How it's built + maintained."),
                 ("senkani kb CLI", "__BASE__docs/reference/cli/senkani-kb.html", "CLI version."),
                 ("Compound learning", "__BASE__docs/concepts/compound-learning.html", "KB ↔ learning bridge.")],
        source="Sources/MCPServer/Tools/KnowledgeTool.swift + Sources/KB/"
    ),
    dict(
        slug="senkani_version", name="senkani_version", status="live",
        overview="Version negotiation: server_version, tool_schemas_version, schema_db_version, and the list of exposed tools.",
        what="Clients cache tool schemas keyed on `tool_schemas_version`. That number increments on any breaking change to a tool's input schema or output contract. `schema_db_version` surfaces `PRAGMA user_version` on the session DB for migration diagnostics.",
        inputs=[],
        output="`{{server_version, tool_schemas_version, schema_db_version, tools: [...]}}`. Includes every tool's name, input schema hash, and status.",
        example='''{<span class="k">"tool"</span>:<span class="v">"senkani_version"</span>}''',
        behavior="Always safe to call; zero side effects. Good canary during upgrades.",
        related=[("senkani doctor", "__BASE__docs/reference/cli/senkani-doctor.html", "Diagnose + repair registration and version mismatches.")],
        source="Sources/MCPServer/Tools/VersionTool.swift"
    ),
    dict(
        slug="senkani_bundle", name="senkani_bundle", status="live", savings="repo-level",
        overview="Budget-bounded repo snapshot — symbol outlines + dep graph + KB entities + README in a canonical, truncation-robust order. Local or remote.",
        what="`BundleComposer` composes outputs within a fixed token budget. Sections order is canonical so partial truncation still produces a parseable brief. Local mode snapshots the current workspace; remote mode (`remote: \"owner/name\"`) uses `senkani_repo` to snapshot any public GitHub repo. Two output formats: `format: \"markdown\"` (default) or `format: \"json\"` (stable-schema `BundleDocument`).",
        inputs=[
            ("budget_tokens", "integer", "8000", "Max tokens in the output bundle."),
            ("remote", "string", "—", "`owner/name` for a public GitHub repo. Omit for local mode."),
            ("format", "string", "markdown", "`markdown` or `json`."),
            ("include", "array", "all", "Subset of `[outlines, deps, kb, readme]`."),
        ],
        output="Markdown document or a `BundleDocument` JSON.",
        example='''{<span class="k">"tool"</span>:<span class="v">"senkani_bundle"</span>,<span class="k">"args"</span>:{<span class="k">"budget_tokens"</span>:<span class="e">6000</span>}}''',
        security="Host allowlist (api.github.com, raw.githubusercontent.com) + SecretDetector on every scanned file.",
        related=[("senkani_repo", "__BASE__docs/reference/mcp/senkani_repo.html", "Remote bundle's underlying GitHub access."),
                 ("Knowledge base concept", "__BASE__docs/concepts/knowledge-base.html", "What KB entities end up in the bundle.")],
        source="Sources/Bundle/BundleComposer.swift"
    ),
    dict(
        slug="senkani_repo", name="senkani_repo", status="live", savings="query-level",
        overview="Query any public GitHub repo without cloning. Actions: tree, file, readme, search.",
        what="Host-allowlisted to api.github.com + raw.githubusercontent.com. Anonymous by default (60 req/h); `GITHUB_TOKEN` env raises the limit. All responses pass through SecretDetector. TTL + LRU cache.",
        inputs=[
            ("action", "string", "—", "`tree`, `file`, `readme`, `search`."),
            ("repo", "string", "—", "`owner/name`."),
            ("path", "string", "—", "For `file`."),
            ("ref", "string", "HEAD", "Branch, tag, or commit SHA."),
        ],
        output="Depends on action. `tree` → file list; `file` → contents; `readme` → rendered readme; `search` → BM25-ranked hits.",
        example='''{<span class="k">"tool"</span>:<span class="v">"senkani_repo"</span>,<span class="k">"args"</span>:{<span class="k">"action"</span>:<span class="v">"tree"</span>,<span class="k">"repo"</span>:<span class="v">"ckluis/senkani"</span>}}''',
        security="Never follows redirects outside the allowlist. Every fetched file is SecretDetector-scanned before being returned.",
        related=[("senkani_bundle", "__BASE__docs/reference/mcp/senkani_bundle.html", "Budget-bounded remote snapshot."),
                 ("senkani_web", "__BASE__docs/reference/mcp/senkani_web.html", "General web fetch (different guard).")],
        source="Sources/MCPServer/Tools/RepoTool.swift"
    ),
]

# ============================================================
# CLI COMMANDS DATA
# ============================================================
CLI_COMMANDS = [
    dict(slug="senkani-exec", name="senkani exec", syntax="senkani exec -- <cmd>",
         summary="Run a command with the filter pipeline applied to output. Mutating commands pass through unchanged.",
         detail="The CLI counterpart to `senkani_exec`. Same FilterEngine, same 24+ rules, same SecretDetector. Use in scripts and CI where you want the compression without running an agent.",
         example='''$ senkani exec -- git status
On branch main · working tree clean''',
         flags=[("-- <cmd>", "Required. Everything after `--` is the command."),
                ("--no-filter", "Bypass the filter (sanity check).")],
         related=[("senkani_exec tool", "__BASE__docs/reference/mcp/senkani_exec.html"),
                  ("Filter toggle (F)", "__BASE__docs/reference/options/filter.html")],
         source="Sources/CLI/ExecCommand.swift"),
    dict(slug="senkani-search", name="senkani search", syntax="senkani search <symbol>",
         summary="Symbol lookup from the tree-sitter index.",
         detail="Same index as `senkani_search`. Output is human-readable by default; `--json` for scripting.",
         example='''$ senkani search OrderRepository
src/orders/repo.ts:12  class OrderRepository''',
         flags=[("--kind <k>", "Filter by kind: class, function, method, etc."),
                ("--file <glob>", "Restrict to matching paths."),
                ("--container <c>", "Restrict to symbols inside a container."),
                ("--limit N", "Max results. Default 20.")],
         related=[("senkani_search tool", "__BASE__docs/reference/mcp/senkani_search.html")],
         source="Sources/CLI/SearchCommand.swift"),
    dict(slug="senkani-fetch", name="senkani fetch", syntax="senkani fetch <symbol>",
         summary="Read a symbol's source lines by name.",
         detail="Outputs just the symbol body. Pair with `senkani search` to discover the exact name.",
         example="$ senkani fetch OrderRepository",
         flags=[("--file <path>", "Disambiguate when the symbol is not unique."),
                ("--container <c>", "Restrict by enclosing type.")],
         related=[("senkani_fetch tool", "__BASE__docs/reference/mcp/senkani_fetch.html")],
         source="Sources/CLI/FetchCommand.swift"),
    dict(slug="senkani-explore", name="senkani explore", syntax="senkani explore [--root path]",
         summary="Navigate the codebase via the import graph from an entry point.",
         detail="Returns a bounded subgraph (imports + imported-by) up to a depth. Default entry point is auto-detected from `Package.swift` / `package.json` / `Cargo.toml`.",
         example="$ senkani explore --root src/server.ts --depth 2",
         flags=[("--root <path>", "Entry point file."),
                ("--depth N", "Hops in each direction."),
                ("--limit N", "Max nodes.")],
         related=[("senkani_explore tool", "__BASE__docs/reference/mcp/senkani_explore.html")],
         source="Sources/CLI/ExploreCommand.swift"),
    dict(slug="senkani-index", name="senkani index", syntax="senkani index [--root path]",
         summary="Build or update the symbol index manually.",
         detail="Normally runs incrementally via FSEvents. This command forces a full rebuild — useful after switching branches or if the index gets out of sync.",
         example="$ senkani index --root .",
         flags=[("--root <path>", "Root to index."),
                ("--force", "Full rebuild even if FSEvents cursor is current.")],
         related=[("Indexer toggle (I)", "__BASE__docs/reference/options/indexer.html")],
         source="Sources/CLI/IndexCommand.swift"),
    dict(slug="senkani-validate", name="senkani validate", syntax="senkani validate <file>",
         summary="Local syntax validation across 25 languages. Zero API calls.",
         detail="Fast parse via tree-sitter. Exit code 0 on pass, nonzero on errors.",
         example="$ senkani validate src/api.ts",
         flags=[("--lang <name>", "Override language detection."),
                ("--full", "Return complete error detail.")],
         related=[("senkani_validate tool", "__BASE__docs/reference/mcp/senkani_validate.html")],
         source="Sources/CLI/ValidateCommand.swift"),
    dict(slug="senkani-stats", name="senkani stats", syntax="senkani stats [--search term]",
         summary="Lifetime metrics from the session database. FTS5 search over tool output history.",
         detail="Default view shows lifetime tokens saved, cost saved, compliance rate, top filter rules by hit. `--search` hits the FTS5-indexed `commands.output_preview`. `--security` surfaces event counters.",
         example='''$ senkani stats
lifetime: 2.3M tokens saved · $14.20 · 94% compliance''',
         flags=[("--search <term>", "FTS5 search over command output history."),
                ("--security", "Show security event counters."),
                ("--verbose", "Per-project rows."),
                ("--json", "JSON output.")],
         related=[("senkani_session tool", "__BASE__docs/reference/mcp/senkani_session.html"),
                  ("Session database concept", "__BASE__docs/concepts/three-layer-stack.html")],
         source="Sources/CLI/StatsCommand.swift"),
    dict(slug="senkani-export", name="senkani export",
         syntax="senkani export --output <file> [--since DATE] [--redact]",
         summary="JSONL dump of sessions + commands + token_events. GDPR-adjacent data portability.",
         detail="Uses a read-only SQLite connection so it doesn't block the live MCP server. `--redact` collapses user paths. `--output -` streams to stdout for piping.",
         example="$ senkani export --output ~/senkani-export.jsonl --redact",
         flags=[("--output <file>", "Destination file or `-` for stdout."),
                ("--since <date>", "ISO date filter."),
                ("--redact", "Redact absolute paths.")],
         related=[("Privacy concept", "__BASE__docs/concepts/security-posture.html")],
         source="Sources/CLI/ExportCommand.swift"),
    dict(slug="senkani-wipe", name="senkani wipe",
         syntax="senkani wipe [--yes] [--include-config]",
         summary="Destructive: delete session DB + socket-auth token.",
         detail="Dry-run prints the deletion list without acting. `--yes` is required to delete. `--include-config` also removes `~/.senkani/config.json`.",
         example="$ senkani wipe     # dry-run\n$ senkani wipe --yes",
         flags=[("--yes", "Required to actually delete."),
                ("--include-config", "Also delete ~/.senkani/config.json.")],
         related=[("senkani uninstall", "__BASE__docs/reference/cli/senkani-uninstall.html"),
                  ("Uninstall guide", "__BASE__docs/guides/uninstall.html")],
         source="Sources/CLI/WipeCommand.swift"),
    dict(slug="senkani-bench", name="senkani bench",
         syntax="senkani bench [--iterations N]",
         summary="Run the benchmark suite: 10 tasks × 7 configs.",
         detail="Reproduces the 80.37× fixture-suite figure on your hardware. Writes JSON results; prints a summary.",
         example="$ senkani bench --iterations 256",
         flags=[("--iterations N", "Default 256."),
                ("--json", "Emit full results."),
                ("--scenario <name>", "Run one scenario only.")],
         related=[("Savings Test pane", "__BASE__docs/reference/panes/savings-test.html")],
         source="Sources/Bench/"),
    dict(slug="senkani-init", name="senkani init",
         syntax="senkani init [--hooks-only]",
         summary="Register MCP server + hooks with Claude Code. Idempotent.",
         detail="Writes the hook binary to `~/.senkani/bin/senkani-hook`, appends an MCP server entry to `~/.claude/settings.json`, and registers PreToolUse + PostToolUse hooks with matcher `Read|Bash|Grep|Write|Edit`. `--hooks-only` skips the MCP entry for Cursor / Copilot users.",
         example="$ senkani init            # Claude Code\n$ senkani init --hooks-only   # Cursor / Copilot",
         flags=[("--hooks-only", "Skip MCP server registration."),
                ("--dry-run", "Print intended changes without writing.")],
         related=[("Install guide", "__BASE__docs/guides/install.html"),
                  ("Claude Code guide", "__BASE__docs/guides/claude-code.html"),
                  ("Cursor / Copilot guide", "__BASE__docs/guides/cursor-copilot.html")],
         source="Sources/CLI/InitCommand.swift"),
    dict(slug="senkani-doctor", name="senkani doctor",
         syntax="senkani doctor [--fix]",
         summary="Diagnose and optionally repair hook registration, binary paths, grammar versions, config.",
         detail="Checks: MCP server entry, hook registration, binary path resolution, grammar staleness (non-blocking advisory — PASS for recent, SKIP for stale >30 d, never FAIL).",
         example="$ senkani doctor --fix",
         flags=[("--fix", "Attempt repair for each failing check.")],
         related=[("senkani init", "__BASE__docs/reference/cli/senkani-init.html"),
                  ("Troubleshooting guide", "__BASE__docs/guides/troubleshooting.html")],
         source="Sources/CLI/DoctorCommand.swift"),
    dict(slug="senkani-compare", name="senkani compare",
         syntax="senkani compare <a> <b>",
         summary="Diff two files or git revisions through the filter pipeline.",
         detail="Useful for comparing agent-produced diffs to raw diffs.",
         example="$ senkani compare HEAD~1 HEAD",
         flags=[("--no-filter", "Disable filter for the comparison.")],
         related=[("senkani_exec tool", "__BASE__docs/reference/mcp/senkani_exec.html"),
                  ("Diff Viewer pane", "__BASE__docs/reference/panes/diff-viewer.html")],
         source="Sources/CLI/CompareCommand.swift"),
    dict(slug="senkani-grammars", name="senkani grammars",
         syntax="senkani grammars",
         summary="Show installed tree-sitter grammar versions.",
         detail="Also: `senkani grammars check` compares vendored versions against upstream tags (cached 24 h).",
         example="$ senkani grammars check",
         flags=[("check", "Subcommand: compare vendored vs upstream.")],
         related=[("Tree-sitter concept", "__BASE__docs/concepts/mcp-intelligence.html")],
         source="Sources/CLI/GrammarsCommand.swift"),
    dict(slug="senkani-schedule", name="senkani schedule",
         syntax="senkani schedule <cron>",
         summary="Schedule recurring commands via launchd.",
         detail="Generates a launchd plist per schedule. Each fire gets its own worktree + pane pair. Budget cap per run.",
         example="$ senkani schedule \"0 9 * * *\" -- senkani kb get audit",
         flags=[("list", "Show active schedules."),
                ("remove <id>", "Delete a schedule.")],
         related=[("Schedules pane", "__BASE__docs/reference/panes/schedules.html")],
         source="Sources/CLI/ScheduleCommand.swift"),
    dict(slug="senkani-uninstall", name="senkani uninstall",
         syntax="senkani uninstall [--yes] [--keep-data]",
         summary="Clean removal of all senkani config, hooks, and MCP entries.",
         detail="Removes: MCP server entry, PreToolUse/PostToolUse hook entries, `~/.senkani/`, app-support DB (unless `--keep-data`), launchd plists, per-project `.senkani/` dirs. Idempotent.",
         example="$ senkani uninstall --yes --keep-data",
         flags=[("--yes", "Required to actually uninstall."),
                ("--keep-data", "Preserve the session database.")],
         related=[("Uninstall guide", "__BASE__docs/guides/uninstall.html"),
                  ("senkani wipe", "__BASE__docs/reference/cli/senkani-wipe.html")],
         source="Sources/CLI/UninstallCommand.swift + UninstallArtifactScanner.swift"),
    dict(slug="senkani-kb", name="senkani kb",
         syntax="senkani kb [list|get|search|rollback|history|timeline]",
         summary="Query and manage the project knowledge base.",
         detail="Subcommands mirror `senkani_knowledge` + rollback/history/timeline from the enrichment layer. Flags: `--sort`, `--type`, `--limit`, `--root`.",
         example="$ senkani kb search \"auth middleware\"",
         flags=[("list", "List entities."),
                ("get <id>", "Full entity detail."),
                ("search <q>", "FTS5 search."),
                ("rollback <id>", "Revert the last enrichment."),
                ("history <id>", "Show enrichment history."),
                ("timeline", "Chronological timeline of KB changes.")],
         related=[("senkani_knowledge tool", "__BASE__docs/reference/mcp/senkani_knowledge.html"),
                  ("Knowledge base concept", "__BASE__docs/concepts/knowledge-base.html")],
         source="Sources/CLI/KBCommand.swift"),
    dict(slug="senkani-eval", name="senkani eval",
         syntax="senkani eval [--update-baseline]",
         summary="Quality gates: bench savings + KB health + regression detection.",
         detail="`--strict` for CI (nonzero exit on regression). `--json` for scripting.",
         example="$ senkani eval --strict",
         flags=[("--update-baseline", "Lock in current numbers as the new baseline."),
                ("--strict", "Nonzero exit on regression."),
                ("--json", "JSON output.")],
         related=[("senkani bench", "__BASE__docs/reference/cli/senkani-bench.html")],
         source="Sources/CLI/EvalCommand.swift"),
    dict(slug="senkani-learn", name="senkani learn",
         syntax="senkani learn [status|apply|reject|sweep|enrich|config|review|audit]",
         summary="Compound learning CLI — review staged proposals, accept/reject, audit.",
         detail="Subcommands match the four artifact types (filter rules, context docs, instruction patches, workflow playbooks) and cadence cycles (sprint review, quarterly audit). See `/concepts/compound-learning/`.",
         example="$ senkani learn status --type filter\n$ senkani learn apply <id>\n$ senkani learn review --days 7",
         flags=[("status --type <t>", "filter | context | instruction | workflow."),
                ("apply <id>", "Promote staged → applied."),
                ("reject <id>", "Discard proposal."),
                ("sweep", "Run the daily recurrence sweep."),
                ("enrich", "Run Gemma rationale enrichment."),
                ("config {show,set}", "Tune thresholds."),
                ("review [--days N]", "Sprint cadence."),
                ("audit [--idle D]", "Quarterly currency review.")],
         related=[("Compound learning concept", "__BASE__docs/concepts/compound-learning.html"),
                  ("Sprint Review pane", "__BASE__docs/reference/panes/sprint-review.html")],
         source="Sources/CLI/LearnCommand.swift"),
]

# ============================================================
# PANES DATA
# ============================================================
PANES = [
    ("terminal", "Terminal", "green",
     "SwiftTerm-backed terminal with Senkani's FCSIT controls. Configurable font size. Kill/restart buttons. Broadcast mode for running the same command across selected panes.",
     ["F=on (filter)", "C=on (cache)", "S=on (secrets)", "I=on (indexer)", "T=off (terse)"]),
    ("dashboard", "Dashboard", "blue",
     "Multi-project portfolio: total savings across every workspace, project-level table, per-feature charts, and insights (top filter rule by hit, freshest KB entity, etc.).", []),
    ("code-editor", "Code Editor", "amber",
     "NSTextView with tree-sitter syntax highlighting across 25 languages. Cmd+click for symbol navigation. Token-intelligence overlays show live compression counts per file.", []),
    ("browser", "Browser", "cyan",
     "Embedded WKWebView. Localhost or any URL. Optional click-to-capture Design Mode (env-gate `SENKANI_BROWSER_DESIGN=on`, ⌥⇧D toggles) — click an element, get a fixed-schema Markdown block on the clipboard.", []),
    ("markdown-preview", "Markdown Preview", "blue",
     "Live render from a file, updating on save. Supports GFM tables, fenced code, and `<img>` with sanitization.", []),
    ("analytics", "Analytics", "blue",
     "Token + cost savings with charts, persistent across restarts. Compression breakdown by source (filter / indexer / intercept). Compliance rate meter.", []),
    ("model-manager", "Model Manager", "purple",
     "Download, verify, and delete local LLMs (Gemma, MiniLM). Shows disk usage + last-used time. Triggers background memory-pressure-aware loading.", []),
    ("savings-test", "Savings Test", "green",
     "Fixture benchmark + live session replay + scenario simulator. Shows the fixture ceiling and the live multiplier side by side — the live number is the honest one.", []),
    ("agent-timeline", "Agent Timeline", "purple",
     "Timeline of optimization events, interactive tool calls, and scheduled-task runs. Start/end/blocked states. Scrubbable.", []),
    ("knowledge-base", "Knowledge Base", "amber",
     "Project knowledge entities with freshness indicators. Click to open the markdown file. Quick-search via `senkani_knowledge`.", []),
    ("diff-viewer", "Diff Viewer", "blue",
     "Side-by-side LCS diff — correct insertions, deletions, replacements. Works with file pairs or git revisions.", []),
    ("log-viewer", "Log Viewer", "yellow",
     "Searchable log output. Tail mode, regex filter, persistent search history.", []),
    ("scratchpad", "Scratchpad", "purple",
     "Auto-saving markdown notepad. One per project. Search across all scratchpads via ⌘K.", []),
    ("schedules", "Schedules", "green",
     "Manage recurring tasks via launchd. View fire history, next-run times, worktree artifacts, budget ledger.", []),
    ("skill-library", "Skill Library", "cyan",
     "Browse, install, and manage AI agent skills discovered in the project or shipped globally. Zero-install enable/disable.", []),
    ("sprint-review", "Sprint Review", "amber",
     "GUI counterpart to `senkani learn review`. Accept/reject staged compound-learning proposals (filter rules, context docs, instruction patches, workflow playbooks) plus a stale-applied section mirroring the quarterly audit.", []),
    ("settings", "Settings", "blue",
     "Global app preferences: theme, font size, default FCSIT, key bindings, telemetry (off by default).", []),
]

# ============================================================
# RENDERERS
# ============================================================

def wiki_nav_mcp(active_slug: str) -> str:
    def line(t):
        cls = ' class="active"' if t["slug"] == active_slug else ''
        return f'        <li><a href="__BASE__docs/reference/mcp/{t["slug"]}.html"{cls}><code>{t["slug"]}</code></a></li>'
    items = "\n".join(line(t) for t in MCP_TOOLS)
    return f'''  <aside class="wiki-nav" aria-label="MCP tools navigation">
    <div class="wiki-nav-group">
      <h4>Reference</h4>
      <ul>
        <li><a href="__BASE__docs/reference/">All reference</a></li>
        <li><a href="__BASE__docs/reference/mcp/">MCP tools index</a></li>
        <li><a href="__BASE__docs/reference/cli/">CLI commands</a></li>
        <li><a href="__BASE__docs/reference/options/">Options &amp; env</a></li>
        <li><a href="__BASE__docs/reference/panes/">Panes</a></li>
      </ul>
    </div>
    <div class="wiki-nav-group">
      <h4>MCP tools ({len(MCP_TOOLS)})</h4>
      <ul>
{items}
      </ul>
    </div>
  </aside>'''


def wiki_nav_cli(active_slug: str) -> str:
    def line(c):
        cls = ' class="active"' if c["slug"] == active_slug else ''
        return f'        <li><a href="__BASE__docs/reference/cli/{c["slug"]}.html"{cls}><code>{c["name"]}</code></a></li>'
    items = "\n".join(line(c) for c in CLI_COMMANDS)
    return f'''  <aside class="wiki-nav" aria-label="CLI commands navigation">
    <div class="wiki-nav-group">
      <h4>Reference</h4>
      <ul>
        <li><a href="__BASE__docs/reference/">All reference</a></li>
        <li><a href="__BASE__docs/reference/mcp/">MCP tools</a></li>
        <li><a href="__BASE__docs/reference/cli/">CLI commands index</a></li>
        <li><a href="__BASE__docs/reference/options/">Options &amp; env</a></li>
        <li><a href="__BASE__docs/reference/panes/">Panes</a></li>
      </ul>
    </div>
    <div class="wiki-nav-group">
      <h4>CLI commands ({len(CLI_COMMANDS)})</h4>
      <ul>
{items}
      </ul>
    </div>
  </aside>'''


def wiki_nav_panes(active_slug: str) -> str:
    def line(p):
        cls = ' class="active"' if p[0] == active_slug else ''
        return f'        <li><a href="__BASE__docs/reference/panes/{p[0]}.html"{cls}>{p[1]}</a></li>'
    items = "\n".join(line(p) for p in PANES)
    return f'''  <aside class="wiki-nav" aria-label="Pane navigation">
    <div class="wiki-nav-group">
      <h4>Reference</h4>
      <ul>
        <li><a href="__BASE__docs/reference/">All reference</a></li>
        <li><a href="__BASE__docs/reference/mcp/">MCP tools</a></li>
        <li><a href="__BASE__docs/reference/cli/">CLI commands</a></li>
        <li><a href="__BASE__docs/reference/options/">Options &amp; env</a></li>
        <li><a href="__BASE__docs/reference/panes/">Panes index</a></li>
      </ul>
    </div>
    <div class="wiki-nav-group">
      <h4>Pane types ({len(PANES)})</h4>
      <ul>
{items}
      </ul>
    </div>
  </aside>'''


def render_mcp_tool(t: dict) -> str:
    title = f'{t["name"]} — MCP tool reference'
    desc = html.escape(t["overview"])[:160]
    io_rows = ''.join(
        f'<div class="k">{html.escape(i[0])}</div><div class="t">{html.escape(i[1])}</div><div class="default">{html.escape(i[2])}</div><div class="desc">{i[3]}</div>'
        for i in t["inputs"]
    ) if t["inputs"] else ''
    inputs_block = f'''
    <h2>Inputs</h2>
    <div class="ref-io-table">
      <div class="head">Name</div><div class="head">Type</div><div class="head">Default</div><div class="head">Description</div>
      {io_rows}
    </div>
''' if t["inputs"] else '    <h2>Inputs</h2>\n    <p>No inputs.</p>\n'
    related_items = "\n".join(
        f'        <li><a href="{r[1]}"><code>{r[0]}</code></a> — {r[2] if len(r) > 2 else ""}</li>' if len(r) == 3
        else f'        <li><a href="{r[1]}"><code>{r[0]}</code></a></li>'
        for r in t["related"]
    )
    security_block = f'    <div class="callout callout-security"><span class="callout-icon">⚔</span><div>{t["security"]}</div></div>\n' if t.get("security") else ""
    details_block = f'<h2>Details</h2>\n    <p>{t["behavior"]}</p>\n' if t.get("behavior") else ""
    savings = f'<span class="tag tag-green">Savings {t["savings"]}</span>' if t.get("savings") else ''
    replaces = f'<span class="tag">Replaces <code>{t["replaces"]}</code></span>' if t.get("replaces") else ''

    body = f'''<main id="main" class="wiki-layout">
{wiki_nav_mcp(t["slug"])}
  <article class="wiki-main">
    <nav class="crumb" aria-label="Breadcrumb">
      <a href="__BASE__">Home</a> <span class="sep">›</span>
      <a href="__BASE__docs/reference/">Reference</a> <span class="sep">›</span>
      <a href="__BASE__docs/reference/mcp/">MCP tools</a> <span class="sep">›</span>
      <span class="here"><code>{t["slug"]}</code></span>
    </nav>
    <span class="quadrant reference">Reference · Information</span>
    <h1 class="page-title"><code style="background:none;padding:0;color:var(--accent-lo);font-size:0.82em;">{t["slug"]}</code></h1>
    <div class="tag-row" style="margin-bottom:18px;">
      <span class="badge badge-live">Live</span>
      {replaces}
      {savings}
    </div>

    <p class="lede">{t["overview"]}</p>

    <h2>Signature</h2>
    <div class="ref-signature">senkani_mcp.call(tool="{t["slug"]}", args={{...}})</div>

    <h2>Behavior</h2>
    <p>{t["what"]}</p>

{inputs_block}
    <h2>Output</h2>
    <p>{t["output"]}</p>

    <h2>Example</h2>
    <pre class="code">{t["example"]}</pre>

    {details_block}
{security_block}
    <div class="seealso">
      <h3>See also</h3>
      <ul>
{related_items}
      </ul>
    </div>

    <div class="source-pointer">
      <strong>Source:</strong> <code>{t["source"]}</code>
    </div>
  </article>
</main>
'''
    return (HEAD.format(title=title, desc=desc) + body + FOOT).replace("\\", "\\")


def render_cli(c: dict) -> str:
    title = f'{c["name"]} — CLI reference'
    desc = html.escape(c["summary"])[:160]
    flags_rows = ''.join(
        f'<div class="k">{html.escape(f[0])}</div><div class="t"></div><div class="default"></div><div class="desc">{f[1]}</div>'
        for f in c["flags"]
    )
    flags_block = f'''
    <h2>Flags</h2>
    <div class="ref-io-table">
      <div class="head">Flag</div><div class="head"></div><div class="head"></div><div class="head">Description</div>
      {flags_rows}
    </div>
''' if c["flags"] else ''
    related_items = "\n".join(f'        <li><a href="{r[1]}"><code>{r[0]}</code></a></li>' for r in c["related"])
    body = f'''<main id="main" class="wiki-layout">
{wiki_nav_cli(c["slug"])}
  <article class="wiki-main">
    <nav class="crumb" aria-label="Breadcrumb">
      <a href="__BASE__">Home</a> <span class="sep">›</span>
      <a href="__BASE__docs/reference/">Reference</a> <span class="sep">›</span>
      <a href="__BASE__docs/reference/cli/">CLI commands</a> <span class="sep">›</span>
      <span class="here"><code>{c["name"]}</code></span>
    </nav>
    <span class="quadrant reference">Reference · Information</span>
    <h1 class="page-title"><code style="background:none;padding:0;color:var(--accent-lo);font-size:0.82em;">{c["name"]}</code></h1>
    <div class="tag-row" style="margin-bottom:18px;"><span class="badge badge-live">Live</span></div>

    <p class="lede">{c["summary"]}</p>

    <h2>Syntax</h2>
    <div class="ref-signature">{c["syntax"]}</div>

    <h2>Behavior</h2>
    <p>{c["detail"]}</p>

    <h2>Example</h2>
    <pre class="code">{c["example"]}</pre>
{flags_block}
    <div class="seealso">
      <h3>See also</h3>
      <ul>
{related_items}
      </ul>
    </div>

    <div class="source-pointer">
      <strong>Source:</strong> <code>{c["source"]}</code>
    </div>
  </article>
</main>
'''
    return HEAD.format(title=title, desc=desc) + body + FOOT


def render_pane(p: tuple) -> str:
    slug, name, color, desc, defaults = p
    title = f"{name} pane — reference"
    meta_desc = html.escape(desc)[:160]
    defaults_block = (
        f'    <h2>Defaults</h2><p>{" · ".join(defaults)}</p>\n' if defaults else ""
    )
    body = f'''<main id="main" class="wiki-layout">
{wiki_nav_panes(slug)}
  <article class="wiki-main">
    <nav class="crumb" aria-label="Breadcrumb">
      <a href="__BASE__">Home</a> <span class="sep">›</span>
      <a href="__BASE__docs/reference/">Reference</a> <span class="sep">›</span>
      <a href="__BASE__docs/reference/panes/">Panes</a> <span class="sep">›</span>
      <span class="here">{name}</span>
    </nav>
    <span class="quadrant reference">Reference · Information</span>
    <h1 class="page-title">{name}</h1>
    <div class="tag-row" style="margin-bottom:18px;">
      <span class="badge badge-live">Live</span>
      <span class="tag tag-orange">Pane type</span>
    </div>

    <p class="lede">{desc}</p>

{defaults_block}
    <h2>Keyboard</h2>
    <p>Open via ⌘K → type the pane name. Close with ⌘W. Focus with ⌘+digit (the pane's position on the canvas).</p>

    <h2>Related</h2>
    <ul>
      <li><a href="__BASE__docs/reference/panes/">All pane types</a></li>
      <li><a href="__BASE__docs/reference/options/fcsit.html">FCSIT per-pane toggles</a></li>
      <li><a href="__BASE__docs/reference/mcp/senkani_pane.html"><code>senkani_pane</code> — programmatic control</a></li>
    </ul>
  </article>
</main>
'''
    return HEAD.format(title=title, desc=meta_desc) + body + FOOT


# ============================================================
# WRITE
# ============================================================
def write(path: Path, content: str):
    """Write content to path, substituting __BASE__ with the correct
    relative prefix so every link resolves for both file:// and
    subpath deploys like ckluis.github.io/senkani/."""
    path.parent.mkdir(parents=True, exist_ok=True)
    # depth = number of directory levels from ROOT. /index.html = 0,
    # /what-is-senkani/index.html = 1, /reference/mcp/senkani_read/index.html = 3.
    rel = path.relative_to(ROOT)
    depth = len(rel.parts) - 1  # minus 1 for the filename itself
    base = "../" * depth
    content = content.replace("__BASE__", base)
    path.write_text(content)
    print(f"  wrote {rel} (depth={depth})")


# ============================================================
# HUB PAGES
# ============================================================
def wiki_nav_reference(active: str) -> str:
    def cls(n): return ' class="active"' if n == active else ''
    return f'''  <aside class="wiki-nav" aria-label="Reference navigation">
    <div class="wiki-nav-group">
      <h4>Reference</h4>
      <ul>
        <li><a href="__BASE__docs/reference/"{cls("index")}>All reference</a></li>
        <li><a href="__BASE__docs/reference/mcp/"{cls("mcp")}>MCP tools ({len(MCP_TOOLS)})</a></li>
        <li><a href="__BASE__docs/reference/cli/"{cls("cli")}>CLI commands ({len(CLI_COMMANDS)})</a></li>
        <li><a href="__BASE__docs/reference/options/"{cls("options")}>Options &amp; env</a></li>
        <li><a href="__BASE__docs/reference/panes/"{cls("panes")}>Panes ({len(PANES)})</a></li>
      </ul>
    </div>
    <div class="wiki-nav-group">
      <h4>Start</h4>
      <ul>
        <li><a href="__BASE__docs/what-is-senkani.html">What is it?</a></li>
        <li><a href="__BASE__docs/concepts/">Concepts</a></li>
        <li><a href="__BASE__docs/guides/install.html">Install</a></li>
      </ul>
    </div>
  </aside>'''


def wiki_nav_concepts(active: str) -> str:
    concepts = [
        ("compression-layer", "Compression layer"),
        ("hook-relay", "Hook relay"),
        ("mcp-intelligence", "MCP intelligence"),
        ("three-layer-stack", "Three-layer stack"),
        ("compound-learning", "Compound learning"),
        ("knowledge-base", "Knowledge base"),
        ("security-posture", "Security posture"),
    ]
    def cls(s): return ' class="active"' if s == active else ''
    items = "\n".join(f'        <li><a href="__BASE__docs/concepts/{s}.html"{cls(s)}>{n}</a></li>' for s, n in concepts)
    return f'''  <aside class="wiki-nav" aria-label="Concepts navigation">
    <div class="wiki-nav-group">
      <h4>Overview</h4>
      <ul>
        <li><a href="__BASE__docs/what-is-senkani.html">What is senkani?</a></li>
        <li><a href="__BASE__docs/concepts/"{cls("index")}>All concepts</a></li>
      </ul>
    </div>
    <div class="wiki-nav-group">
      <h4>Concepts</h4>
      <ul>
{items}
      </ul>
    </div>
    <div class="wiki-nav-group">
      <h4>Next</h4>
      <ul>
        <li><a href="__BASE__docs/reference/">Reference index</a></li>
        <li><a href="__BASE__docs/guides/install.html">Install</a></li>
      </ul>
    </div>
  </aside>'''


def wiki_nav_guides(active: str) -> str:
    guides = [
        ("install", "Install"),
        ("claude-code", "Claude Code"),
        ("cursor-copilot", "Cursor / Copilot"),
        ("first-session", "First session"),
        ("budget-setup", "Budget setup"),
        ("compound-learning", "Reviewing proposals"),
        ("kb-workflow", "Knowledge-base workflow"),
        ("uninstall", "Uninstall"),
        ("troubleshooting", "Troubleshooting"),
    ]
    def cls(s): return ' class="active"' if s == active else ''
    items = "\n".join(f'        <li><a href="__BASE__docs/guides/{s}.html"{cls(s)}>{n}</a></li>' for s, n in guides)
    return f'''  <aside class="wiki-nav" aria-label="Guides navigation">
    <div class="wiki-nav-group">
      <h4>Guides</h4>
      <ul>
        <li><a href="__BASE__docs/guides/"{cls("index")}>All guides</a></li>
{items}
      </ul>
    </div>
    <div class="wiki-nav-group">
      <h4>Next</h4>
      <ul>
        <li><a href="__BASE__docs/reference/">Reference</a></li>
        <li><a href="__BASE__docs/concepts/">Concepts</a></li>
      </ul>
    </div>
  </aside>'''


def wiki_nav_options(active: str) -> str:
    opts = [
        ("fcsit", "FCSIT overview"),
        ("filter", "F — Filter"),
        ("cache", "C — Cache"),
        ("secrets", "S — Secrets"),
        ("indexer", "I — Indexer"),
        ("terse", "T — Terse"),
        ("budget", "Budget caps"),
        ("security", "Security env vars"),
        ("web", "Web env vars"),
        ("compound-learning", "Compound-learning env"),
    ]
    def cls(s): return ' class="active"' if s == active else ''
    items = "\n".join(f'        <li><a href="__BASE__docs/reference/options/{s}.html"{cls(s)}>{n}</a></li>' for s, n in opts)
    return f'''  <aside class="wiki-nav" aria-label="Options navigation">
    <div class="wiki-nav-group">
      <h4>Reference</h4>
      <ul>
        <li><a href="__BASE__docs/reference/">All reference</a></li>
        <li><a href="__BASE__docs/reference/options/"{cls("index")}>Options index</a></li>
      </ul>
    </div>
    <div class="wiki-nav-group">
      <h4>Options &amp; env</h4>
      <ul>
{items}
      </ul>
    </div>
  </aside>'''


def render_hub_reference():
    title = "Reference — senkani"
    desc = "Reference for every MCP tool, CLI command, option, pane type."
    mcp_rows = "\n".join(
        f'      <a class="listing-row" href="__BASE__docs/reference/mcp/{t["slug"]}.html"><div class="listing-name">{t["slug"]}</div>'
        f'<div class="listing-desc">{html.escape(t["overview"])}</div>'
        f'<div class="listing-savings{" na" if not t.get("savings") else ""}">{t.get("savings", "—")}</div>'
        f'<div class="listing-status"><span class="badge badge-live">Live</span></div></a>'
        for t in MCP_TOOLS
    )
    body = f'''<main id="main" class="wiki-layout">
{wiki_nav_reference("index")}
  <article class="wiki-main">
    <nav class="crumb" aria-label="Breadcrumb">
      <a href="__BASE__">Home</a> <span class="sep">›</span> <span class="here">Reference</span>
    </nav>
    <span class="quadrant reference">Reference · Information</span>
    <h1 class="page-title">Reference</h1>
    <p class="lede">Every MCP tool, CLI command, option, and pane type has its own page. This index links to every reference section. Bookmark any URL.</p>

    <div class="card-grid">
      <a class="card" href="__BASE__docs/reference/mcp/">
        <h3>MCP tools <span class="tag tag-orange" style="margin-left:8px;">{len(MCP_TOOLS)}</span></h3>
        <p>Every <code>senkani_*</code> tool your agent can call — read, exec, search, fetch, explore, web, knowledge, bundle, repo, and more.</p>
      </a>
      <a class="card" href="__BASE__docs/reference/cli/">
        <h3>CLI commands <span class="tag tag-orange" style="margin-left:8px;">{len(CLI_COMMANDS)}</span></h3>
        <p>The same filter and index, scriptable from the shell: <code>senkani exec</code>, <code>senkani search</code>, <code>senkani bench</code>, <code>senkani learn</code>, <code>senkani kb</code>, and more.</p>
      </a>
      <a class="card" href="__BASE__docs/reference/options/">
        <h3>Options &amp; env</h3>
        <p>FCSIT per-pane toggles, budget caps, security env vars, web SSRF overrides, compound-learning thresholds. Every <code>SENKANI_*</code> variable documented.</p>
      </a>
      <a class="card" href="__BASE__docs/reference/panes/">
        <h3>Panes <span class="tag tag-orange" style="margin-left:8px;">{len(PANES)}</span></h3>
        <p>17 workspace pane types: Terminal, Code Editor, Browser, Analytics, Agent Timeline, Sprint Review, Knowledge Base, and more.</p>
      </a>
    </div>

    <h2 style="margin-top:32px;">All MCP tools</h2>
    <div class="listing">
      <div class="listing-row head">
        <div>Tool</div><div>What it does</div><div>Savings</div><div>Status</div>
      </div>
{mcp_rows}
    </div>

    <h2 style="margin-top:32px;">Next</h2>
    <ul>
      <li><a href="__BASE__docs/reference/cli/">Browse CLI commands →</a></li>
      <li><a href="__BASE__docs/reference/options/fcsit.html">Start with FCSIT toggles</a> (the five per-pane feature switches).</li>
      <li><a href="__BASE__docs/concepts/three-layer-stack.html">Understand the three-layer stack</a>.</li>
    </ul>
  </article>
</main>
'''
    return HEAD.format(title=title, desc=desc) + body + FOOT


def render_hub_mcp():
    title = "MCP tools — reference"
    desc = f"Reference for all {len(MCP_TOOLS)} senkani MCP tools."
    rows = "\n".join(
        f'      <a class="listing-row" href="__BASE__docs/reference/mcp/{t["slug"]}.html"><div class="listing-name">{t["slug"]}</div>'
        f'<div class="listing-desc">{html.escape(t["overview"])}</div>'
        f'<div class="listing-savings{" na" if not t.get("savings") else ""}">{t.get("savings", "—")}</div>'
        f'<div class="listing-status"><span class="badge badge-live">Live</span></div></a>'
        for t in MCP_TOOLS
    )
    body = f'''<main id="main" class="wiki-layout">
{wiki_nav_mcp("")}
  <article class="wiki-main">
    <nav class="crumb" aria-label="Breadcrumb">
      <a href="__BASE__">Home</a> <span class="sep">›</span>
      <a href="__BASE__docs/reference/">Reference</a> <span class="sep">›</span>
      <span class="here">MCP tools</span>
    </nav>
    <span class="quadrant reference">Reference · Information</span>
    <h1 class="page-title">MCP tools</h1>
    <p class="lede">{len(MCP_TOOLS)} tools that sit between your agent and your filesystem. Each tool has its own page with inputs, outputs, examples, security notes, and source pointers. Pick any.</p>

    <div class="listing">
      <div class="listing-row head">
        <div>Tool</div><div>What it does</div><div>Savings</div><div>Status</div>
      </div>
{rows}
    </div>

    <div class="callout callout-info">
      <span class="callout-icon">⚐</span>
      <div>All tools auto-register via <a href="__BASE__docs/reference/cli/senkani-init.html"><code>senkani init</code></a>. Non-Senkani terminals never see the tools — activation is gated on <code>SENKANI_PANE_ID</code>, which the app injects only into managed panes.</div>
    </div>
  </article>
</main>
'''
    return HEAD.format(title=title, desc=desc) + body + FOOT


def render_hub_cli():
    title = "CLI commands — reference"
    desc = f"Reference for all {len(CLI_COMMANDS)} senkani CLI commands."
    rows = "\n".join(
        f'      <a class="listing-row" href="__BASE__docs/reference/cli/{c["slug"]}.html"><div class="listing-name">{c["name"]}</div>'
        f'<div class="listing-desc">{html.escape(c["summary"])}</div>'
        f'<div class="listing-savings na">—</div>'
        f'<div class="listing-status"><span class="badge badge-live">Live</span></div></a>'
        for c in CLI_COMMANDS
    )
    body = f'''<main id="main" class="wiki-layout">
{wiki_nav_cli("")}
  <article class="wiki-main">
    <nav class="crumb" aria-label="Breadcrumb">
      <a href="__BASE__">Home</a> <span class="sep">›</span>
      <a href="__BASE__docs/reference/">Reference</a> <span class="sep">›</span>
      <span class="here">CLI commands</span>
    </nav>
    <span class="quadrant reference">Reference · Information</span>
    <h1 class="page-title">CLI commands</h1>
    <p class="lede">Every MCP tool has a CLI equivalent for shell use: <code>senkani exec</code>, <code>senkani search</code>, <code>senkani fetch</code>, <code>senkani bench</code>, <code>senkani kb</code>, <code>senkani learn</code>. Scriptable, pipeable, CI-friendly.</p>

    <div class="listing">
      <div class="listing-row head">
        <div>Command</div><div>What it does</div><div></div><div>Status</div>
      </div>
{rows}
    </div>
  </article>
</main>
'''
    return HEAD.format(title=title, desc=desc) + body + FOOT


def render_hub_panes():
    title = "Panes — reference"
    desc = f"All {len(PANES)} senkani workspace pane types."
    rows = "\n".join(
        f'      <a class="card" href="__BASE__docs/reference/panes/{p[0]}.html"><h4>{p[1]}</h4><p>{p[3]}</p></a>'
        for p in PANES
    )
    body = f'''<main id="main" class="wiki-layout">
{wiki_nav_panes("")}
  <article class="wiki-main">
    <nav class="crumb" aria-label="Breadcrumb">
      <a href="__BASE__">Home</a> <span class="sep">›</span>
      <a href="__BASE__docs/reference/">Reference</a> <span class="sep">›</span>
      <span class="here">Panes</span>
    </nav>
    <span class="quadrant reference">Reference · Information</span>
    <h1 class="page-title">Panes</h1>
    <p class="lede">A horizontal canvas of typed panes. Each pane type is a primitive; arrange any combination for the project you're in. Senkani persists the layout per project.</p>

    <div class="card-grid">
{rows}
    </div>

    <h2 style="margin-top:32px;">Keyboard</h2>
    <ul>
      <li><strong>⌘K</strong> — command palette. Type a pane name to open.</li>
      <li><strong>⌘+digit</strong> — focus the Nth pane on the canvas.</li>
      <li><strong>⌘W</strong> — close focused pane.</li>
    </ul>

    <div class="seealso">
      <h3>See also</h3>
      <ul>
        <li><a href="__BASE__docs/reference/options/fcsit.html">FCSIT per-pane toggles</a></li>
        <li><a href="__BASE__docs/reference/mcp/senkani_pane.html"><code>senkani_pane</code> — programmatic pane control</a></li>
      </ul>
    </div>
  </article>
</main>
'''
    return HEAD.format(title=title, desc=desc) + body + FOOT


def render_hub_options():
    title = "Options & env vars — reference"
    desc = "FCSIT toggles, budget caps, security env vars, and compound-learning thresholds."
    body = f'''<main id="main" class="wiki-layout">
{wiki_nav_options("index")}
  <article class="wiki-main">
    <nav class="crumb" aria-label="Breadcrumb">
      <a href="__BASE__">Home</a> <span class="sep">›</span>
      <a href="__BASE__docs/reference/">Reference</a> <span class="sep">›</span>
      <span class="here">Options &amp; env</span>
    </nav>
    <span class="quadrant reference">Reference · Information</span>
    <h1 class="page-title">Options &amp; env vars</h1>
    <p class="lede">Resolution order: <strong>CLI flag &gt; env var &gt; <code>~/.senkani/config.json</code> &gt; default</strong>. Any toggle can be overridden at any level without touching other settings.</p>

    <h2>FCSIT — per-pane feature toggles</h2>
    <div class="fcsit-card">
      <a class="fcsit-letter f" href="__BASE__docs/reference/options/filter.html"><span class="ltr">F</span><span class="name">Filter</span><span class="default">default on</span></a>
      <a class="fcsit-letter c" href="__BASE__docs/reference/options/cache.html"><span class="ltr">C</span><span class="name">Cache</span><span class="default">default on</span></a>
      <a class="fcsit-letter s" href="__BASE__docs/reference/options/secrets.html"><span class="ltr">S</span><span class="name">Secrets</span><span class="default">default on</span></a>
      <a class="fcsit-letter i" href="__BASE__docs/reference/options/indexer.html"><span class="ltr">I</span><span class="name">Indexer</span><span class="default">default on</span></a>
      <a class="fcsit-letter t" href="__BASE__docs/reference/options/terse.html"><span class="ltr">T</span><span class="name">Terse</span><span class="default">default off</span></a>
    </div>
    <p><a href="__BASE__docs/reference/options/fcsit.html">Read the FCSIT overview →</a></p>

    <h2>Env-var families</h2>
    <div class="card-grid">
      <a class="card" href="__BASE__docs/reference/options/budget.html"><h4>Budget caps</h4><p>Daily + weekly spend ceilings enforced at the hook layer. <code>SENKANI_BUDGET_DAILY</code>, <code>SENKANI_BUDGET_WEEKLY</code>.</p></a>
      <a class="card" href="__BASE__docs/reference/options/security.html"><h4>Security env vars</h4><p>Prompt-injection guard, SSRF overrides, socket auth, structured JSON logs, retention tuning.</p></a>
      <a class="card" href="__BASE__docs/reference/options/web.html"><h4>Web env vars</h4><p>Overrides for the <code>senkani_web</code> SSRF guard, subresource blocklist, allowlisted hosts.</p></a>
      <a class="card" href="__BASE__docs/reference/options/compound-learning.html"><h4>Compound-learning env</h4><p>Confidence thresholds, recurrence gates, Gemma enrichment rate limits.</p></a>
    </div>

    <h2 style="margin-top:32px;">Config file</h2>
    <pre class="code"><span class="c">// ~/.senkani/config.json</span>
{{
  <span class="k">"retention"</span>: {{
    <span class="k">"token_events_days"</span>: <span class="e">90</span>,
    <span class="k">"sandboxed_results_hours"</span>: <span class="e">24</span>
  }},
  <span class="k">"budget"</span>: {{
    <span class="k">"daily_usd"</span>: <span class="e">5.00</span>,
    <span class="k">"weekly_usd"</span>: <span class="e">25.00</span>
  }}
}}</pre>
  </article>
</main>
'''
    return HEAD.format(title=title, desc=desc) + body + FOOT


def render_hub_concepts():
    title = "Concepts — understanding senkani"
    desc = "Explanation pages: why senkani compresses where it compresses, how the hook relay works, how compound learning mines your own sessions, and how the knowledge base stays coherent."
    body = f'''<main id="main" class="wiki-layout">
{wiki_nav_concepts("index")}
  <article class="wiki-main">
    <nav class="crumb" aria-label="Breadcrumb">
      <a href="__BASE__">Home</a> <span class="sep">›</span> <span class="here">Concepts</span>
    </nav>
    <span class="quadrant concept">Concept · Explanation</span>
    <h1 class="page-title">Concepts</h1>
    <p class="lede">Explanation pages — the <em>why</em> behind senkani. Reference tells you what each tool does; concepts tell you why the system works. Start with <a href="__BASE__docs/what-is-senkani.html">What is senkani?</a> if this is your first visit.</p>

    <div class="card-grid">
      <a class="card" href="__BASE__docs/concepts/compression-layer.html"><h4>Compression layer</h4><p>Three places Senkani compresses: input (before the LLM sees it), redundancy (before the tool runs), output (before responses grow). Why all three.</p></a>
      <a class="card" href="__BASE__docs/concepts/hook-relay.html"><h4>Hook relay</h4><p>How the <code>senkani-hook</code> binary intercepts your agent's Read/Bash/Grep, routes to senkani equivalents, and denies with cached results when appropriate.</p></a>
      <a class="card" href="__BASE__docs/concepts/mcp-intelligence.html"><h4>MCP intelligence</h4><p>What "MCP tool" means and why senkani has 19 of them. How tree-sitter + FTS5 + MiniLM compose into sub-5 ms symbol search.</p></a>
      <a class="card" href="__BASE__docs/concepts/three-layer-stack.html"><h4>Three-layer stack</h4><p>Layer 1 tools, Layer 2 hooks, Layer 3 smart denials. Why denial-with-cached-result is the biggest win on pathological sessions.</p></a>
      <a class="card" href="__BASE__docs/concepts/compound-learning.html"><h4>Compound learning</h4><p>Four artifact types — filter rules, context docs, instruction patches, workflow playbooks — mined from your own sessions. The <code>.recurring → .staged → .applied</code> flow.</p></a>
      <a class="card" href="__BASE__docs/concepts/knowledge-base.html"><h4>Knowledge base</h4><p>Project entities + decisions + links. Markdown as source-of-truth, SQLite as rebuilt index. How it stays coherent when you hand-edit.</p></a>
      <a class="card" href="__BASE__docs/concepts/security-posture.html"><h4>Security posture</h4><p>v0.2.0 defaults: prompt-injection guard on, SSRF hardening on, secret redaction on, socket auth opt-in. Why senkani is a trust boundary and what that means concretely.</p></a>
    </div>
  </article>
</main>
'''
    return HEAD.format(title=title, desc=desc) + body + FOOT


def render_hub_guides():
    title = "Guides — how to set up and run senkani"
    desc = "Numbered, paste-runnable guides: install, wire up Claude Code, wire up Cursor/Copilot, first session, budget setup, and more."
    body = f'''<main id="main" class="wiki-layout">
{wiki_nav_guides("index")}
  <article class="wiki-main">
    <nav class="crumb" aria-label="Breadcrumb">
      <a href="__BASE__">Home</a> <span class="sep">›</span> <span class="here">Guides</span>
    </nav>
    <span class="quadrant guide">Guide · How-to</span>
    <h1 class="page-title">Guides</h1>
    <p class="lede">Numbered, paste-runnable guides with expected-output blocks. Every shell command has been verified against a clean checkout.</p>

    <div class="card-grid">
      <a class="card" href="__BASE__docs/guides/install.html"><h4>Install</h4><p>Clone, build with Swift Package Manager, register hooks, launch the workspace. Three minutes end-to-end.</p></a>
      <a class="card" href="__BASE__docs/guides/claude-code.html"><h4>Wire up Claude Code</h4><p>How <code>senkani init</code> modifies <code>~/.claude/settings.json</code>; what the MCP entry looks like; how to verify the integration.</p></a>
      <a class="card" href="__BASE__docs/guides/cursor-copilot.html"><h4>Wire up Cursor / Copilot</h4><p><code>senkani init --hooks-only</code> for non-Claude agents. What changes, what doesn't.</p></a>
      <a class="card" href="__BASE__docs/guides/first-session.html"><h4>Your first session</h4><p>Open the workspace, kick off a coding agent, read the Analytics pane. What the numbers mean and how to read them.</p></a>
      <a class="card" href="__BASE__docs/guides/budget-setup.html"><h4>Budget setup</h4><p>Daily + weekly caps, dual-layer enforcement, and what happens when you hit them.</p></a>
      <a class="card" href="__BASE__docs/guides/compound-learning.html"><h4>Reviewing learned proposals</h4><p>How to use <code>senkani learn review</code> and the Sprint Review pane to accept/reject staged proposals.</p></a>
      <a class="card" href="__BASE__docs/guides/kb-workflow.html"><h4>Knowledge-base workflow</h4><p>Day-to-day with <code>senkani kb</code>: seeding entities, editing the source markdown, running the audit.</p></a>
      <a class="card" href="__BASE__docs/guides/uninstall.html"><h4>Clean uninstall</h4><p><code>senkani uninstall</code> + <code>senkani wipe</code>. What each removes and what to keep.</p></a>
      <a class="card" href="__BASE__docs/guides/troubleshooting.html"><h4>Troubleshooting</h4><p>Hook not registering, MCP not activating, grammar staleness, rebuild-index steps.</p></a>
    </div>
  </article>
</main>
'''
    return HEAD.format(title=title, desc=desc) + body + FOOT


def render_hub_status():
    title = "Status — what's built"
    desc = "Current release, test count, MCP tool + CLI command + pane counts, security posture, and roadmap."
    body = f'''<main id="main" class="wiki-layout">
{wiki_nav_reference("")}
  <article class="wiki-main">
    <nav class="crumb" aria-label="Breadcrumb">
      <a href="__BASE__">Home</a> <span class="sep">›</span> <span class="here">Status</span>
    </nav>
    <span class="quadrant reference">Reference · Information</span>
    <h1 class="page-title">Status</h1>
    <p class="lede">Current release: <strong>v0.2.0</strong>. <strong>1,510</strong> unit tests passing. All features below are live + tested + reproducible on your hardware.</p>

    <div class="card-grid">
      <div class="stat-card"><div class="num">v<em>0.2</em>.0</div><div class="label">Current release — <a href="__BASE__docs/changelog.html">changelog</a></div></div>
      <div class="stat-card"><div class="num"><em>1,510</em></div><div class="label">Passing tests</div></div>
      <div class="stat-card"><div class="num"><em>{len(MCP_TOOLS)}</em></div><div class="label">MCP tools — <a href="__BASE__docs/reference/mcp/">reference</a></div></div>
      <div class="stat-card"><div class="num"><em>{len(CLI_COMMANDS)}</em></div><div class="label">CLI commands — <a href="__BASE__docs/reference/cli/">reference</a></div></div>
      <div class="stat-card"><div class="num"><em>{len(PANES)}</em></div><div class="label">Pane types — <a href="__BASE__docs/reference/panes/">reference</a></div></div>
      <div class="stat-card"><div class="num"><em>25</em></div><div class="label">Tree-sitter languages indexed</div></div>
    </div>

    <h2 style="margin-top:40px;">Shipped this release (v0.2.0)</h2>
    <ul>
      <li><strong>Hook relay + filter pipeline</strong> — 24 command-specific rules; Layer 3 smart denials (re-read suppression, command replay, trivial routing, symbol upgrade, redundant validation); 80.37× fixture-suite reduction.</li>
      <li><strong>Symbol indexer</strong> — 25 tree-sitter grammars, FTS5 search, dependency graph, container hierarchy, incremental FSEvents updates; cold &lt; 5 ms / cached &lt; 1 ms.</li>
      <li><strong>Session DB + analytics</strong> — SQLite + FTS5; per-call token tracking; budget enforcement at hook layer; BM25+RRF search fusion; @-mention context pinning; session continuity; JSONL data export.</li>
      <li><strong>Local ML</strong> — MiniLM embeddings (384-dim) + Gemma vision via MLX on Neural Engine; fully offline after download; L0/L1/L2 tiered context pre-warming.</li>
      <li><strong>Compound learning</strong> — recurring→staged→applied with Laplace-smoothed confidence; four artifact types; Schneier gate on instruction-patch auto-apply.</li>
      <li><strong>Knowledge base</strong> — markdown source-of-truth + rebuilt SQLite index; enrichment validator, rollback, timeline; KB↔learning bridge.</li>
      <li><strong>Security hardening</strong> — SSRF guard with DNS pre-resolution + redirect re-validation + subresource blocklist; prompt-injection guard (multilingual + homoglyph NFKC-folded); 13 secret-detector families; socket-auth handshake; opt-in structured JSON logs with sink redaction.</li>
      <li><strong>JS-rendered web fetch</strong> — <code>senkani_web</code> returns AXTree markdown via WKWebView; version negotiation via <code>senkani_version</code>.</li>
      <li><strong>New website</strong> — this rebuild. Multi-page wiki + landing page per <code>spec/website_rebuild.md</code>.</li>
    </ul>

    <h2>Links</h2>
    <ul>
      <li><a href="__BASE__docs/changelog.html">Full changelog</a></li>
      <li><a href="https://github.com/ckluis/senkani">GitHub repo</a></li>
      <li><a href="__BASE__docs/about.html">About + license</a></li>
    </ul>
  </article>
</main>
'''
    return HEAD.format(title=title, desc=desc) + body + FOOT


def render_about():
    title = "About — senkani"
    desc = "License, credits, the name (閃蟹 — fast claw)."
    body = '''<main id="main" class="wiki-layout">
''' + wiki_nav_reference("") + '''
  <article class="wiki-main">
    <nav class="crumb" aria-label="Breadcrumb">
      <a href="__BASE__">Home</a> <span class="sep">›</span> <span class="here">About</span>
    </nav>
    <h1 class="page-title">About</h1>

    <h2>The name</h2>
    <p><strong lang="zh">閃蟹</strong> — "senkani" — literally <em>flash crab</em>, or "fast claw." The crab is a pincer; Senkani is the pincer between your agent and your filesystem. Snap, compress, return.</p>

    <h2>License</h2>
    <p>Core: <strong>MIT</strong>. See <a href="https://github.com/ckluis/senkani/blob/main/LICENSE">LICENSE</a>.</p>

    <h2>Built with</h2>
    <ul>
      <li><strong>Swift 6.0+</strong> — Sources/Core, Sources/Filter, Sources/Indexer, Sources/MCPServer, Sources/Bundle, Sources/HookRelay, Sources/CLI, SenkaniApp.</li>
      <li><strong>SwiftUI + SwiftTerm</strong> — the workspace.</li>
      <li><strong>tree-sitter</strong> — 25 vendored grammars for symbol extraction.</li>
      <li><strong>SQLite + FTS5</strong> — session DB, knowledge graph index, bench results.</li>
      <li><strong>Apple MLX</strong> — MiniLM embeddings, Gemma vision, Gemma rationale rewriter.</li>
    </ul>

    <h2>Platform</h2>
    <p>macOS 14+, Apple Silicon native universal binary. Intel macs run the core but not the MLX-accelerated tools.</p>

    <h2>Telemetry</h2>
    <p><strong>Off by default.</strong> Senkani does not send telemetry, usage data, or model outputs anywhere. The session database is local to your machine; <code>senkani export</code> is the only way data leaves the device, and only when you invoke it.</p>

    <h2>Links</h2>
    <ul>
      <li><a href="https://github.com/ckluis/senkani">GitHub</a></li>
      <li><a href="__BASE__docs/changelog.html">Changelog</a></li>
      <li><a href="https://github.com/ckluis/senkani/blob/main/LICENSE">LICENSE</a></li>
    </ul>
  </article>
</main>
'''
    return HEAD.format(title=title, desc=desc) + body + FOOT


def render_docs_root():
    title = "Docs — senkani"
    desc = "Wiki root: concepts, reference, guides, status, about, changelog."
    body = '''<main id="main" class="wiki-layout">
''' + wiki_nav_reference("") + '''
  <article class="wiki-main">
    <nav class="crumb" aria-label="Breadcrumb">
      <a href="__BASE__">Home</a> <span class="sep">›</span> <span class="here">Docs</span>
    </nav>
    <h1 class="page-title">Docs</h1>
    <p class="lede">The senkani wiki. Every MCP tool, CLI command, option, and pane has its own page. Concepts explain the why; guides walk you through how-tos; reference answers what-does-this-do.</p>

    <div class="card-grid">
      <a class="card" href="__BASE__docs/what-is-senkani.html"><h3>What is senkani?</h3><p>The product in one page — category, positioning, who it's for.</p></a>
      <a class="card" href="__BASE__docs/concepts/"><h3>Concepts</h3><p>Explanation. Why the three-layer stack, how the hook relay works, how compound learning mines your sessions.</p></a>
      <a class="card" href="__BASE__docs/reference/"><h3>Reference</h3><p>Every <code>senkani_*</code> MCP tool, every CLI command, every FCSIT option, every pane type.</p></a>
      <a class="card" href="__BASE__docs/guides/"><h3>Guides</h3><p>How-tos. Install, wire up Claude Code, set up budgets, review learned proposals, clean uninstall.</p></a>
      <a class="card" href="__BASE__docs/status.html"><h3>Status</h3><p>What's shipped in v0.2.0 + test count + feature checklist.</p></a>
      <a class="card" href="__BASE__docs/changelog.html"><h3>Changelog</h3><p>Release-by-release notes.</p></a>
    </div>
  </article>
</main>
'''
    return HEAD.format(title=title, desc=desc) + body + FOOT


def render_what_is_senkani():
    title = "What is senkani? — positioning + overview"
    desc = "Senkani is a native macOS trust boundary between your AI coding agent and your filesystem. Positioning + overview."
    body = '''<main id="main" class="wiki-layout">
''' + wiki_nav_concepts("") + '''
  <article class="wiki-main">
    <nav class="crumb" aria-label="Breadcrumb">
      <a href="__BASE__">Home</a> <span class="sep">›</span>
      <a href="__BASE__docs/">Docs</a> <span class="sep">›</span>
      <span class="here">What is senkani?</span>
    </nav>
    <span class="quadrant concept">Concept · Explanation</span>
    <h1 class="page-title">What is senkani?</h1>
    <p class="lede">Senkani is a native macOS binary that sits between your AI coding agent (Claude Code, Cursor, Copilot, any MCP-compatible tool) and your filesystem. Every tool call — read, grep, shell, build, search — is intercepted by a hook relay, answered by a local symbol index or filter pipeline where possible, and forwarded with only the output that matters.</p>

    <h2>The one-sentence version</h2>
    <p><strong>Senkani is a trust boundary.</strong> Your agent on one side, your filesystem on the other; the boundary compresses, redacts, caches, and learns.</p>

    <h2>The category</h2>
    <p>Senkani is a new category of developer tool. It is <em>not</em> a new coding agent, not an IDE plugin, not a cloud service, not a framework your code imports. It is a local compression-and-context layer that makes the agent you already use cheaper, faster, and safer — by intercepting the tool calls the agent makes on your behalf.</p>

    <div class="positioning-table" role="table" aria-label="Positioning">
      <div class="head">Dimension</div>
      <div class="head">Senkani is</div>
      <div class="head">Senkani is not</div>

      <div class="label">Category</div>
      <div class="yes">A token-compression + context layer for existing agents.</div>
      <div class="no">A new coding agent, IDE, editor, or chatbot.</div>

      <div class="label">Runtime</div>
      <div class="yes">One local macOS binary, fully offline after install.</div>
      <div class="no">A cloud service, SaaS, or plugin marketplace.</div>

      <div class="label">Trust</div>
      <div class="yes">A boundary: SSRF guard, secret redaction, injection guard, socket auth.</div>
      <div class="no">A model with opinions. The model on the far side is whatever you choose.</div>

      <div class="label">Integration</div>
      <div class="yes">Hooks + MCP server registered once in <code>~/.claude/settings.json</code>.</div>
      <div class="no">A wrapper, proxy, router, or replacement for Claude, Cursor, Copilot, Codex.</div>

      <div class="label">Locality</div>
      <div class="yes">On-device inference where local is enough (MiniLM embeds, Gemma vision).</div>
      <div class="no">A per-request API middleman that adds new costs.</div>

      <div class="label">Outputs</div>
      <div class="yes">A <a href="__BASE__docs/concepts/knowledge-base.html">knowledge graph</a>, a session DB, and <a href="__BASE__docs/concepts/compound-learning.html">learned artifacts</a> you can inspect.</div>
      <div class="no">A black box; every decision is logged, tunable, and reversible.</div>
    </div>

    <h2>Who it's for</h2>
    <ul>
      <li><strong>Developers running coding agents on real codebases.</strong> If your Claude Code session is eating 40k+ tokens on a medium refactor, the compression layer pays for itself on the first prompt.</li>
      <li><strong>Operators who care about trust boundaries.</strong> Secret redaction, SSRF hardening, prompt-injection scanning, and socket-auth handshakes all ship on by default.</li>
      <li><strong>People tired of configuring LLM stacks.</strong> <code>senkani init</code>, one command, idempotent, zero config files required.</li>
    </ul>

    <h2>How the pieces connect</h2>
    <p>Senkani has three layers, and all three ship in the same binary:</p>
    <ol>
      <li><a href="__BASE__docs/reference/mcp/">MCP tools</a> — 19 tools the agent can call directly. Compressed reads, filtered shells, symbol lookups, sandboxed parse, local embed/vision.</li>
      <li><a href="__BASE__docs/concepts/hook-relay.html">Hook relay</a> — intercepts the agent's built-in Read/Bash/Grep and routes to senkani equivalents or denies with cached results.</li>
      <li><a href="__BASE__docs/concepts/three-layer-stack.html">Smart denials</a> — re-read suppression, command replay, trivial routing, search upgrade. The filter decides a tool call doesn't need to run at all.</li>
    </ol>

    <h2>What it replaces (or augments)</h2>
    <ul>
      <li><code>Read</code> → <code>senkani_read</code> (compressed, cached, redacted) or <code>senkani_fetch</code> (symbol-only).</li>
      <li><code>Grep</code> → <code>senkani_search</code> (local tree-sitter index; 99% fewer tokens than text grep).</li>
      <li><code>Bash</code> → <code>senkani_exec</code> (24+ command-specific filter rules; mutating commands pass through unchanged).</li>
      <li>Per-repo briefs → <a href="__BASE__docs/reference/mcp/senkani_bundle.html"><code>senkani_bundle</code></a> (budget-bounded Markdown or JSON).</li>
      <li>Cloud embed / vision API calls → <a href="__BASE__docs/reference/mcp/senkani_embed.html"><code>senkani_embed</code></a> + <a href="__BASE__docs/reference/mcp/senkani_vision.html"><code>senkani_vision</code></a> on Apple Silicon.</li>
    </ul>

    <div class="callout callout-info">
      <span class="callout-icon">⚐</span>
      <div><strong>Savings multipliers vary.</strong> The <code>80.37×</code> figure on the landing page is the synthetic fixture ceiling. Live sessions typically land in the 3–15× range depending on workflow. The <a href="__BASE__docs/reference/panes/savings-test.html">Savings Test pane</a> shows both side by side, and the live number is the honest one.</div>
    </div>

    <h2>Next</h2>
    <ul>
      <li><a href="__BASE__docs/guides/install.html">Install senkani</a> — clone, build, <code>init</code>, launch.</li>
      <li><a href="__BASE__docs/concepts/three-layer-stack.html">Read about the three-layer stack</a>.</li>
      <li><a href="__BASE__docs/reference/mcp/">Browse the MCP tool reference</a>.</li>
    </ul>
  </article>
</main>
'''
    return HEAD.format(title=title, desc=desc) + body + FOOT


def render_changelog():
    title = "Changelog — senkani"
    desc = "Versioned release notes for senkani. Full detail from CHANGELOG.md in the repo."
    body = '''<main id="main" class="wiki-layout">
''' + wiki_nav_reference("") + '''
  <article class="wiki-main">
    <nav class="crumb" aria-label="Breadcrumb">
      <a href="__BASE__">Home</a> <span class="sep">›</span> <span class="here">Changelog</span>
    </nav>
    <h1 class="page-title">Changelog</h1>
    <p class="lede">Release notes per server version (reported by <a href="__BASE__docs/reference/mcp/senkani_version.html"><code>senkani_version</code></a>). Full detail lives in <a href="https://github.com/ckluis/senkani/blob/main/CHANGELOG.md">CHANGELOG.md</a> in the repo — this page is a curated summary.</p>

    <h2>v0.2.0 (current) — April 2026</h2>
    <ul>
      <li><strong>Website rebuild</strong> — multi-page wiki + tightened landing page. 19 MCP tools + 19 CLI commands + 17 panes each have their own URL. <a href="__BASE__docs/what-is-senkani.html">Start here</a>.</li>
      <li><strong>Security hardening (v0.2.0 release)</strong> — prompt-injection guard on, SSRF guard on (DNS pre-resolution + redirect re-validation + subresource blocklist), secret detection on (13 families + entropy), socket-auth opt-in, structured JSON logs opt-in with sink redaction, retention scheduler.</li>
      <li><strong>Compound learning + KB master plan</strong> — nine-round landing 2026-04-17: H+2b context signals, H+2c instruction/workflow generators with Schneier never-auto-apply, H+2d sprint + quarterly cadence, F+1 Layer-1 rebuild coordinator, F+2 entity tracker, F+3 enrichment validator + KB rollback, F+4 KB timeline, F+5 KB↔learning bridge.</li>
      <li><strong><code>senkani_repo</code></strong> — query any public GitHub repo without cloning. Host-allowlisted, SecretDetector-scanned, TTL-cached.</li>
      <li><strong>MLX inference lock</strong> — FIFO serialization + macOS memory-pressure-aware model drops across <code>senkani_embed</code>, <code>senkani_vision</code>, Gemma rationale rewriter.</li>
      <li><strong>Sprint Review pane</strong> — GUI counterpart to <code>senkani learn review</code>. Accept/reject staged proposals with stale-applied panel.</li>
      <li><strong>Grammar staleness advisory</strong> — non-blocking (SKIP not FAIL) to avoid CI false alarms.</li>
    </ul>

    <p>See the repo <a href="https://github.com/ckluis/senkani/blob/main/CHANGELOG.md">CHANGELOG.md</a> for dated per-feature detail.</p>
  </article>
</main>
'''
    return HEAD.format(title=title, desc=desc) + body + FOOT


# ============================================================
# OPTIONS PAGES
# ============================================================
def render_opt(slug: str, title: str, lede: str, body_html: str):
    full_title = f"{title} — options reference"
    desc = html.escape(lede)[:160]
    body = f'''<main id="main" class="wiki-layout">
{wiki_nav_options(slug)}
  <article class="wiki-main">
    <nav class="crumb" aria-label="Breadcrumb">
      <a href="__BASE__">Home</a> <span class="sep">›</span>
      <a href="__BASE__docs/reference/">Reference</a> <span class="sep">›</span>
      <a href="__BASE__docs/reference/options/">Options &amp; env</a> <span class="sep">›</span>
      <span class="here">{title}</span>
    </nav>
    <span class="quadrant reference">Reference · Information</span>
    <h1 class="page-title">{title}</h1>
    <p class="lede">{lede}</p>
{body_html}
  </article>
</main>
'''
    return HEAD.format(title=full_title, desc=desc) + body + FOOT


OPT_FCSIT = ("fcsit", "FCSIT — five per-pane toggles",
             "Each pane in the workspace carries five feature switches: <strong>F</strong>ilter, <strong>C</strong>ache, <strong>S</strong>ecrets, <strong>I</strong>ndexer, <strong>T</strong>erse. Set per-pane; persist to <code>~/.senkani/panes/{paneId}.env</code>; take effect immediately without a restart.",
             '''
    <div class="fcsit-card">
      <a class="fcsit-letter f" href="__BASE__docs/reference/options/filter.html"><span class="ltr">F</span><span class="name">Filter</span><span class="default">default on</span></a>
      <a class="fcsit-letter c" href="__BASE__docs/reference/options/cache.html"><span class="ltr">C</span><span class="name">Cache</span><span class="default">default on</span></a>
      <a class="fcsit-letter s" href="__BASE__docs/reference/options/secrets.html"><span class="ltr">S</span><span class="name">Secrets</span><span class="default">default on</span></a>
      <a class="fcsit-letter i" href="__BASE__docs/reference/options/indexer.html"><span class="ltr">I</span><span class="name">Indexer</span><span class="default">default on</span></a>
      <a class="fcsit-letter t" href="__BASE__docs/reference/options/terse.html"><span class="ltr">T</span><span class="name">Terse</span><span class="default">default off</span></a>
    </div>

    <h2>What each letter controls</h2>
    <div class="ref-io-table">
      <div class="head">Letter</div><div class="head">Feature</div><div class="head">Default</div><div class="head">What it does</div>
      <div class="k">F</div><div class="t">Filter</div><div class="default">on</div><div class="desc"><a href="__BASE__docs/reference/options/filter.html">Filter pipeline</a> — 24 command-specific output rules applied to <code>senkani_exec</code>.</div>
      <div class="k">C</div><div class="t">Cache</div><div class="default">on</div><div class="desc"><a href="__BASE__docs/reference/options/cache.html">Read cache</a> — keyed on (path, mtime); unchanged files return from memory.</div>
      <div class="k">S</div><div class="t">Secrets</div><div class="default">on</div><div class="desc"><a href="__BASE__docs/reference/options/secrets.html">SecretDetector</a> — 13 regex families + entropy fallback on every tool output.</div>
      <div class="k">I</div><div class="t">Indexer</div><div class="default">on</div><div class="desc"><a href="__BASE__docs/reference/options/indexer.html">Symbol indexer</a> — <code>senkani_search</code>, <code>senkani_fetch</code>, <code>senkani_outline</code> active.</div>
      <div class="k">T</div><div class="t">Terse</div><div class="default">off</div><div class="desc"><a href="__BASE__docs/reference/options/terse.html">Terse mode</a> — output-token reduction via system-prompt injection + phrase strip.</div>
    </div>

    <h2>How to toggle</h2>
    <ul>
      <li><strong>UI:</strong> click the letter in the pane header — it highlights when on.</li>
      <li><strong>Env var:</strong> <code>SENKANI_FILTER=on|off</code>, <code>SENKANI_CACHE=on|off</code>, <code>SENKANI_SECRETS=on|off</code>, <code>SENKANI_INDEXER=on|off</code>, <code>SENKANI_TERSE=on|off</code>.</li>
      <li><strong>MCP:</strong> <code>senkani_session</code> with <code>action:"toggle", feature:"filter"</code>.</li>
    </ul>

    <h2>Per-pane vs global</h2>
    <p>FCSIT is <strong>per-pane</strong>. Different panes can run different combinations — a terse-mode research pane alongside a full-fidelity build pane. Global defaults come from <code>~/.senkani/config.json</code>; env vars override per pane; the UI toggle is the final say for the current session.</p>
''')

OPT_FILTER = ("filter", "F — Filter pipeline",
              "The 24 command-specific rules that compress <code>senkani_exec</code> output. Mutating commands pass through unchanged.",
              '''
    <h2>What it does</h2>
    <p>Matches <code>(command, subcommand)</code> pairs to rule chains. <code>git status</code>, <code>git diff</code>, <code>git log</code>, <code>npm install</code>, <code>yarn install</code>, <code>pnpm install</code>, <code>pip install</code>, <code>make</code>, <code>cargo build</code>, <code>swift build</code>, <code>curl -v</code>, <code>docker pull</code>, <code>terraform plan</code>, and ~11 more. Each rule is a pure function of <code>(cmd, stdout, stderr)</code> and has regression tests.</p>

    <h2>What it doesn't touch</h2>
    <ul>
      <li><code>git commit</code>, <code>git push</code>, <code>git reset</code> — mutating.</li>
      <li><code>rm</code>, <code>mv</code>, <code>cp</code> — filesystem mutations.</li>
      <li><code>docker run</code>, <code>terraform apply</code> — external mutations.</li>
      <li>Any command not in the rule set — passthrough.</li>
    </ul>

    <h2>Env var</h2>
    <p><code>SENKANI_FILTER=on|off</code> — default <strong>on</strong>. Setting <code>off</code> disables the filter for the pane's session; raw output flows through.</p>

    <h2>Savings</h2>
    <p><strong>60–90%</strong> on read-only commands (<code>git status</code>, <code>npm install</code>, <code>git diff</code>). <strong>0%</strong> on mutating commands (by design).</p>

    <div class="seealso"><h3>See also</h3><ul>
      <li><a href="__BASE__docs/reference/mcp/senkani_exec.html"><code>senkani_exec</code> — the MCP tool</a></li>
      <li><a href="__BASE__docs/reference/cli/senkani-exec.html"><code>senkani exec</code> — the CLI wrapper</a></li>
      <li><a href="__BASE__docs/concepts/compression-layer.html">Why we compress at the filter layer</a></li>
      <li><a href="__BASE__docs/concepts/compound-learning.html">New rules mined from your sessions</a></li>
    </ul></div>
''')

OPT_CACHE = ("cache", "C — Read cache",
             "Session-scoped file-read cache keyed on <code>(path, mtime)</code>. Unchanged files return instantly from memory.",
             '''
    <h2>What it does</h2>
    <p>Every <code>senkani_read</code> (and every intercepted built-in <code>Read</code>) populates the cache. Subsequent reads of the same path with the same <code>mtime</code> return from memory — zero tokens, zero disk I/O. A file change (touch, edit) evicts its entry.</p>

    <h2>Env var</h2>
    <p><code>SENKANI_CACHE=on|off</code> — default <strong>on</strong>.</p>

    <h2>Where it lives</h2>
    <p>In-process only. Cleared on pane close. To wipe explicitly: <code>senkani_session</code> with <code>action:"clear-cache"</code>.</p>

    <div class="seealso"><h3>See also</h3><ul>
      <li><a href="__BASE__docs/reference/mcp/senkani_read.html"><code>senkani_read</code></a></li>
      <li><a href="__BASE__docs/concepts/three-layer-stack.html">Layer 3: re-read suppression</a></li>
    </ul></div>
''')

OPT_SECRETS = ("secrets", "S — Secret detection",
               "13 regex families + entropy fallback on every tool output. On by default; turning off is an explicit statement.",
               '''
    <h2>What it detects</h2>
    <p>API keys (OpenAI, Anthropic, Stripe, Slack, GitHub, GitLab, npm, AWS, GCP, HuggingFace), bearer tokens, JWTs, SSH private keys, <code>.env</code>-style <code>KEY=value</code> patterns for known-sensitive keys, and high-entropy strings in suspicious contexts. Each hit is replaced with <code>[REDACTED:&lt;family&gt;]</code> before the agent sees it.</p>

    <h2>Performance</h2>
    <p>The detector short-circuits with <code>firstMatch</code> so no-match inputs don't pay the full regex cost (1 MB benign input: ~25 ms).</p>

    <h2>Env var</h2>
    <p><code>SENKANI_SECRETS=on|off</code> — default <strong>on</strong>. Don't turn this off unless you're running a test fixture that intentionally produces secret-shaped strings.</p>

    <div class="seealso"><h3>See also</h3><ul>
      <li><a href="__BASE__docs/reference/options/security.html">Full security env-var reference</a></li>
      <li><a href="__BASE__docs/concepts/security-posture.html">Security posture concept</a></li>
    </ul></div>
''')

OPT_INDEXER = ("indexer", "I — Symbol indexer",
               "Tree-sitter-backed symbol index. Enables <code>senkani_search</code>, <code>senkani_fetch</code>, <code>senkani_outline</code>, <code>senkani_deps</code>, <code>senkani_explore</code>.",
               '''
    <h2>What it does</h2>
    <p>Extracts symbols from source files via 25 vendored tree-sitter grammars; keeps the index in memory; updates incrementally via FSEvents; persists BM25 + FTS5 search index. Cold search &lt; 5 ms, cached &lt; 1 ms.</p>

    <h2>Env var</h2>
    <p><code>SENKANI_INDEXER=on|off</code> — default <strong>on</strong>. Off disables symbol tools for the pane; agents fall back to text-grep (expensive).</p>

    <h2>Languages</h2>
    <p>TypeScript, JavaScript, Python, Go, Rust, Swift, Java, Kotlin, Ruby, C, C++, C#, PHP, Scala, OCaml, Haskell, Elixir, Erlang, Dart, TOML, YAML, JSON, HTML, CSS, GraphQL. Run <code>senkani grammars</code> to see the vendored list.</p>

    <div class="seealso"><h3>See also</h3><ul>
      <li><a href="__BASE__docs/reference/mcp/senkani_search.html"><code>senkani_search</code></a></li>
      <li><a href="__BASE__docs/reference/cli/senkani-grammars.html"><code>senkani grammars</code></a></li>
      <li><a href="__BASE__docs/concepts/mcp-intelligence.html">How the index is built</a></li>
    </ul></div>
''')

OPT_TERSE = ("terse", "T — Terse mode",
             "Output-token reduction. Two layers: a system-prompt injection that asks the model to strip filler, and a post-filter that strips filler phrases from tool outputs before they reach the model.",
             '''
    <h2>System-prompt injection (layer 1)</h2>
    <p>When <strong>T</strong> is enabled for a pane, the MCP session prepends this message to every tool result:</p>
    <pre class="code"><span class="c">// Injected before every tool result when T is on</span>
<span class="w">CRITICAL: You are in TERSE MODE. ALL responses must minimize
output tokens ruthlessly. No preamble, no summaries, no apologies,
no "I'll help you with", no "Let me know if you need anything else."
Respond only with exactly what was asked. Code blocks pass through
unchanged — only prose is compressed.</span></pre>
    <p>The model receives this before processing each response and adjusts its output accordingly.</p>

    <h2>Algorithmic minimization (layer 2)</h2>
    <p>A second layer strips filler phrases from tool outputs before forwarding them — removing the noise before it reaches the model, not after. Code blocks are passed through unchanged.</p>
    <p>Stripped phrase patterns (case-insensitive): "It looks like", "I'll help you with", "Certainly!", "Of course!", "Let me know if", "I hope this helps", "Feel free to", "Is there anything else", "Happy to help", "I'd be happy to".</p>

    <h2>Synergy</h2>
    <p>Terse works synergistically with F/C/S/I: those reduce <strong>input</strong> tokens; T reduces <strong>output</strong> tokens. Combined effect on a typical session: 40–65% total token reduction vs no compression.</p>

    <h2>Env var</h2>
    <p><code>SENKANI_TERSE=on|off</code> — default <strong>off</strong>. Enable it when you want tight, machine-readable responses; disable it when you're pair-programming and want the model's explanations intact.</p>

    <div class="seealso"><h3>See also</h3><ul>
      <li><a href="__BASE__docs/reference/options/fcsit.html">FCSIT overview</a></li>
      <li><a href="__BASE__docs/concepts/compression-layer.html">Where terse fits in the compression stack</a></li>
    </ul></div>
''')

OPT_BUDGET = ("budget", "Budget caps",
              "Daily and weekly spend ceilings enforced at the hook layer. When you hit a cap, new tool calls are denied with a clear message.",
              '''
    <h2>Env vars</h2>
    <p><code>SENKANI_BUDGET_DAILY=5.00</code> — daily spend cap in USD (default <strong>$5.00</strong>).<br>
    <code>SENKANI_BUDGET_WEEKLY=25.00</code> — weekly spend cap in USD (default <strong>$25.00</strong>).</p>

    <h2>How enforcement works</h2>
    <p>The hook layer queries <code>costForToday()</code> and <code>costForWeek()</code> from the session DB (aggregated from <code>token_events</code>) before approving a tool call. When a cap is exceeded, the hook denies with a structured error message that the agent sees — not a silent failure.</p>

    <h2>Dual-layer enforcement</h2>
    <p>Enforcement runs at both the pre-tool-use hook AND the MCP server — so denial happens even if the agent bypasses the Senkani tools and calls built-ins directly.</p>

    <h2>Reset</h2>
    <p>Daily resets at midnight local. Weekly resets Monday 00:00 local. No manual reset — the cap is a ceiling on lifetime spend, not a bank.</p>

    <div class="seealso"><h3>See also</h3><ul>
      <li><a href="__BASE__docs/guides/budget-setup.html">Budget setup guide</a></li>
      <li><a href="__BASE__docs/reference/cli/senkani-stats.html"><code>senkani stats</code> — see your spend</a></li>
    </ul></div>
''')

OPT_SECURITY = ("security", "Security env vars",
                "Every <code>SENKANI_*</code> variable that affects the trust boundary. Defaults are secure; overrides are explicit.",
                '''
    <h2>Prompt-injection guard</h2>
    <p><code>SENKANI_INJECTION_GUARD=on|off</code> — default <strong>on</strong>. Scans every MCP tool response for instruction-override, tool-call injection, context-manipulation, and exfiltration patterns, with anti-evasion normalization (lowercase, zero-width strip, Cyrillic→Latin homoglyphs). Single linear pass.</p>

    <h2>Socket authentication</h2>
    <p><code>SENKANI_SOCKET_AUTH=on</code> — default <strong>off</strong> (v0.2.0; flipping to on next release). Generates a 32-byte random token at <code>~/.senkani/.token</code> (mode 0600), rotated on every server start. Every connection to <code>mcp.sock</code>/<code>hook.sock</code>/<code>pane.sock</code> must send a length-prefixed handshake frame matching the token before normal protocol begins. Raises the bar from ambient same-UID socket access to must-read-token-file.</p>

    <h2>Structured JSON logs</h2>
    <p><code>SENKANI_LOG_JSON=1</code> — default off. When on, emits one JSON object per critical event to stderr. Every <code>.string(_)</code> log field passes through <code>SecretDetector.scan</code> at emit time — a stray API key in a log field is automatically <code>[REDACTED:…]</code>'d.</p>

    <h2>Instructions payload byte cap</h2>
    <p><code>SENKANI_INSTRUCTIONS_BUDGET_BYTES</code> — default <strong>2048</strong>. The <code>instructions</code> string injected at MCP server start (repo map + session brief + skills) is capped at 2 KB by default. Prevents the per-session-start token tax from growing with project size.</p>

    <h2>Observability counters</h2>
    <p>Every security-defense site increments an <code>event_counters</code> row (migration v2): injection detections, SSRF blocks, socket handshake rejections, schema migrations, retention prunes, command redactions. Read them via <code>senkani stats --security</code>.</p>

    <div class="seealso"><h3>See also</h3><ul>
      <li><a href="__BASE__docs/concepts/security-posture.html">Security posture concept</a></li>
      <li><a href="__BASE__docs/reference/options/web.html">Web-specific SSRF overrides</a></li>
      <li><a href="__BASE__docs/reference/options/secrets.html">Secret detection (FCSIT S)</a></li>
    </ul></div>
''')

OPT_WEB = ("web", "Web env vars",
           "Overrides for the <code>senkani_web</code> SSRF guard. Only touch these if you know what you're doing.",
           '''
    <h2>SSRF guard bypass</h2>
    <p><code>SENKANI_WEB_ALLOW_PRIVATE=on</code> — default <strong>off</strong>. Normally, <code>senkani_web</code> blocks any address in private/link-local/CGNAT/multicast ranges (including IPv4-mapped IPv6 and octal/hex IPv4). Redirects are re-validated. Subresources (img/script/xhr/etc.) to the same ranges are blocked via <code>WKContentRuleList</code>. Setting this env var to <code>on</code> lifts the private-range block — use only for internal doc servers on a trusted network.</p>

    <div class="callout callout-warn">
      <span class="callout-icon">⚠</span>
      <div><strong>This is not a "make it work" switch.</strong> Cloud metadata endpoints (169.254.169.254, fd00:ec2::254) are accessible from your machine if this is on. Senkani's SSRF guard exists specifically to keep those endpoints unreachable from LLM-controlled HTTP requests. Bypass at your own risk.</div>
    </div>

    <h2>Scheme scope</h2>
    <p><code>file://</code> is never accepted by <code>senkani_web</code>. Use <a href="__BASE__docs/reference/mcp/senkani_read.html"><code>senkani_read</code></a> for local files.</p>

    <div class="seealso"><h3>See also</h3><ul>
      <li><a href="__BASE__docs/reference/mcp/senkani_web.html"><code>senkani_web</code> — behavior + security</a></li>
      <li><a href="__BASE__docs/concepts/security-posture.html">Trust boundary concept</a></li>
    </ul></div>
''')

OPT_CL = ("compound-learning", "Compound-learning env",
          "Confidence thresholds, recurrence gates, Gemma enrichment rate limits. Tune via <code>~/.senkani/compound-learning.json</code> or <code>SENKANI_COMPOUND_*</code> env vars.",
          '''
    <h2>Thresholds</h2>
    <ul>
      <li><code>SENKANI_COMPOUND_RECURRENCE=3</code> — min distinct sessions for a pattern to promote from <code>.recurring</code> to <code>.staged</code>. Default <strong>3</strong>.</li>
      <li><code>SENKANI_COMPOUND_CONFIDENCE=0.7</code> — min Laplace-smoothed confidence (0.0–1.0) for promotion. Default <strong>0.7</strong>.</li>
      <li><code>SENKANI_COMPOUND_SWEEP_CRON=…</code> — when to run the daily recurrence sweep. Default: lazy, at session start.</li>
    </ul>

    <h2>Instruction-patch safety</h2>
    <p>Instruction patches (H+2c) <strong>never auto-apply</strong> from the daily sweep — per Schneier gate. You explicitly run <code>senkani learn apply &lt;id&gt;</code>. This is not tunable; it's a design constraint.</p>

    <h2>Gemma enrichment</h2>
    <p>Gemma 4 optionally enriches rationale strings (H+2a). Contained to a dedicated <code>enrichedRationale</code> field — never enters <code>FilterPipeline</code>.</p>

    <div class="seealso"><h3>See also</h3><ul>
      <li><a href="__BASE__docs/concepts/compound-learning.html">Compound learning concept</a></li>
      <li><a href="__BASE__docs/reference/cli/senkani-learn.html"><code>senkani learn</code> CLI</a></li>
      <li><a href="__BASE__docs/guides/compound-learning.html">Reviewing proposals guide</a></li>
    </ul></div>
''')

ALL_OPTS = [OPT_FCSIT, OPT_FILTER, OPT_CACHE, OPT_SECRETS, OPT_INDEXER, OPT_TERSE, OPT_BUDGET, OPT_SECURITY, OPT_WEB, OPT_CL]


# ============================================================
# CONCEPT PAGES
# ============================================================
def render_concept(slug: str, title: str, lede: str, body_html: str, see_also: list[tuple[str, str]] = None):
    full_title = f"{title} — concept"
    desc = html.escape(lede)[:160]
    see_also = see_also or []
    sa = "\n".join(f'        <li><a href="{h}">{t}</a></li>' for t, h in see_also)
    body = f'''<main id="main" class="wiki-layout">
{wiki_nav_concepts(slug)}
  <article class="wiki-main">
    <nav class="crumb" aria-label="Breadcrumb">
      <a href="__BASE__">Home</a> <span class="sep">›</span>
      <a href="__BASE__docs/concepts/">Concepts</a> <span class="sep">›</span>
      <span class="here">{title}</span>
    </nav>
    <span class="quadrant concept">Concept · Explanation</span>
    <h1 class="page-title">{title}</h1>
    <p class="lede">{lede}</p>
{body_html}
    <div class="seealso"><h3>See also</h3><ul>
{sa}
    </ul></div>
  </article>
</main>
'''
    return HEAD.format(title=full_title, desc=desc) + body + FOOT


CONCEPTS = [
    ("compression-layer", "Compression layer",
     "Senkani compresses at three places, not one. Input compression shrinks tool outputs before the LLM sees them; redundancy elimination stops redundant tool calls from running; output compression (terse mode) shrinks what the model emits. All three run in the same binary, toggleable per pane.",
     '''
    <h2>The three compression surfaces</h2>
    <p>A naïve "LLM token reducer" would just filter tool outputs. Senkani does that, but it's not enough on its own. A session that reads the same file 5 times costs 5× no matter how compressed each read is. A session that deterministically runs <code>npm test</code> three times in a row is wasting 3× the tokens, with or without filters.</p>

    <h2>Surface 1 — input compression (FCSIT F + I)</h2>
    <p>Every tool output that comes <em>back</em> to the model runs through the relevant reducer:</p>
    <ul>
      <li><strong><a href="__BASE__docs/reference/mcp/senkani_exec.html"><code>senkani_exec</code></a></strong> applies 24+ command-specific rules. <code>npm install</code>: 428 lines → 2. <code>git clone</code>: 312 → 4. <code>git diff</code>: adaptive truncation + dedup.</li>
      <li><strong><a href="__BASE__docs/reference/mcp/senkani_read.html"><code>senkani_read</code></a></strong> returns outlines (symbols + line numbers) by default, not full content. Full mode requires <code>full: true</code>.</li>
      <li><strong><a href="__BASE__docs/reference/mcp/senkani_search.html"><code>senkani_search</code></a></strong> returns ~50 tokens from the local tree-sitter index instead of ~5,000 from grepping.</li>
      <li><strong><a href="__BASE__docs/reference/mcp/senkani_fetch.html"><code>senkani_fetch</code></a></strong> returns only a single symbol's line range.</li>
    </ul>

    <h2>Surface 2 — redundancy elimination (hook Layer 3)</h2>
    <p>The hook relay keeps a short-term memory of what the agent has already asked. When the same question comes in again, the hook answers from cache — or denies with a message pointing at the cached result. See <a href="__BASE__docs/concepts/three-layer-stack.html">three-layer stack</a> for the five denial patterns.</p>

    <h2>Surface 3 — output compression (FCSIT T)</h2>
    <p><a href="__BASE__docs/reference/options/terse.html">Terse mode</a> shrinks the model's <em>output</em>, not just its input. Two layers: a system-prompt injection that tells the model to strip filler, and a post-filter that strips filler phrases from tool outputs on the way <em>in</em> (so the model doesn't learn to mimic them).</p>

    <h2>Why all three</h2>
    <p>Each surface addresses a different waste mode:</p>
    <ul>
      <li>Surface 1 — raw tool output is noisy. Compress the noise.</li>
      <li>Surface 2 — agents re-ask. Don't run the call at all.</li>
      <li>Surface 3 — models are verbose. Shrink the response.</li>
    </ul>
    <p>Skipping any one leaves measurable tokens on the table. The fixture benchmark (<a href="__BASE__docs/reference/cli/senkani-bench.html"><code>senkani bench</code></a>) isolates each surface; the <a href="__BASE__docs/reference/panes/savings-test.html">Savings Test pane</a> shows live-session breakdowns by source.</p>

    <h2>What it's not</h2>
    <p>Senkani is not a lossy summarizer. It doesn't paraphrase your code; it doesn't drop information the model legitimately needs. Every elided line is either byte-level redundancy (repeated ANSI codes, blank-line runs, progress bars) or structural redundancy (outline instead of body when the body wasn't asked for). If the agent needs the full file, it passes <code>full: true</code>.</p>
''',
     [("senkani_exec (filter)", "__BASE__docs/reference/mcp/senkani_exec.html"),
      ("senkani_read (outline)", "__BASE__docs/reference/mcp/senkani_read.html"),
      ("Three-layer stack", "__BASE__docs/concepts/three-layer-stack.html"),
      ("Terse mode (options)", "__BASE__docs/reference/options/terse.html"),
      ("Filter option (F)", "__BASE__docs/reference/options/filter.html")]),

    ("hook-relay", "Hook relay",
     "The <code>senkani-hook</code> binary is a zero-dependency Mach-O that Claude Code (and other MCP-capable agents) runs before every Read/Bash/Grep/Write/Edit tool call. It decides: allow, allow-with-rewrite, or deny.",
     '''
    <h2>What it intercepts</h2>
    <p>Registered during <a href="__BASE__docs/reference/cli/senkani-init.html"><code>senkani init</code></a> with matcher <code>Read|Bash|Grep|Write|Edit</code>. Claude Code fires PreToolUse hook → the hook binary runs (&lt; 5 ms active, &lt; 1 ms passthrough) → the hook returns a decision.</p>

    <h2>The three outcomes</h2>
    <ol>
      <li><strong>Allow + pass through.</strong> The tool runs as requested. Common for <code>Write</code>, <code>Edit</code>, and mutating <code>Bash</code>.</li>
      <li><strong>Allow + rewrite.</strong> The tool still runs, but output is post-processed (secret redaction, ANSI strip, filter rules). Common for <code>Read</code> and <code>Bash</code>.</li>
      <li><strong>Deny with a reason.</strong> The tool does not run. The reason string goes to the model — often with a cached answer inline. Common for re-reads of unchanged files, <code>ls</code>/<code>pwd</code>, redundant build re-runs.</li>
    </ol>

    <h2>Why a separate binary</h2>
    <p>Claude Code's hook protocol spawns a fresh process per tool call. Swift apps with full MLX linkage take tens of milliseconds to start; that's too slow to sit in front of every tool call. So the hook is a minimal binary (<code>Sources/Hook</code>), zero MLX dependency, IPC-connects to the long-running MCP server via a Unix-domain socket.</p>

    <h2>The shared HookRelay library</h2>
    <p><code>Sources/HookRelay/</code> is imported by both <code>senkani-hook</code> (the standalone binary) and the main app's <code>--hook</code> mode (useful during testing). Same decision logic, same socket wire format.</p>

    <h2>SENKANI_PANE_ID gating</h2>
    <p>MCP tools are only active in Senkani-managed terminals — the app injects <code>SENKANI_PANE_ID=&lt;id&gt;</code> when it spawns a pane's shell. Non-Senkani terminals never see senkani tools even if the MCP server is running globally. This prevents pollution and keeps the trust boundary well-defined.</p>

    <h2>Socket-auth handshake</h2>
    <p>With <code>SENKANI_SOCKET_AUTH=on</code>, every hook connection sends a length-prefixed handshake frame matching the token at <code>~/.senkani/.token</code> (mode 0600, rotated on every server start). Ambient same-UID attackers can no longer talk to the sockets; they'd need to read the token file too.</p>
''',
     [("senkani init CLI", "__BASE__docs/reference/cli/senkani-init.html"),
      ("Three-layer stack", "__BASE__docs/concepts/three-layer-stack.html"),
      ("Socket auth (security env)", "__BASE__docs/reference/options/security.html")]),

    ("mcp-intelligence", "MCP intelligence",
     "MCP — Model Context Protocol — is the standard JSON-RPC interface an LLM agent uses to call tools. Senkani exposes 19 MCP tools specifically designed for the friction points of agent-driven coding sessions.",
     '''
    <h2>Why MCP</h2>
    <p>An MCP-aware agent doesn't hard-code tool definitions; it asks the server what tools exist and what their schemas look like. Senkani's MCP server registers once via <code>senkani init</code>, and every MCP-compatible agent (Claude Code, Cursor if you wire it up, Copilot if you wire it up, any custom client) can call the same 19 tools.</p>

    <h2>The 19 tools, classified</h2>
    <ul>
      <li><strong>Perception</strong> — <a href="__BASE__docs/reference/mcp/senkani_read.html"><code>senkani_read</code></a>, <a href="__BASE__docs/reference/mcp/senkani_fetch.html"><code>senkani_fetch</code></a>, <a href="__BASE__docs/reference/mcp/senkani_outline.html"><code>senkani_outline</code></a>, <a href="__BASE__docs/reference/mcp/senkani_search.html"><code>senkani_search</code></a>, <a href="__BASE__docs/reference/mcp/senkani_deps.html"><code>senkani_deps</code></a>, <a href="__BASE__docs/reference/mcp/senkani_explore.html"><code>senkani_explore</code></a>.</li>
      <li><strong>Action</strong> — <a href="__BASE__docs/reference/mcp/senkani_exec.html"><code>senkani_exec</code></a>, <a href="__BASE__docs/reference/mcp/senkani_validate.html"><code>senkani_validate</code></a>, <a href="__BASE__docs/reference/mcp/senkani_parse.html"><code>senkani_parse</code></a>.</li>
      <li><strong>External</strong> — <a href="__BASE__docs/reference/mcp/senkani_web.html"><code>senkani_web</code></a>, <a href="__BASE__docs/reference/mcp/senkani_repo.html"><code>senkani_repo</code></a>.</li>
      <li><strong>Local ML</strong> — <a href="__BASE__docs/reference/mcp/senkani_embed.html"><code>senkani_embed</code></a>, <a href="__BASE__docs/reference/mcp/senkani_vision.html"><code>senkani_vision</code></a>.</li>
      <li><strong>Session + state</strong> — <a href="__BASE__docs/reference/mcp/senkani_session.html"><code>senkani_session</code></a>, <a href="__BASE__docs/reference/mcp/senkani_watch.html"><code>senkani_watch</code></a>, <a href="__BASE__docs/reference/mcp/senkani_pane.html"><code>senkani_pane</code></a>.</li>
      <li><strong>Knowledge</strong> — <a href="__BASE__docs/reference/mcp/senkani_knowledge.html"><code>senkani_knowledge</code></a>, <a href="__BASE__docs/reference/mcp/senkani_bundle.html"><code>senkani_bundle</code></a>.</li>
      <li><strong>Meta</strong> — <a href="__BASE__docs/reference/mcp/senkani_version.html"><code>senkani_version</code></a>.</li>
    </ul>

    <h2>How the indexer backs Perception</h2>
    <p>Four of the six perception tools are one thin wrapper over the same tree-sitter-backed symbol index: 25 vendored grammars, FTS5 full-text search, BM25 ranking with optional RRF fusion via MiniLM file embeddings, bidirectional dependency graph built at index time, FSEvents-driven incremental updates. Cold search &lt; 5 ms; cached &lt; 1 ms.</p>

    <h2>How MLX backs Local ML</h2>
    <p><code>senkani_embed</code> runs MiniLM-L6-v2 via MLX on the Neural Engine (sub-200 ms; 384-dim Float32). <code>senkani_vision</code> runs Gemma via MLX (sub-500 ms on M-series). Shared <code>MLXInferenceLock</code> FIFO-serializes every MLX call so the Neural Engine doesn't see concurrent contention; loaded model containers drop on macOS memory-pressure warnings.</p>

    <h2>Version negotiation</h2>
    <p><code>senkani_version</code> returns <code>server_version</code>, <code>tool_schemas_version</code>, and <code>schema_db_version</code>. Clients cache tool schemas keyed on <code>tool_schemas_version</code>; that number increments only on breaking changes. <code>schema_db_version</code> surfaces <code>PRAGMA user_version</code> on the session DB for migration diagnostics.</p>
''',
     [("All MCP tools", "__BASE__docs/reference/mcp/"),
      ("Tree-sitter grammars (senkani grammars)", "__BASE__docs/reference/cli/senkani-grammars.html"),
      ("Model Manager pane", "__BASE__docs/reference/panes/model-manager.html"),
      ("Compression layer", "__BASE__docs/concepts/compression-layer.html")]),

    ("three-layer-stack", "The three-layer stack",
     "Senkani compresses at three places — Layer 1 (MCP tools), Layer 2 (smart hooks), Layer 3 (preemptive interception). Each layer catches waste the other layers can't.",
     '''
    <h2>Layer 1 — MCP tools</h2>
    <p>The agent calls <code>senkani_read</code> instead of <code>Read</code>, <code>senkani_exec</code> instead of <code>Bash</code>, <code>senkani_search</code> instead of <code>Grep</code>. Each tool is cached, compressed, and secret-redacted by construction. This is the happy path.</p>

    <h2>Layer 2 — Smart hooks</h2>
    <p>Not every agent cooperates. Sometimes an agent calls built-in <code>Read</code> directly instead of <code>senkani_read</code>. Layer 2 intercepts the built-in and rewrites the response through the filter pipeline on the way out. Same compression, worse ergonomics (the agent's tool sheet doesn't show the senkani alternative), but the savings still land.</p>

    <h2>Layer 3 — Preemptive interception (smart denials)</h2>
    <p>Some calls shouldn't run at all. Layer 3 is five pattern matchers that deny with a cached answer:</p>
    <ol>
      <li><strong>Re-read suppression.</strong> The agent just read <code>src/auth.ts</code>; it didn't change; the next <code>Read src/auth.ts</code> is suppressed. The deny reason says "read 42s ago, unchanged."</li>
      <li><strong>Command replay.</strong> Deterministic commands (<code>npm test</code>, <code>swift build</code>, <code>pytest</code>) with no file changes since the last invocation → deny with the cached result.</li>
      <li><strong>Trivial routing.</strong> <code>pwd</code>, <code>ls</code>, <code>echo $HOME</code> → answer in the deny reason. Saves a round-trip.</li>
      <li><strong>Search upgrade.</strong> Three sequential <code>Read</code>s on small related files → deny the third with a hint to use <code>senkani_search</code>.</li>
      <li><strong>Redundant validation.</strong> If a build/lint command already ran with no file changes since, subsequent re-runs are covered by command replay.</li>
    </ol>

    <h2>Why three layers, not one</h2>
    <p>Layer 1 depends on the agent cooperating. Layer 2 handles the common case of a slightly-uncooperative agent. Layer 3 handles pathological waste patterns that neither layer would catch: re-reads, re-runs, round-trippable trivia. On cooperative sessions, Layers 2 and 3 fire rarely. On pathological sessions, they rescue 40–60% of tokens.</p>

    <h2>How denials feel to the model</h2>
    <p>A denial is not a failure — it's a structured response. The model sees the reason (e.g., "read 42s ago, unchanged"), often with the cached content inline. It continues with the real answer, not a retry. No training signal needed; the agent just reads the deny reason like any other tool result.</p>
''',
     [("Hook relay", "__BASE__docs/concepts/hook-relay.html"),
      ("senkani_read", "__BASE__docs/reference/mcp/senkani_read.html"),
      ("Compression layer", "__BASE__docs/concepts/compression-layer.html")]),

    ("compound-learning", "Compound learning",
     "Senkani mines your own sessions for patterns and surfaces four artifact types: filter rules, context docs, instruction patches, workflow playbooks. Patterns flow <code>.recurring → .staged → .applied</code>.",
     '''
    <h2>The lifecycle</h2>
    <p>Every session's tool calls, outputs, and retries are logged to the session DB. A daily sweep (lazy — runs at session start) looks at the recurring set and promotes any pattern meeting <code>recurrence ≥ 3 AND confidence ≥ 0.7</code> (Laplace-smoothed) to <code>.staged</code>. You review staged proposals in the <a href="__BASE__docs/reference/panes/sprint-review.html">Sprint Review pane</a> or via <a href="__BASE__docs/reference/cli/senkani-learn.html"><code>senkani learn review</code></a>. Accepted proposals move to <code>.applied</code>; applied artifacts take effect on the next session.</p>

    <h2>Filter rules (H, H+1)</h2>
    <p>The post-session waste analyzer notices when output from <code>command X</code> gets repeatedly truncated to its first N lines or has a substring stripped. It proposes a filter rule (<code>head(50)</code>, <code>stripMatching("progress")</code>) for future invocations. Regression-gated on real <code>commands.output_preview</code> samples — the proposed rule must not break outputs that previously passed through cleanly.</p>

    <h2>Context docs (H+2b)</h2>
    <p>Files read across ≥ 3 distinct sessions become priming documents at <code>.senkani/context/&lt;title&gt;.md</code>, injected into the next session's brief as a one-line "Learned:" section. The body is scanned by <code>SecretDetector</code> on every read and write.</p>

    <h2>Instruction patches (H+2c) — never auto-apply</h2>
    <p>Tool hints derived from per-session retry patterns. Example: if the agent consistently retries <code>Read</code> after getting an outline when it wanted full content, an instruction patch proposes tweaking the tool's description to clarify the <code>full: true</code> parameter. <strong>Never applied automatically from the daily sweep</strong> — Schneier constraint forces explicit <code>senkani learn apply &lt;id&gt;</code>. The rationale: instruction drift is a subtle prompt-injection surface; you want a human in the loop.</p>

    <h2>Workflow playbooks (H+2c)</h2>
    <p>Named multi-step recipes mined from ordered tool-call pairs within a 60-second window. Applied at <code>.senkani/playbooks/learned/&lt;title&gt;.md</code> — namespace-isolated from shipped skills so the two don't collide.</p>

    <h2>Enrichment via Gemma (H+2a)</h2>
    <p>Gemma 4 optionally enriches the rationale strings that accompany each proposal, via MLX. The enriched text lives in a dedicated <code>enrichedRationale</code> field — <strong>never enters FilterPipeline</strong>. This is deliberate: the enrichment improves the human review experience; it doesn't alter the runtime behavior.</p>

    <h2>Cadence</h2>
    <ul>
      <li><strong>Sprint review</strong> — <code>senkani learn review [--days 7]</code>. Go through staged proposals weekly.</li>
      <li><strong>Quarterly audit</strong> — <code>senkani learn audit [--idle D]</code>. Check applied artifacts for currency; retire stale ones.</li>
    </ul>

    <h2>KB ↔ learning bridge</h2>
    <p>High-mention entities from the <a href="__BASE__docs/concepts/knowledge-base.html">knowledge base</a> boost compound-learning confidence; applied context docs seed KB entity stubs; rolling back a KB entity cascades to invalidate derived context docs. The two systems are not isolated — they're sources for each other.</p>
''',
     [("senkani learn CLI", "__BASE__docs/reference/cli/senkani-learn.html"),
      ("Sprint Review pane", "__BASE__docs/reference/panes/sprint-review.html"),
      ("Compound-learning env vars", "__BASE__docs/reference/options/compound-learning.html"),
      ("Knowledge base", "__BASE__docs/concepts/knowledge-base.html")]),

    ("knowledge-base", "Knowledge base",
     "Project entities, decisions, and links live in <code>.senkani/knowledge/*.md</code> — markdown as source of truth. SQLite is a rebuilt index. <code>KBLayer1Coordinator</code> detects staleness and recovers from corruption.",
     '''
    <h2>Why markdown + rebuilt index</h2>
    <p>Markdown is diff-able, review-able, and human-editable. SQLite is fast. Senkani keeps the markdown as the source of truth and the SQLite index as a derivable artifact — if the index gets corrupt or stale, rebuild it from markdown. This is the inverse of the usual pattern ("DB is truth, exports are stale") and it prevents whole classes of data-loss bugs.</p>

    <h2>Entity → link → decision</h2>
    <ul>
      <li><strong>Entity</strong> — a named thing: a module, a class, a concept, a person, a library. <code>upsert_entity</code> creates or updates.</li>
      <li><strong>Link</strong> — a typed edge between two entities: <code>depends_on</code>, <code>replaced_by</code>, <code>authored_by</code>, etc.</li>
      <li><strong>Decision</strong> — a dated note attached to one or more entities explaining why something was built that way.</li>
    </ul>

    <h2>FTS5 search</h2>
    <p><code>search_knowledge</code> hits the FTS5-indexed body text. BM25 ranking. Queries are sanitized (FTS5 operator syntax stripped) before execution.</p>

    <h2>Enrichment + validation</h2>
    <p>High-mention entities (≥ 5× per session) get queued for Gemma enrichment via MLX. <code>EnrichmentValidator</code> flags <strong>information loss</strong> (enrichment shorter than original body), <strong>contradiction</strong> (enrichment contains negation of source claims), and <strong>excessive rewrite</strong> (low Jaccard similarity) before commit. The goal is strict drift detection — enrichment is additive, not editorial.</p>

    <h2>Rollback + timeline</h2>
    <p>Every enrichment commit creates an append-only history row. <code>senkani kb rollback &lt;id&gt;</code> reverts the latest enrichment; <code>senkani kb history &lt;id&gt;</code> lists prior versions; <code>senkani kb timeline</code> is a chronological view of all KB mutations across the project.</p>

    <h2>Layer 1 coordinator</h2>
    <p><code>KBLayer1Coordinator</code> detects SQLite index staleness (markdown newer than indexed) and corruption (unreadable pragmas). In either case it rebuilds from markdown without stopping the MCP server. Hand-edits to <code>.senkani/knowledge/*.md</code> are safe — the index follows.</p>

    <h2>Bridge to compound learning</h2>
    <p>See <a href="__BASE__docs/concepts/compound-learning.html">compound learning</a> for the KB ↔ learning bridge: entity-mention counts boost proposal confidence; applied context docs seed entity stubs; rolling back an entity invalidates derived context docs.</p>
''',
     [("senkani_knowledge MCP tool", "__BASE__docs/reference/mcp/senkani_knowledge.html"),
      ("senkani kb CLI", "__BASE__docs/reference/cli/senkani-kb.html"),
      ("Compound learning", "__BASE__docs/concepts/compound-learning.html"),
      ("Knowledge Base pane", "__BASE__docs/reference/panes/knowledge-base.html")]),

    ("security-posture", "Security posture",
     "Senkani is a trust boundary. v0.2.0 defaults are all secure: prompt-injection guard on, SSRF hardening on, secret redaction on, schema migrations versioned + crash-safe. Opt-outs are explicit env vars, not hidden flags.",
     '''
    <h2>What "trust boundary" means</h2>
    <p>The agent on one side; your filesystem, network, and secrets on the other. Everything that crosses the boundary is scanned, redacted, validated, or rejected. The boundary is not a feature; it's the product.</p>

    <h2>Prompt-injection guard</h2>
    <p><code>SENKANI_INJECTION_GUARD=on</code> by default. Scans every MCP tool response for instruction-override patterns ("ignore previous instructions", "you are now…"), tool-call injection (fake function-call syntax inside returned text), context-manipulation (zero-width chars, homoglyph substitutions), and exfiltration (base64-looking blobs that decode to URLs or credentials). Anti-evasion normalization: lowercase, zero-width-char strip, Cyrillic→Latin homoglyph fold, NFKC normalization. Single linear pass.</p>

    <h2>SSRF hardening</h2>
    <p><a href="__BASE__docs/reference/mcp/senkani_web.html"><code>senkani_web</code></a> resolves the target host via <code>getaddrinfo</code> before fetch and blocks any address in private/link-local/CGNAT/multicast ranges (including IPv4-mapped IPv6, octal/hex IPv4, IPv4-compatible IPv6). Redirects are re-validated via <code>WKNavigationDelegate.decidePolicyFor</code> — a 3xx Location header to <code>10.x</code>, <code>169.254.169.254</code>, or <code>::ffff:…</code> is cancelled. A <code>WKContentRuleList</code> blocks subresource requests (img/script/xhr) to the same ranges, so a hostile HTML page embedding <code>&lt;img src="http://169.254.169.254/…"&gt;</code> cannot reach cloud metadata through WebKit's auto-rendering. <code>file://</code> scheme is rejected entirely.</p>

    <h2>Secret redaction</h2>
    <p>13 regex families + entropy-based fallback. Short-circuits with <code>firstMatch</code> so no-match inputs don't pay the full regex cost (1 MB benign input: ~25 ms). Every tool output runs through before reaching the model. The counter <code>command_redactions</code> on <code>event_counters</code> increments on each redaction.</p>

    <h2>Schema migrations — versioned + crash-safe</h2>
    <p>Session DB uses <code>PRAGMA user_version</code> + a <code>schema_migrations</code> audit log. Cross-process coordination via <code>flock</code> sidecar. On failed migration, a kill-switch lockfile is written and subsequent boots refuse to run migrations until the operator inspects the DB. This trades convenience for safety deliberately.</p>

    <h2>Retention</h2>
    <p><code>RetentionScheduler</code> prunes <code>token_events</code> (90 d default), <code>sandboxed_results</code> (24 h default), <code>validation_results</code> (24 h default) on an hourly tick. Tune via <code>~/.senkani/config.json</code> → <code>"retention": {…}</code>.</p>

    <h2>Socket authentication — opt-in</h2>
    <p><code>SENKANI_SOCKET_AUTH=on</code> generates a 32-byte random token at <code>~/.senkani/.token</code> (mode 0600), rotated on every server start. Every connection to <code>mcp.sock</code>/<code>hook.sock</code>/<code>pane.sock</code> must send a length-prefixed handshake frame matching the token. Raises the bar from ambient same-UID socket access to must-read-token-file. <strong>Default off in v0.2.0 for backward compatibility; flipping to on next release.</strong></p>

    <h2>Observability</h2>
    <p>Every security-defense site increments an <code>event_counters</code> row: injection detections, SSRF blocks, socket handshake rejections, schema migrations, retention prunes, command redactions. Surfaced via <code>senkani stats --security</code> with Gelman-style <code>count/total (pct%)</code> rate annotation, or the <code>senkani_session action:"stats"</code> MCP action.</p>

    <h2>Data portability</h2>
    <p><a href="__BASE__docs/reference/cli/senkani-export.html"><code>senkani export</code></a> streams sessions + commands + token_events as JSONL via a read-only SQLite connection — doesn't block the live MCP server. <code>--redact</code> collapses user paths. GDPR-adjacent by design, not by regulation.</p>
''',
     [("senkani_web (SSRF guard)", "__BASE__docs/reference/mcp/senkani_web.html"),
      ("Security env vars", "__BASE__docs/reference/options/security.html"),
      ("Web env vars", "__BASE__docs/reference/options/web.html"),
      ("senkani doctor (verify posture)", "__BASE__docs/reference/cli/senkani-doctor.html")]),
]


# ============================================================
# GUIDE PAGES
# ============================================================
def render_guide(slug: str, title: str, lede: str, body_html: str, next_link: tuple = None):
    full_title = f"{title} — guide"
    desc = html.escape(lede)[:160]
    next_block = f'    <h2>Next</h2><p><a href="{next_link[1]}">{next_link[0]} →</a></p>' if next_link else ""
    body = f'''<main id="main" class="wiki-layout">
{wiki_nav_guides(slug)}
  <article class="wiki-main">
    <nav class="crumb" aria-label="Breadcrumb">
      <a href="__BASE__">Home</a> <span class="sep">›</span>
      <a href="__BASE__docs/guides/">Guides</a> <span class="sep">›</span>
      <span class="here">{title}</span>
    </nav>
    <span class="quadrant guide">Guide · How-to</span>
    <h1 class="page-title">{title}</h1>
    <p class="lede">{lede}</p>
{body_html}
{next_block}
  </article>
</main>
'''
    return HEAD.format(title=full_title, desc=desc) + body + FOOT


GUIDES = [
    ("install", "Install senkani",
     "Clone the repo, build with Swift Package Manager, register hooks, launch the workspace. Three minutes end-to-end on Apple Silicon.",
     '''
    <h2>Prerequisites</h2>
    <ul>
      <li>macOS 14+</li>
      <li>Swift 6.0+ (ships with Xcode 15+)</li>
      <li>Xcode Command Line Tools (<code>xcode-select --install</code> if you don't already have them)</li>
    </ul>

    <div class="step">
      <div class="step-num">Step 1 · Clone + build</div>
      <pre class="code">git clone https://github.com/ckluis/senkani
cd senkani
swift build -c release</pre>
      <p>First build takes ~4 minutes. Subsequent builds are incremental.</p>
    </div>

    <div class="step">
      <div class="step-num">Step 2 · Register</div>
      <pre class="code">.build/release/senkani init</pre>
      <p>Writes the hook binary to <code>~/.senkani/bin/senkani-hook</code>, appends an MCP server entry to <code>~/.claude/settings.json</code>, registers PreToolUse + PostToolUse hooks. Idempotent — safe to re-run.</p>
    </div>

    <div class="step">
      <div class="step-num">Step 3 · Verify</div>
      <pre class="code">.build/release/senkani doctor</pre>
      <p>Should report all green: MCP server registered, hooks registered, binary path resolved, grammar versions within window. If anything is amber or red, run <code>senkani doctor --fix</code>.</p>
    </div>

    <div class="step">
      <div class="step-num">Step 4 · Launch the workspace</div>
      <pre class="code">.build/release/senkani</pre>
      <p>SwiftUI workspace opens. ⌘K opens the pane palette; start with an Analytics pane to watch your first session compress.</p>
    </div>

    <h2>If you don't use Claude Code</h2>
    <p>If you use Cursor, Copilot, or another agent that doesn't speak MCP, skip the server registration and install hooks only:</p>
    <pre class="code">.build/release/senkani init --hooks-only</pre>
    <p>You get the filter pipeline and smart denials, but not the 19 MCP tools.</p>
''',
     ("Wire up Claude Code", "__BASE__docs/guides/claude-code.html")),

    ("claude-code", "Wire up Claude Code",
     "Senkani's MCP server registers globally with Claude Code via <code>senkani init</code>. No config files to maintain.",
     '''
    <h2>What <code>senkani init</code> modifies</h2>
    <ol>
      <li>Writes <code>~/.senkani/bin/senkani-hook</code> (the compiled Mach-O hook binary, zero deps, &lt; 5 ms startup).</li>
      <li>Appends an entry to <code>~/.claude/settings.json</code> under <code>mcpServers</code>:
        <pre class="code"><span class="k">"mcpServers"</span>: {{
  <span class="k">"senkani"</span>: {{
    <span class="k">"command"</span>: <span class="v">"/Users/you/.senkani/bin/senkani"</span>,
    <span class="k">"args"</span>: []
  }}
}}</pre>
      </li>
      <li>Appends PreToolUse + PostToolUse hook entries with matcher <code>Read|Bash|Grep|Write|Edit</code>.</li>
      <li>Does not touch any other settings. Does not require sudo. Does not modify shell profiles.</li>
    </ol>

    <h2>Verify</h2>
    <pre class="code">senkani doctor</pre>
    <p>Should show "MCP server registered" and "Hooks registered." If not, run <code>senkani doctor --fix</code>.</p>

    <h2>First session</h2>
    <ol>
      <li>Launch the senkani app (<code>senkani</code> with no args, or open SenkaniApp).</li>
      <li>Open a Terminal pane (⌘K → "Terminal").</li>
      <li>Run <code>claude</code> inside the pane. The MCP server starts; the agent sees all 19 senkani tools on top of Claude Code's built-ins.</li>
      <li>Open an Analytics pane side-by-side (⌘K → "Analytics"). Watch token savings accumulate as the session runs.</li>
    </ol>

    <div class="callout callout-info">
      <span class="callout-icon">⚐</span>
      <div>MCP activation is gated on <code>SENKANI_PANE_ID</code>, which the app injects <em>only</em> into managed panes. Run <code>claude</code> in a non-Senkani terminal and it won't see the senkani tools — by design.</div>
    </div>
''',
     ("Your first session", "__BASE__docs/guides/first-session.html")),

    ("cursor-copilot", "Wire up Cursor / Copilot",
     "Cursor and Copilot don't speak MCP. Install the hooks-only variant so you still get the filter pipeline + smart denials on their built-in Read/Bash.",
     '''
    <h2>Install hooks only</h2>
    <pre class="code">senkani init --hooks-only</pre>
    <p>This skips the MCP server registration in <code>~/.claude/settings.json</code> but still:</p>
    <ul>
      <li>Writes <code>~/.senkani/bin/senkani-hook</code>.</li>
      <li>Registers Senkani's PreToolUse + PostToolUse hooks for Cursor/Copilot's Read/Bash/Grep equivalents where supported.</li>
      <li>Runs the filter pipeline + secret redaction on intercepted tool output.</li>
    </ul>

    <h2>What you get</h2>
    <ul>
      <li>✓ Compression via the filter pipeline (F toggle).</li>
      <li>✓ Secret redaction (S toggle).</li>
      <li>✓ Smart denials — re-read suppression, command replay, trivial routing.</li>
      <li>✗ <strong>No</strong> <code>senkani_*</code> MCP tools. Your agent can't call them.</li>
      <li>✗ <strong>No</strong> symbol search / fetch. Text-grep is the fallback.</li>
      <li>✗ <strong>No</strong> terse mode (T toggle relies on MCP system-prompt injection).</li>
    </ul>

    <h2>Tradeoff</h2>
    <p>You keep ~40% of the savings. Not as good as Claude Code + full MCP; better than nothing.</p>

    <div class="callout callout-info">
      <span class="callout-icon">⚐</span>
      <div>If your agent later adds MCP support, re-run <code>senkani init</code> (without <code>--hooks-only</code>) to add the server entry. Idempotent; no harm done.</div>
    </div>
''',
     ("Your first session", "__BASE__docs/guides/first-session.html")),

    ("first-session", "Your first session",
     "Launch the workspace, run an agent, read the numbers. What you'll see and how to interpret it.",
     '''
    <div class="step">
      <div class="step-num">Step 1</div>
      <h3>Open the workspace</h3>
      <pre class="code">senkani</pre>
      <p>Or open SenkaniApp from /Applications if you dragged it there. A single empty canvas appears.</p>
    </div>

    <div class="step">
      <div class="step-num">Step 2</div>
      <h3>Open three panes</h3>
      <p>⌘K → type "Terminal" → Enter. ⌘K → "Analytics". ⌘K → "Agent Timeline". Three panes side by side.</p>
    </div>

    <div class="step">
      <div class="step-num">Step 3</div>
      <h3>Start the agent</h3>
      <p>In the Terminal pane:</p>
      <pre class="code">claude</pre>
      <p>Claude Code starts; MCP handshake happens automatically (you can confirm via the "MCP connected" indicator in the status bar).</p>
    </div>

    <div class="step">
      <div class="step-num">Step 4</div>
      <h3>Ask for something real</h3>
      <p>Ask the agent to do something that involves reading your project:</p>
      <pre class="code">&gt; Find the function that handles order pagination.</pre>
      <p>Watch the Agent Timeline pane fill with tool calls (<code>senkani_search</code> → <code>senkani_fetch</code> → possibly <code>senkani_read</code>). Each line shows the tool, target, and compression ratio.</p>
    </div>

    <div class="step">
      <div class="step-num">Step 5</div>
      <h3>Read the Analytics pane</h3>
      <ul>
        <li><strong>Tokens saved</strong> — bytes that would have been sent to the LLM but weren't.</li>
        <li><strong>Cost saved</strong> — tokens × model rate (from the pane's model preset).</li>
        <li><strong>Compliance rate</strong> — fraction of tool calls that went through Senkani vs the agent's built-ins. High is good.</li>
        <li><strong>Per-feature breakdown</strong> — F / C / S / I / T contributions.</li>
      </ul>
    </div>

    <h2>What "good" looks like</h2>
    <ul>
      <li>Compliance &gt; 80% — the agent is using <code>senkani_*</code> tools.</li>
      <li>Live multiplier &gt; 3× — you're saving meaningful tokens.</li>
      <li>Agent Timeline is mostly <code>senkani_*</code> entries, not raw Read/Bash/Grep.</li>
    </ul>

    <h2>If compliance is low</h2>
    <p>The agent is bypassing senkani tools. Run <code>senkani doctor</code> to check registration; make sure the MCP server entry in <code>~/.claude/settings.json</code> is present; make sure you launched <code>claude</code> <em>inside</em> a Senkani-managed Terminal pane (the one the app opened, not a random shell).</p>
''',
     ("Budget setup", "__BASE__docs/guides/budget-setup.html")),

    ("budget-setup", "Budget setup",
     "Daily and weekly spend caps, dual-layer enforcement, and what happens when you hit a cap.",
     '''
    <h2>Set the caps</h2>
    <pre class="code"><span class="c"># in your shell profile:</span>
<span class="k">export</span> SENKANI_BUDGET_DAILY=5.00
<span class="k">export</span> SENKANI_BUDGET_WEEKLY=25.00</pre>
    <p>Or in <code>~/.senkani/config.json</code>:</p>
    <pre class="code">{{
  <span class="k">"budget"</span>: {{
    <span class="k">"daily_usd"</span>: <span class="e">5.00</span>,
    <span class="k">"weekly_usd"</span>: <span class="e">25.00</span>
  }}
}}</pre>

    <h2>How enforcement fires</h2>
    <p>Before every tool call, the PreToolUse hook queries <code>costForToday()</code> and <code>costForWeek()</code> from the session DB. If either exceeds the cap, the hook denies the call with a structured message the agent sees.</p>

    <h2>Dual-layer</h2>
    <p>Enforcement runs at both the hook AND the MCP server — the agent can't bypass by switching to built-in tools. See <a href="__BASE__docs/concepts/three-layer-stack.html">three-layer stack</a>.</p>

    <h2>Reset</h2>
    <p>Daily resets at midnight local. Weekly resets Monday 00:00 local. There's no manual reset — the cap is a ceiling on lifetime spend, not a bank.</p>

    <h2>Monitor</h2>
    <pre class="code">senkani stats</pre>
    <p>Shows lifetime totals plus current-day / current-week spend against each cap.</p>

    <h2>What happens when you hit a cap</h2>
    <p>The agent gets a denial message like:</p>
    <pre class="code"><span class="er">Budget exceeded: daily cap $5.00 reached at $5.04.
Tool call denied. To continue today, raise SENKANI_BUDGET_DAILY or wait until midnight.</span></pre>
    <p>The agent typically stops cleanly and tells you. It's not a silent failure.</p>
''',
     ("Reviewing learned proposals", "__BASE__docs/guides/compound-learning.html")),

    ("compound-learning", "Reviewing learned proposals",
     "How to use <code>senkani learn review</code> and the Sprint Review pane to accept, reject, or defer staged proposals.",
     '''
    <h2>Weekly (sprint) cadence</h2>
    <pre class="code">senkani learn review --days 7</pre>
    <p>Lists everything that moved from <code>.recurring</code> to <code>.staged</code> in the last week.</p>

    <h2>In the Sprint Review pane</h2>
    <p>Open ⌘K → "Sprint Review". Each proposal shows:</p>
    <ul>
      <li><strong>Type</strong> — filter rule / context doc / instruction patch / workflow playbook.</li>
      <li><strong>Evidence</strong> — sessions + token cost that produced the recurrence.</li>
      <li><strong>Confidence</strong> — Laplace-smoothed, 0.0–1.0.</li>
      <li><strong>Rationale</strong> — why the system thinks this pattern is worth applying (optionally enriched via Gemma).</li>
      <li><strong>Actions</strong> — Accept (moves to <code>.applied</code>), Reject (discards), Defer (keeps staged).</li>
    </ul>

    <h2>Instruction patches</h2>
    <p>These don't auto-apply from the daily sweep — you must explicitly accept each one in review. This is a deliberate Schneier gate against subtle prompt-injection drift.</p>

    <h2>Quarterly audit</h2>
    <pre class="code">senkani learn audit --idle 90</pre>
    <p>Lists applied artifacts that haven't fired in N days. Retire stale entries so the live artifact pool stays fresh.</p>
''',
     ("Knowledge-base workflow", "__BASE__docs/guides/kb-workflow.html")),

    ("kb-workflow", "Knowledge-base workflow",
     "Day-to-day with <code>senkani kb</code>: seed entities, hand-edit markdown, run the audit. The markdown at <code>.senkani/knowledge/</code> is the source of truth.",
     '''
    <h2>Seed an entity</h2>
    <pre class="code">senkani kb add "OrderRepository"</pre>
    <p>Creates <code>.senkani/knowledge/order_repository.md</code>. Edit it with any text editor; the SQLite index picks up the change on the next query.</p>

    <h2>Query</h2>
    <pre class="code">senkani kb search "pagination"
senkani kb get order_repository
senkani kb list --type class --sort freshness</pre>

    <h2>Enrich</h2>
    <pre class="code">senkani learn enrich</pre>
    <p>Runs Gemma enrichment on high-mention entities (≥ 5× per session). <code>EnrichmentValidator</code> flags information loss / contradiction / excessive rewrite before commit.</p>

    <h2>Rollback</h2>
    <pre class="code">senkani kb rollback order_repository</pre>
    <p>Reverts the latest enrichment. History preserved.</p>

    <h2>Timeline</h2>
    <pre class="code">senkani kb timeline --days 30</pre>
    <p>Chronological view of all KB mutations — additions, enrichments, rollbacks.</p>
''',
     ("Uninstall", "__BASE__docs/guides/uninstall.html")),

    ("uninstall", "Clean uninstall",
     "<code>senkani uninstall</code> removes everything it registered. <code>senkani wipe</code> additionally removes the session DB.",
     '''
    <h2>Dry-run first</h2>
    <pre class="code">senkani uninstall</pre>
    <p>Without <code>--yes</code>, prints the deletion list without acting. Gives you a chance to confirm.</p>

    <h2>Commit</h2>
    <pre class="code">senkani uninstall --yes --keep-data</pre>
    <p>Removes:</p>
    <ul>
      <li>MCP server entry from <code>~/.claude/settings.json</code>.</li>
      <li>PreToolUse + PostToolUse hook entries from <code>~/.claude/settings.json</code>.</li>
      <li>Project-level hooks in every <code>.claude/</code> Senkani touched.</li>
      <li><code>~/.senkani/bin/senkani-hook</code>.</li>
      <li><code>~/.senkani/</code> runtime dir.</li>
      <li>senkani launchd plists (if any <code>senkani schedule</code> jobs exist).</li>
      <li>Per-project <code>.senkani/</code> dirs.</li>
    </ul>
    <p><code>--keep-data</code> preserves the session database at <code>~/Library/Application Support/Senkani/</code>. Drop the flag if you want everything gone.</p>

    <h2>Full wipe</h2>
    <pre class="code">senkani wipe --yes</pre>
    <p>Deletes the session DB + socket-auth token. Doesn't uninstall. Use this when you want to reset your stats.</p>

    <div class="callout callout-warn">
      <span class="callout-icon">⚠</span>
      <div><strong>Uninstall is idempotent.</strong> Running it twice is safe — the second run finds nothing to remove. But there's no undo; once wiped, session history is gone. Export first if you want a record: <code>senkani export --output ~/senkani-archive.jsonl --redact</code>.</div>
    </div>
''',
     ("Troubleshooting", "__BASE__docs/guides/troubleshooting.html")),

    ("troubleshooting", "Troubleshooting",
     "Common fixes: hook not registering, MCP not activating, grammar staleness, index rebuild.",
     '''
    <h2>Start here</h2>
    <pre class="code">senkani doctor --fix</pre>
    <p>Checks every expected file, every registration entry, every grammar version. <code>--fix</code> attempts repair for each amber/red finding.</p>

    <h2>Hook not registering</h2>
    <p>Symptom: tool calls go through but no compression happens, or the Agent Timeline pane stays empty.</p>
    <ol>
      <li>Confirm <code>~/.claude/settings.json</code> has PreToolUse + PostToolUse entries pointing at <code>~/.senkani/bin/senkani-hook</code>.</li>
      <li>Confirm the hook binary exists and is executable: <code>ls -l ~/.senkani/bin/senkani-hook</code>.</li>
      <li>Re-run <code>senkani init</code> — it's idempotent.</li>
    </ol>

    <h2>MCP server not activating</h2>
    <p>Symptom: agent doesn't see any <code>senkani_*</code> tools.</p>
    <ol>
      <li>Confirm <code>SENKANI_PANE_ID</code> is set in the shell: <code>echo $SENKANI_PANE_ID</code>. If empty, you're in a non-Senkani terminal — launch <code>claude</code> inside a Terminal pane the app opened.</li>
      <li>Confirm the MCP server entry in <code>~/.claude/settings.json</code>.</li>
      <li>Run <code>senkani_version</code> (tool) or <code>senkani doctor</code>.</li>
    </ol>

    <h2>Grammar staleness warning</h2>
    <p>Symptom: <code>senkani doctor</code> reports SKIP with "grammar X is N days stale."</p>
    <p>This is a non-blocking advisory — it never fails CI. Stale = upstream has a newer version AND vendored &gt; 30 days. Within the window, outdated grammars roll up as PASS. Over the window, SKIP (not FAIL). If you want to update, the repo's <code>swift package update</code> pulls the latest grammars.</p>

    <h2>Index out of sync</h2>
    <p>Symptom: <code>senkani search</code> returns stale results or can't find a symbol you just added.</p>
    <pre class="code">senkani index --force</pre>
    <p>Forces a full rebuild. Normally the index updates incrementally via FSEvents — but after switching branches or restoring from a backup, the cursor can get out of sync.</p>

    <h2>Budget cap triggered unexpectedly</h2>
    <p>Symptom: tool calls denied with "budget exceeded."</p>
    <pre class="code">senkani stats</pre>
    <p>Shows spend against the caps. If you want to raise them: edit <code>~/.senkani/config.json</code> or set <code>SENKANI_BUDGET_DAILY</code>/<code>SENKANI_BUDGET_WEEKLY</code>.</p>

    <h2>Still stuck?</h2>
    <p>Open an issue at <a href="https://github.com/ckluis/senkani/issues">github.com/ckluis/senkani/issues</a>. Include the output of <code>senkani doctor</code> (with any paths redacted) and the relevant slice of <code>senkani stats --security</code>.</p>
''',
     None),
]


def main():
    print(f"Generating senkani site pages under {ROOT}")
    # MCP tool pages
    print(f"MCP tools: {len(MCP_TOOLS)}")
    for t in MCP_TOOLS:
        write(ROOT / "docs" / "reference" / "mcp" / f'{t["slug"]}.html', render_mcp_tool(t))
    # CLI command pages
    print(f"CLI commands: {len(CLI_COMMANDS)}")
    for c in CLI_COMMANDS:
        write(ROOT / "docs" / "reference" / "cli" / f'{c["slug"]}.html', render_cli(c))
    # Pane pages
    print(f"Panes: {len(PANES)}")
    for p in PANES:
        write(ROOT / "docs" / "reference" / "panes" / f'{p[0]}.html', render_pane(p))
    # Options pages
    print(f"Options: {len(ALL_OPTS)}")
    for slug, title, lede, body in ALL_OPTS:
        write(ROOT / "docs" / "reference" / "options" / f'{slug}.html', render_opt(slug, title, lede, body))
    # Concept pages
    print(f"Concepts: {len(CONCEPTS)}")
    for slug, title, lede, body, sa in CONCEPTS:
        write(ROOT / "docs" / "concepts" / f'{slug}.html', render_concept(slug, title, lede, body, sa))
    # Guide pages
    print(f"Guides: {len(GUIDES)}")
    for slug, title, lede, body, nxt in GUIDES:
        write(ROOT / "docs" / "guides" / f'{slug}.html', render_guide(slug, title, lede, body, nxt))
    # Hub pages
    print("Hubs")
    write(ROOT / "docs" / "reference" / "index.html", render_hub_reference())
    write(ROOT / "docs" / "reference" / "mcp" / "index.html", render_hub_mcp())
    write(ROOT / "docs" / "reference" / "cli" / "index.html", render_hub_cli())
    write(ROOT / "docs" / "reference" / "panes" / "index.html", render_hub_panes())
    write(ROOT / "docs" / "reference" / "options" / "index.html", render_hub_options())
    write(ROOT / "docs" / "concepts" / "index.html", render_hub_concepts())
    write(ROOT / "docs" / "guides" / "index.html", render_hub_guides())
    write(ROOT / "docs" / "status.html", render_hub_status())
    write(ROOT / "docs" / "about.html", render_about())
    write(ROOT / "docs" / "changelog.html", render_changelog())
    write(ROOT / "docs" / "what-is-senkani.html", render_what_is_senkani())
    # Docs root hub — an index.html at /docs/
    write(ROOT / "docs" / "index.html", render_docs_root())
    print("Done.")


if __name__ == "__main__":
    main()
