# Code-quality pack — context

This pack enforces **lint discipline** and **review heuristics**
combined. It pairs a two-phase HandManifest skill (`lint-enforcement`
+ `review-heuristics`) with a HookRouter policy fragment that denies
the three most common per-line lint-suppression markers
(`eslint-disable-next-line`, `swiftlint:disable`, `# noqa`).

When a tool call (Bash, Edit, Write) carries any of those markers in
its primary argument, the HookRouter blocks the call with the
matching deny reason. The skill phase bodies cover the rest of the
review surface — test coverage on new code, docstrings on public
API, type hints on exported symbols.

To opt out, run `senkani pack uninstall code-quality` and the
HookRouter merge drops the rules immediately.
