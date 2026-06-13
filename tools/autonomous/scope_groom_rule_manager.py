#!/usr/bin/env python3
"""
scope_groom_rule_manager — write and revoke the narrow, single-use Bash
permission rules that scope-groom mode adds to `.claude/settings.local.json`
when an operator authorizes the autonomous build round to run an
external-write action.

Originating item:
`process-gap-harness-vs-item-authorization-mismatch`.
Blocker (resolved 2026-06-12):
`process-gap-build-round-categorical-action-vetting-2026-05-07`.

Two-layer authorization model (see `spec/autonomous/PROCESS.md`):

  1. Project layer (per-item, durable) — scope-groom records the
     operator's decision in the per-item file's `## Scope decisions`.
  2. Harness layer (policy-driven, persistent) — Claude Code's
     allowlist lives in `.claude/settings.local.json`.

High-severity external writes (filing GitHub issues on third-party
repos, posting to Slack, sending email, billing-API writes) need BOTH
layers aligned. Without the harness rule, the build round aborts even
with per-item scope-groom authorization. This helper closes the gap:
scope-groom writes the harness rule narrowly, and close-mode revokes it.

The rule is SINGLE-USE (Schneier lens — auto-revoke is the
security-critical control):

  - Written during the scope-groom round, scoped to the exact command
    pattern the build round will run (e.g. `gh issue create --repo
    swiftlang/swift-testing *`).
  - Tagged with a `SCOPE_GROOM_MARKER <item-id>` comment line placed
    IMMEDIATELY ABOVE the `"Bash(...)"` allow entry, so close-mode can
    find it without parsing the rule shape.
  - Removed by close-mode when the item lands (whether via `done`,
    `skipped`, or `manual` reversion — the authorization was scoped to
    the ONE build attempt, not to the operator's ongoing intent).

== Comment-tolerance design choice (the load-bearing decision) ==

`.claude/settings.local.json` is read by Claude Code as JSON, but once
scope-groom has written a managed rule the file carries
`// scope-groom-managed: <item-id>` comment lines that a naive
`json.loads` would reject. We resolve this with a STRIP-THEN-PARSE
validity check plus RAW-LINE mutation:

  - VALIDITY / READ: `_strip_managed_marker_lines()` removes ONLY lines
    whose stripped content begins with the marker token, then
    `json.loads` the remainder. A file with managed markers therefore
    validates as JSON; a genuinely-corrupt file (unbalanced braces,
    bad commas, a non-marker `//` comment) still fails — fail-safe
    (acceptance bullet 6). We never try to "repair" corrupt JSON.

  - WRITE: we DO round-trip the structural content through json so the
    allow-list stays well-formed and deterministic, but we re-emit the
    managed marker comment as a sibling line above each managed Bash
    entry. Re-emission is driven by the parsed allow entries plus a
    marker-map we recover from the raw text, so existing managed markers
    survive and writing is idempotent (Kleppmann lens — re-run yields a
    byte-identical file).

  - REVOKE: we operate on RAW LINES (never a json round-trip that would
    drop the `//` comments wholesale): regex the marker line for the
    target item-id, then remove that marker line AND the nearest
    `"Bash(...)"` allow entry structurally adjacent to it (the entry on
    the line BELOW the marker, falling back to the nearest Bash entry
    after the marker within the same allow array). Multiple managed
    rules for the same item-id are all removed.

Stdlib-only (no PyYAML, no external JSON libs). The marker constant is
imported from `check_categorical_block` — single source of truth.

Usage (CLI, for operator/skill wiring):
    # write a managed rule
    python3 tools/autonomous/scope_groom_rule_manager.py write \\
        --settings .claude/settings.local.json \\
        --item-id my-item-id \\
        --command 'gh issue create --repo swiftlang/swift-testing *'

    # revoke all managed rules for an item-id
    python3 tools/autonomous/scope_groom_rule_manager.py revoke \\
        --settings .claude/settings.local.json \\
        --item-id my-item-id

Exit codes:
    0 — success (write/revoke applied, or no-op when nothing to do)
    2 — usage / IO / malformed-settings error (fail-safe: no write made)
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

THIS_DIR = Path(__file__).resolve().parent
if str(THIS_DIR) not in sys.path:
    sys.path.insert(0, str(THIS_DIR))
from check_categorical_block import SCOPE_GROOM_MARKER  # noqa: E402

# Interview-answer choices that mean "the operator will run the action
# themselves" — NO harness rule should be written for these. Anything
# else that explicitly authorizes the loop (e.g. the
# "Autonomous build round (with explicit auth)" choice) IS an
# autonomous authorization.
_NON_AUTONOMOUS_TOKENS = ("manual", "cowork", "operator", "myself",
                          "by hand", "skip", "drop")
_AUTONOMOUS_TOKENS = ("autonomous", "with explicit auth", "loop run",
                      "loop will run", "build round")


class SettingsError(Exception):
    """Raised when settings.local.json is genuinely corrupt (not merely
    carrying managed `//` markers). Callers fail-safe: no write."""


def _marker_line_for(item_id: str) -> re.Pattern[str]:
    """Regex matching a managed-marker comment line for `item_id`.

    The marker token is fixed (imported); the item-id is matched
    verbatim (escaped) so a substring item-id can't false-positive a
    longer one."""
    return re.compile(
        r"^\s*" + re.escape(SCOPE_GROOM_MARKER) + r"\s*"
        + re.escape(item_id) + r"\s*$"
    )


_ANY_MARKER_LINE = re.compile(r"^\s*" + re.escape(SCOPE_GROOM_MARKER))
_BASH_ENTRY_LINE = re.compile(r'^\s*"Bash\((?P<inner>.*)\)"\s*,?\s*$')


def is_autonomous_authorization(answer: str) -> bool:
    """No-op decision helper (acceptance bullet 5): distinguish
    "operator authorized the loop to run the action" from "operator
    will run it themselves."

    Returns True ONLY when the answer affirmatively authorizes the
    autonomous loop. A blank/None answer, or any answer naming a
    manual/cowork/operator-run path, returns False (fail-closed — a
    rule is a privilege grant, so the ambiguous default is "no rule").
    """
    if not answer:
        return False
    text = answer.strip().lower()
    if not text:
        return False
    # Manual/cowork/operator path wins if named — fail closed.
    if any(tok in text for tok in _NON_AUTONOMOUS_TOKENS):
        return False
    return any(tok in text for tok in _AUTONOMOUS_TOKENS)


def _strip_managed_marker_lines(text: str) -> str:
    """Remove ONLY the managed-marker comment lines, leaving the rest
    of the file byte-for-byte. The remainder must be valid JSON; if it
    isn't, the file is genuinely corrupt."""
    kept = [ln for ln in text.splitlines()
            if not _ANY_MARKER_LINE.match(ln)]
    return "\n".join(kept)


def load_settings(path: Path) -> dict:
    """Comment-tolerant load: strip managed markers, then json.loads.

    Missing file → a fresh `{}` skeleton (a write can seed it).
    Genuinely-corrupt JSON → SettingsError (fail-safe; no write)."""
    if not path.exists():
        return {}
    raw = path.read_text(encoding="utf-8")
    if raw.strip() == "":
        return {}
    stripped = _strip_managed_marker_lines(raw)
    try:
        data = json.loads(stripped)
    except json.JSONDecodeError as exc:
        raise SettingsError(
            f"settings file is not valid JSON after stripping managed "
            f"markers: {path} ({exc})"
        ) from exc
    if not isinstance(data, dict):
        raise SettingsError(
            f"settings root is not a JSON object: {path}"
        )
    return data


def _managed_item_ids(text: str) -> set[str]:
    """Item-ids that already have a managed marker in the raw text."""
    ids: set[str] = set()
    for ln in text.splitlines():
        if _ANY_MARKER_LINE.match(ln):
            tail = ln.strip()[len(SCOPE_GROOM_MARKER):].strip()
            if tail:
                ids.add(tail)
    return ids


def bash_rule_for(command: str) -> str:
    """The allow-entry string for a command pattern: `Bash(<command>)`.

    The command is used verbatim (the caller scopes it narrowly — e.g.
    `gh issue create --repo swiftlang/swift-testing *`). We do not add
    or strip a trailing wildcard; narrowing is the caller's contract."""
    return f"Bash({command})"


def has_managed_rule(text: str, item_id: str, command: str) -> bool:
    """True if a managed marker for `item_id` already sits immediately
    above the `"Bash(<command>)"` entry in the raw text — the
    idempotency probe."""
    lines = text.splitlines()
    marker_re = _marker_line_for(item_id)
    want_entry = bash_rule_for(command)
    for i, ln in enumerate(lines):
        if marker_re.match(ln):
            for j in range(i + 1, len(lines)):
                m = _BASH_ENTRY_LINE.match(lines[j])
                if m is None:
                    if _ANY_MARKER_LINE.match(lines[j]):
                        break
                    continue
                inner = m.group("inner")
                if inner == command or f"Bash({inner})" == want_entry:
                    return True
                break
    return False


def write_rule(path: Path, item_id: str, command: str) -> bool:
    """Write a narrow managed Bash rule into `path` (settings-shaped).

    Idempotent: if a managed marker for `item_id` already guards the
    same `Bash(<command>)` entry, this is a no-op and the file is left
    byte-identical. Returns True if the file was changed, False on
    no-op.

    The written form, inside the `permissions.allow` array, is two
    adjacent lines:

        SCOPE_GROOM_MARKER <item-id>
        "Bash(<command>)",

    The marker is a JSON-illegal `//` line by design; `load_settings`
    strips it before parsing. We mutate raw lines (not a json round-
    trip) so existing managed markers for OTHER items survive verbatim.

    Raises SettingsError if the file is genuinely corrupt (caller
    fail-safes)."""
    # Validate first — fail-safe on corrupt JSON, never write into it.
    data = load_settings(path)

    raw = path.read_text(encoding="utf-8") if path.exists() else ""

    if raw.strip() and has_managed_rule(raw, item_id, command):
        return False  # idempotent no-op

    perms = data.get("permissions")
    if not isinstance(perms, dict):
        perms = {}
        data["permissions"] = perms
    allow = perms.get("allow")
    if not isinstance(allow, list):
        allow = []
        perms["allow"] = allow

    entry = bash_rule_for(command)

    # If the file already has managed markers we cannot safely json.dumps
    # (that would drop the comments). Instead, splice the two lines into
    # the raw text just before the closing `]` of the allow array, and
    # add the entry to the json model only for the from-scratch path.
    if _managed_item_ids(raw):
        new_raw = _splice_into_allow_array(raw, item_id, entry)
        if new_raw is None:
            # Couldn't locate the array structurally — rebuild from the
            # parsed model (markers are recovered below).
            new_raw = _serialize_with_markers(data, raw)
        path.write_text(new_raw, encoding="utf-8")
        return True

    # Clean file (no managed markers yet). Add to the model, serialize,
    # then promote our entry to a marker+entry pair.
    allow.append(entry)
    new_raw = _serialize_with_markers(data, raw,
                                      new_marker=(item_id, entry))
    path.write_text(new_raw, encoding="utf-8")
    return True


def _splice_into_allow_array(raw: str, item_id: str, entry: str) -> str | None:
    """Insert `marker` + `"entry",` as the last two lines of the
    `permissions.allow` array in the RAW text, preserving every
    existing managed comment. Returns the new text, or None if the
    array's closing bracket couldn't be located structurally."""
    lines = raw.splitlines()
    # Find the allow array: the line containing `"allow"` then the
    # matching `]`. We track bracket depth from the `[` that opens it.
    allow_open = None
    for i, ln in enumerate(lines):
        if re.search(r'"allow"\s*:\s*\[', ln):
            allow_open = i
            break
    if allow_open is None:
        return None
    # Walk forward to the closing `]` at the array's own depth.
    depth = 0
    started = False
    close_idx = None
    for i in range(allow_open, len(lines)):
        for ch in lines[i]:
            if ch == "[":
                depth += 1
                started = True
            elif ch == "]":
                depth -= 1
                if started and depth == 0:
                    close_idx = i
                    break
        if close_idx is not None:
            break
    if close_idx is None:
        return None

    indent = _detect_array_indent(lines, allow_open, close_idx)
    # Ensure the entry currently above the close has a trailing comma.
    insert_at = close_idx
    prev = insert_at - 1
    while prev > allow_open and lines[prev].strip() == "":
        prev -= 1
    if prev > allow_open:
        stripped_prev = lines[prev].rstrip()
        if stripped_prev and not stripped_prev.endswith(","):
            lines[prev] = stripped_prev + ","
    marker_line = f"{indent}{SCOPE_GROOM_MARKER} {item_id}"
    entry_line = f'{indent}{json.dumps(entry)},'
    # Drop the trailing comma on OUR entry only if it is the last item
    # AND the array had no prior items — but we always added a comma to
    # prev, so a trailing comma on a non-last item is fine; JSON forbids
    # a trailing comma on the LAST item, and ours is now last. Remove it.
    entry_line = entry_line.rstrip(",")
    new_lines = lines[:insert_at] + [marker_line, entry_line] + lines[insert_at:]
    text = "\n".join(new_lines)
    if raw.endswith("\n"):
        text += "\n"
    return text


def _detect_array_indent(lines: list[str], open_idx: int,
                         close_idx: int) -> str:
    """Indent string for entries inside the allow array."""
    for i in range(open_idx + 1, close_idx):
        ln = lines[i]
        if ln.strip():
            return ln[: len(ln) - len(ln.lstrip())]
    # Fall back: array-open indent + 2 spaces.
    open_ln = lines[open_idx]
    base = open_ln[: len(open_ln) - len(open_ln.lstrip())]
    return base + "  "


def _serialize_with_markers(data: dict, raw: str,
                            new_marker: tuple[str, str] | None = None) -> str:
    """Serialize `data` to pretty JSON, then re-attach managed marker
    comment lines above their guarded Bash entries.

    `new_marker` (item_id, entry) tags one entry that has no recovered
    marker yet (the from-scratch write path). Existing markers are
    recovered from `raw` by pairing each marker line with the Bash
    entry directly below it."""
    recovered = _recover_marker_map(raw)
    if new_marker is not None:
        recovered.setdefault(new_marker[1], []).append(new_marker[0])

    pretty = json.dumps(data, indent=2)
    out_lines: list[str] = []
    for ln in pretty.splitlines():
        m = _BASH_ENTRY_LINE.match(ln)
        if m is not None:
            entry = f"Bash({m.group('inner')})"
            for item_id in recovered.get(entry, []):
                indent = ln[: len(ln) - len(ln.lstrip())]
                out_lines.append(f"{indent}{SCOPE_GROOM_MARKER} {item_id}")
        out_lines.append(ln)
    text = "\n".join(out_lines)
    if raw.endswith("\n") or not raw:
        text += "\n"
    return text


def _recover_marker_map(raw: str) -> dict[str, list[str]]:
    """Map `Bash(<command>)` entry → [item_ids] from existing managed
    markers in raw text. A marker pairs with the nearest Bash entry on
    a following line."""
    out: dict[str, list[str]] = {}
    lines = raw.splitlines()
    for i, ln in enumerate(lines):
        if _ANY_MARKER_LINE.match(ln):
            tail = ln.strip()[len(SCOPE_GROOM_MARKER):].strip()
            for j in range(i + 1, len(lines)):
                m = _BASH_ENTRY_LINE.match(lines[j])
                if m is None:
                    if _ANY_MARKER_LINE.match(lines[j]):
                        break
                    continue
                entry = f"Bash({m.group('inner')})"
                out.setdefault(entry, []).append(tail)
                break
    return out


def revoke_rules(path: Path, item_id: str) -> int:
    """Remove ALL managed rules for `item_id` from `path`.

    Operates on RAW LINES so the `//` comments for OTHER items survive.
    For each marker line matching `item_id`, removes that marker line
    plus the structurally-adjacent `"Bash(...)"` entry (the entry on
    the next non-blank line; if that isn't a Bash entry we walk forward
    to the nearest Bash entry before the next marker, defensively).

    Fixes up trailing-comma validity: if removing the last array entry
    leaves a dangling comma on the now-last entry, that comma is
    stripped so the result re-parses as JSON.

    Returns the number of rules removed. Raises SettingsError if the
    pre-image is genuinely corrupt (we still refuse to touch a
    corrupt file)."""
    if not path.exists():
        return 0
    # Validate the pre-image (fail-safe). Markers are tolerated.
    load_settings(path)

    raw = path.read_text(encoding="utf-8")
    lines = raw.splitlines()
    marker_re = _marker_line_for(item_id)
    drop: set[int] = set()
    removed = 0

    for i, ln in enumerate(lines):
        if i in drop:
            continue
        if marker_re.match(ln):
            drop.add(i)
            # Find the adjacent Bash entry below.
            for j in range(i + 1, len(lines)):
                if j in drop:
                    continue
                if _ANY_MARKER_LINE.match(lines[j]):
                    break  # next managed block; no entry for this marker
                if _BASH_ENTRY_LINE.match(lines[j]):
                    drop.add(j)
                    removed += 1
                    break
                if lines[j].strip() == "":
                    continue
                # A non-blank, non-Bash, non-marker line: the marker had
                # no adjacent entry. Stop — only drop the orphan marker.
                break

    if not drop:
        return 0

    kept = [ln for idx, ln in enumerate(lines) if idx not in drop]
    text = "\n".join(kept)
    if raw.endswith("\n"):
        text += "\n"

    # Deleting the last array entry can leave a dangling trailing comma
    # on the now-last surviving entry (JSON forbids it). That comma is an
    # artifact of OUR own raw-line deletion, not operator corruption, so
    # we normalize it out before re-validating. The normalizer is scoped
    # to "comma immediately before a closing ] or }" — it cannot mask a
    # genuinely-malformed file (unbalanced braces still fail to parse).
    # `text` (with surviving markers) drives marker recovery; the
    # comma-fixed, marker-stripped image drives JSON validation.
    validated_text = _strip_dangling_trailing_commas(text)
    data = load_settings_from_text(validated_text, path)
    text = _serialize_with_markers(data, text)
    path.write_text(text, encoding="utf-8")
    return removed


def _strip_dangling_trailing_commas(text: str) -> str:
    """Remove JSON-illegal trailing commas that our own raw-line
    deletion can introduce: a STRUCTURAL comma that is the last
    non-whitespace character before a STRUCTURAL `]` or `}` (possibly
    across blank lines).

    JSON-STRING-AWARE: commas, brackets, and whitespace INSIDE a string
    value are never touched, so a surviving allow entry whose value
    literally contains `,]` or `,}` (e.g. `Bash(echo "[a,]")`) is
    preserved verbatim — the naive `re.sub(r",(\\s*[\\]}])", ...)` would
    have silently corrupted it (re-audit panel 2026-06-13, Kleppmann).
    Operates on the marker-stripped image so managed `//` lines don't
    confuse the scan. Conservative: only the structural
    comma→close-bracket case is collapsed; every other character is kept,
    so a genuinely-malformed file (unbalanced braces) still fails to
    parse downstream."""
    stripped = _strip_managed_marker_lines(text)
    chars = list(stripped)
    n = len(chars)
    # Pass 1: flag every character that lives inside a JSON string literal
    # (respecting backslash escapes), so structural punctuation can be
    # told apart from punctuation inside a command string.
    in_string = [False] * n
    inside = False
    escape = False
    for i, ch in enumerate(chars):
        if inside:
            in_string[i] = True
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                inside = False
        elif ch == '"':
            inside = True
            in_string[i] = True
    # Pass 2: drop each STRUCTURAL comma immediately followed — across
    # structural whitespace only — by a structural `]` or `}`.
    drop: set[int] = set()
    for i, ch in enumerate(chars):
        if ch != "," or in_string[i]:
            continue
        j = i + 1
        while j < n and chars[j].isspace() and not in_string[j]:
            j += 1
        if j < n and chars[j] in "]}" and not in_string[j]:
            drop.add(i)
    if not drop:
        return stripped
    return "".join(ch for k, ch in enumerate(chars) if k not in drop)


def load_settings_from_text(text: str, path: Path) -> dict:
    """Same comment-tolerant parse as load_settings but from an
    in-memory string (used after a raw-line revoke to re-validate)."""
    stripped = _strip_managed_marker_lines(text)
    if stripped.strip() == "":
        return {}
    try:
        data = json.loads(stripped)
    except json.JSONDecodeError as exc:
        raise SettingsError(
            f"post-revoke settings not valid JSON: {path} ({exc})"
        ) from exc
    if not isinstance(data, dict):
        raise SettingsError(f"post-revoke root not an object: {path}")
    return data


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description=("Write/revoke scope-groom-managed narrow Bash rules "
                     "in .claude/settings.local.json."))
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_write = sub.add_parser("write", help="write a managed rule")
    p_write.add_argument("--settings", type=Path, required=True)
    p_write.add_argument("--item-id", required=True)
    p_write.add_argument("--command", required=True,
                         help="narrow command pattern, e.g. "
                              "'gh issue create --repo X *'")
    p_write.add_argument("--answer", default=None,
                         help="optional interview answer; if given, the "
                              "rule is written ONLY when it authorizes "
                              "the autonomous loop")

    p_revoke = sub.add_parser("revoke", help="revoke managed rules for an item")
    p_revoke.add_argument("--settings", type=Path, required=True)
    p_revoke.add_argument("--item-id", required=True)

    args = parser.parse_args(argv)

    try:
        if args.cmd == "write":
            if args.answer is not None and not is_autonomous_authorization(
                    args.answer):
                print(json.dumps({
                    "action": "write",
                    "result": "noop",
                    "reason": "answer did not authorize autonomous loop",
                }))
                return 0
            changed = write_rule(args.settings, args.item_id, args.command)
            print(json.dumps({
                "action": "write",
                "result": "written" if changed else "noop",
                "item_id": args.item_id,
                "command": args.command,
            }))
            return 0
        if args.cmd == "revoke":
            n = revoke_rules(args.settings, args.item_id)
            print(json.dumps({
                "action": "revoke",
                "removed": n,
                "item_id": args.item_id,
            }))
            return 0
    except SettingsError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    except OSError as exc:
        print(f"error: io: {exc}", file=sys.stderr)
        return 2
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
