# Senkani CLI Conventions

> The style guide for `senkani <command>`. Argument naming, verb
> choice, output formats, exit codes, stdout vs stderr policy.
> Contributors adding a new subcommand: read this first; deviations
> need a `// CLI deviation:` comment in the command file.
>
> See [`spec/glossary.md`](../spec/glossary.md) for what `tool`,
> `pane`, `session`, `hook`, `artifact`, etc. mean.

---

## Verb choice (top-level commands)

Each subcommand is a verb. Choose the verb so that
`senkani <verb> [object]` reads as imperative English.

| Verb     | Meaning                                                    | Examples                          |
|----------|------------------------------------------------------------|-----------------------------------|
| `init`   | Idempotent setup; safe to re-run.                          | `init`, `mcp-install`             |
| `doctor` | Read-only diagnosis of the install + environment.          | `doctor`                          |
| `index`  | Build or rebuild a derived store.                          | `index`, `kb rebuild`             |
| `search` | Read query, list results, exit.                            | `search`, `kb search`             |
| `fetch`  | Read query, return a single primary result.                | `fetch`                           |
| `explore`| Walk a graph from a root.                                  | `explore`                         |
| `bench`  | Run a measurement, exit with the number.                   | `bench`, `eval`                   |
| `learn`  | Inspect/modify the compound-learning store.                | `learn status`, `apply`, `reject` |
| `schedule` | Manage cron-style background tasks.                      | `schedule add`, `remove`, `run`   |
| `wipe`   | **Destructive.** Always requires `--yes`.                  | `wipe`                            |
| `uninstall` | Remove Senkani from this machine.                       | `uninstall`                       |

Avoid noun-shaped commands (`senkani indexer`, `senkani database`).
The thing being acted on is the object, not the verb.

## Argument naming

- **Long form is canonical.** Every option declares
  `name: .long` — no implicit short forms. Add short forms only when
  ergonomics demand it (`-y` for `--yes`, etc.) and document them
  explicitly.
- **kebab-case** for multi-word flags: `--keep-data`, `--include-config`,
  `--since-days`, `--auto-fix`. Never `--keep_data` or `--keepData`.
- **`--root`** is the canonical name for the project root. Every
  command that needs one calls it `--root` (not `--project`,
  `--project-root`, `--path`, `--dir`). Consistency across
  `index`, `search`, `fetch`, `explore`, `eval`, `kb`, `bundle`,
  `validate`.
- **`--yes`** is the canonical confirmation override for destructive
  actions. Wipe and uninstall both use it. Don't invent
  `--confirm` / `--force` aliases.
- **Boolean flags** read as a true assertion: `--keep-data` is true
  when present. Avoid `--no-` prefixes; if you find yourself wanting
  one, the default is wrong.
- **Path-shaped options** end in `-path` only when ambiguous with a
  non-path option of the same root: `--db-path`, `--metrics-path`.
  Otherwise plain (`--output`, `--root`).

## Output formats

Two output formats. Pick one per command and stick with it.

- **Human (default)** — terse, columnar, no ANSI in CI (autodetect
  via `isatty(1)`). Lead with the headline number; supporting detail
  underneath.
- **`--json`** — stable schema. Every JSON-emitting command
  documents its schema in the command file's top-of-file comment.
  Adding a key is non-breaking; removing or renaming one is.

`--format <markdown|json>` is reserved for commands that produce a
**document** (e.g., `senkani bundle`) where markdown is the
human-readable form. Don't introduce `--format` for commands whose
human output is not a document.

`--output <path>` writes to a file; `-` means stdout. Default for
file-writing commands is stdout.

## Exit codes

- `0` — success.
- `1` — operation failed (`throw ExitCode.failure`). Default failure
  code; covers indexing errors, file-not-found, validation failures,
  doctor regressions when `--strict`.
- `2` — argument-parsing failure (handled by `ArgumentParser`
  automatically — don't override).
- Other non-zero — only when surfacing a child process's exit code
  (`MLEvalCommand` proxies `process.terminationStatus`; `senkani
  exec` proxies the wrapped command's exit code).

Never `exit()` directly from a subcommand. Always `throw
ExitCode.failure` so `ArgumentParser` can clean up.

## stdout vs stderr policy

- **stdout** — the program's *output*: search hits, fetched code,
  doctor's report, JSON payloads. Anything a script might pipe.
- **stderr** — the program's *commentary*: progress lines, warnings,
  error messages, `senkani exec`'s passthrough of wrapped-command
  stderr. Anything a script would *not* pipe.
- A `--json` command writes JSON only to stdout; warnings still go
  to stderr. JSON consumers must be able to parse stdout without
  filtering.
- `senkani exec` is the load-bearing exception: it proxies stdout +
  stderr from the wrapped command faithfully (filter applies only
  to the captured copy used for metrics).

## Confirmation prompts

- Destructive actions (`wipe`, `uninstall`, `learn reject`) prompt by
  default and require `--yes` to skip. The prompt repeats the
  destructive scope ("This will delete: …") before asking.
- Non-destructive actions never prompt. If a command's behaviour
  could surprise the user, that's a design bug — either reduce the
  scope or split the command, don't add a prompt.

## Help text

- Every `@Argument`, `@Option`, `@Flag` carries a `help:` string.
- Help is one sentence, ends with a period, fits on a terminal line
  at 80 columns when rendered as `--flag <type>   help text`.
- Default values go in parentheses at the end:
  `"Maximum results (default 30)."`
- Reference units (`days`, `cents`, `ms`) explicitly:
  `"Window in days to include (default 7)."`

## Subcommand grouping

Commands with multiple verbs (`learn`, `kb`, `schedule`) nest:

```
senkani learn status
senkani learn apply <id>
senkani kb list
senkani kb search <query>
senkani schedule add --task <name> --cron <expr> --command <sh>
```

The parent (`learn`, `kb`, `schedule`) is itself a `ParsableCommand`
with no `run()`; it just hosts subcommands. Don't have the parent
*also* do work — that hides the verb.

## Adding a new subcommand — checklist

1. File at `Sources/CLI/<Name>Command.swift`. Type name ends in
   `Command` (`SearchCommand`, not `Search`).
2. Register in `Senkani.swift` `subcommands:` array.
3. Top-of-file comment: one paragraph summary; if `--json` is
   supported, include the schema.
4. Every flag: `name: .long`, kebab-case, `help:` ending in period.
5. `--root` if scoped to a project; `--yes` if destructive.
6. Exit via `throw ExitCode.failure`; never `exit()`.
7. stdout = output, stderr = commentary.
8. Add to `senkani doctor` if the command exposes a healthy/unhealthy
   state worth surfacing.
