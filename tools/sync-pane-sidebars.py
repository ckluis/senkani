#!/usr/bin/env python3
"""Regenerate every pane detail-page sidebar from the canonical pane list.

Single source of truth: ``docs/reference/panes.html`` (the panes index).
Its ``<a class="card" href="..panes/<slug>.html"><h4>TITLE</h4>`` anchors define
the ordered, canonical set of pane types. This script parses that list and
rewrites the ``<aside class="wiki-nav" ...>...</aside>`` navigation block in
every ``docs/reference/panes/*.html`` detail page so all 21 detail-page
sidebars are byte-for-byte identical, modulo the single ``class="active"``
marker on the link for the page being rendered.

The canonical sidebar has THREE groups:
  1. "Reference"          — 5 static links (verbatim).
  2. "Pane types (N)"     — one link per canonical pane, in card order, N = card count.
  3. "Panels & overlays"  — single Settings link.

Idempotent: only the ``<aside class="wiki-nav">...</aside>`` block is touched,
located by exact markers and swapped in place, so everything else (breadcrumb,
``<article class="wiki-main">``, head, footer) is preserved byte-for-byte and a
second run produces no diff.

Drift is enforced in CI by ``Tests/SenkaniTests/PaneDetailSidebarDriftTests``,
which fails the build if any detail page's pane-types set or count diverges
from ``panes.html``.
"""

from __future__ import annotations

import glob
import os
import re
import sys

# Repo root = parent of this script's directory (tools/).
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PANES_INDEX = os.path.join(REPO_ROOT, "docs", "reference", "panes.html")
DETAIL_GLOB = os.path.join(REPO_ROOT, "docs", "reference", "panes", "*.html")

ASIDE_OPEN = '  <aside class="wiki-nav" aria-label="Pane navigation">'
ASIDE_CLOSE = "  </aside>"

# Card anchor: <a class="card" href="..panes/<slug>.html"><h4>TITLE</h4>
CARD_RE = re.compile(
    r'<a class="card" href="[^"]*panes/([a-z0-9-]+)\.html"><h4>([^<]+)</h4>'
)


def parse_canonical_panes(index_html: str) -> list[tuple[str, str]]:
    """Return ordered (slug, title) pairs from the panes.html card anchors."""
    return [(m.group(1), m.group(2)) for m in CARD_RE.finditer(index_html)]


def build_aside(panes: list[tuple[str, str]], active_slug: str | None) -> str:
    """Build the canonical <aside ...>...</aside> block.

    ``active_slug`` is the slug whose link gets ``class="active"`` — for a pane
    page that's the matching pane link; for settings.html it's "settings"
    (the Settings link in the Panels & overlays group).
    """

    def link(slug: str, title: str) -> str:
        active = ' class="active"' if slug == active_slug else ""
        href = f"../../../docs/reference/panes/{slug}.html"
        return f'        <li><a href="{href}"{active}>{title}</a></li>'

    lines: list[str] = [ASIDE_OPEN]

    # Group 1 — Reference (static).
    lines += [
        '    <div class="wiki-nav-group">',
        "      <h4>Reference</h4>",
        "      <ul>",
        '        <li><a href="../../../docs/reference.html">All reference</a></li>',
        '        <li><a href="../../../docs/reference/mcp.html">MCP tools</a></li>',
        '        <li><a href="../../../docs/reference/cli.html">CLI commands</a></li>',
        '        <li><a href="../../../docs/reference/options.html">Options &amp; env</a></li>',
        '        <li><a href="../../../docs/reference/panes.html">Panes index</a></li>',
        "      </ul>",
        "    </div>",
    ]

    # Group 2 — Pane types (N).
    lines += [
        '    <div class="wiki-nav-group">',
        f"      <h4>Pane types ({len(panes)})</h4>",
        "      <ul>",
    ]
    lines += [link(slug, title) for slug, title in panes]
    lines += [
        "      </ul>",
        "    </div>",
    ]

    # Group 3 — Panels & overlays (Settings).
    lines += [
        '    <div class="wiki-nav-group">',
        "      <h4>Panels &amp; overlays</h4>",
        "      <ul>",
        link("settings", "Settings"),
        "      </ul>",
        "    </div>",
    ]

    lines.append(ASIDE_CLOSE)
    return "\n".join(lines)


def replace_aside(html: str, new_aside: str, rel_path: str) -> str:
    """Swap the existing <aside class="wiki-nav">...</aside> for new_aside.

    Located by exact line-start markers so the breadcrumb / <article> below
    and the <nav class="topnav"> above are never touched.
    """
    start = html.find(ASIDE_OPEN)
    if start == -1:
        raise ValueError(f"{rel_path}: could not find aside open marker")
    close = html.find(ASIDE_CLOSE, start)
    if close == -1:
        raise ValueError(f"{rel_path}: could not find aside close marker")
    end = close + len(ASIDE_CLOSE)
    return html[:start] + new_aside + html[end:]


def main() -> int:
    with open(PANES_INDEX, encoding="utf-8") as f:
        index_html = f.read()

    panes = parse_canonical_panes(index_html)
    if not panes:
        print("ERROR: parsed 0 cards from panes.html", file=sys.stderr)
        return 1

    pane_slugs = {slug for slug, _ in panes}
    print(f"Canonical panes from panes.html ({len(panes)}):")
    for slug, title in panes:
        print(f"  {slug} -> {title}")
    print()

    changed = 0
    unchanged = 0
    for path in sorted(glob.glob(DETAIL_GLOB)):
        slug = os.path.splitext(os.path.basename(path))[0]
        # settings.html is not a card slug; its active link is the Settings link.
        active_slug = slug if (slug in pane_slugs or slug == "settings") else None
        rel = os.path.relpath(path, REPO_ROOT)

        with open(path, encoding="utf-8") as f:
            original = f.read()

        new_aside = build_aside(panes, active_slug)
        updated = replace_aside(original, new_aside, rel)

        if updated != original:
            with open(path, "w", encoding="utf-8") as f:
                f.write(updated)
            changed += 1
            print(f"  changed   {rel}")
        else:
            unchanged += 1
            print(f"  unchanged {rel}")

    print()
    print(f"Done: {changed} changed, {unchanged} unchanged "
          f"({changed + unchanged} detail pages).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
