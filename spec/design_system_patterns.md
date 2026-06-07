# Design-system patterns

The canonical opinionated defaults for the V.10b A/B Design-system
render toggle in `HTMLPreviewView`. Selecting `Design-system` parses
this file into a structured rule set, generates a stylesheet, and
injects it into the WKWebView via `WKUserScript` at document-end.

Operator may override post-ship by editing the rule lines below.
The parser re-reads on every pane open / mode flip; no caching.

Rule line format (one rule per line, under a `## <slot>` heading):

    - <token-name>: <value>

`<token-name>` is dot-delimited; `<value>` is a CSS value literal
(length, ratio, color, font-family list, integer). Lines outside the
four canonical headings (`## Spacing`, `## Contrast`, `## Hierarchy`,
`## Type scale`) are ignored. The four headings are required; the
parser fails closed on any missing.

## Spacing

- spacing.unit: 4px
- spacing.pad-block: 16px
- spacing.pad-inline: 16px
- spacing.section-rhythm: 32px
- spacing.gap-tight: 8px
- spacing.gap-loose: 24px

## Contrast

- contrast.body-min: 4.5
- contrast.heading-large-min: 3.0
- contrast.body-fg: #1a1a1a
- contrast.body-bg: #ffffff
- contrast.muted-fg: #555555

## Hierarchy

- hierarchy.h1-scale: 2.4
- hierarchy.h2-scale: 1.8
- hierarchy.h3-scale: 1.4
- hierarchy.section-mark-weight: 600

## Type scale

- typeScale.base: 1rem
- typeScale.ratio: 1.25
- typeScale.line-height: 1.55
- typeScale.body-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif
- typeScale.mono-family: ui-monospace, SFMono-Regular, Menlo, monospace
