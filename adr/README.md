# Architecture Decision Records

One file per architectural decision, dated and immutable. An ADR records *why a choice was
made at a point in time*, including what was rejected and what the choice costs. It is
history, not documentation of current behaviour.

## Why these exist alongside the other docs

| Doc | Answers | Tense |
|---|---|---|
| `AGENTS.md` | What invariants hold right now, and where the code is | present, terse |
| `vignettes/articles/design.Rmd` | How the architecture works and hangs together | present, narrative |
| `vignettes/articles/roadmap.Rmd` | What we intend to change | future |
| `adr/` (here) | Why we chose this over the alternatives, and when | past, immutable |

Practical test for where something belongs:

- "Masks are cached per rule object; never mutate a rule" → AGENTS.md.
- "Tiles are read whole on a local link and as merged ranges on a slow one" → design.Rmd.
- "We plan a coarse transcript tier" → roadmap.Rmd.
- "We dropped DuckDB-WASM because hyparquet read the polygon tiles in 245 ms against 1.1 s,
  and a viewer without R is not a goal" → ADR.

AGENTS.md and design.Rmd state the *outcome* of an ADR without rehearsing the argument. When
they disagree, AGENTS.md wins for current behaviour and the ADR for intent, and the
disagreement is a sign that a superseding ADR is owed.

## Writing one

1. Copy `0000-template.md` to `NNNN-short-kebab-title.md`, taking the next free number.
   Numbers are record order, not decision order.
2. Fill it in. Keep it to a page; the extra belongs in design.Rmd, linked from the ADR.
3. Add a row to the index below, and an `adr/NNNN` comment at the code the decision
   constrains, where the tempting edit would be made.

## Amending one

An accepted ADR is not edited, except its `Status` line and added links (`Superseded by`).
Everything else changes by writing a new ADR that supersedes it.

Statuses: **Proposed** · **Accepted** · **Superseded by NNNN** · **Reversed** ·
**Deprecated**.

## Scope

Something an outsider, or you in six months, would otherwise change by accident: a decision
that constrains future code, was contested or non-obvious, or has a cost worth remembering.
Not bug fixes, behaviour-preserving refactors or naming conventions (AGENTS.md
"Conventions").

## Index

| # | Title | Status | Date |
|---|---|---|---|
| [0001](0001-selections-are-rules-over-all-cells.md) | Selections are rules over all cells, evaluated in the browser and in R | Accepted | 2026-10-30 |
| [0002](0002-cells-numbered-by-polygon-tile.md) | Cells are numbered by concatenated polygon tiles; the browser holds no string IDs | Accepted | 2026-10-30 |
| [0003](0003-no-browser-data-model.md) | No browser-side data model: DuckDB-WASM and Mosaic removed | Accepted | 2026-10-30 |
| [0004](0004-tile-transfer-whole-or-merged-columns.md) | Tiles are read whole on a fast link and as merged column ranges on a slow one | Accepted | 2026-10-30 |
| [0005](0005-own-point-decoder-sampling-before-decode.md) | Transcript tiles use an own JS decoder that samples before decoding | Accepted | 2026-10-30 |
| [0006](0006-localhost-token-advisory-origin.md) | Serve on localhost under a per-launch token path; the Origin check is advisory | Accepted | 2026-10-30 |
| [0007](0007-interactive-selection-not-through-spatrelate.md) | Interactive selection does not go through `spatRelate()` | Accepted | 2026-10-30 |
| [0008](0008-images-read-by-the-browser-from-the-tiff.md) | Images are read by the browser from their TIFF file, JPEG-2000 decoded in workers | Accepted | 2026-10-31 |
| [0009](0009-panels-docked-with-dockview-config-held-by-r.md) | Panels are docked with dockview-core 4; R holds the saved config | Accepted | 2026-11-02 |
| [0010](0010-cells-are-a-table-drawn-as-marks.md) | Cells are a table drawn as marks; polygons are optional detail | Proposed | 2026-11-02 |
| [0011](0011-binned-features-drawn-as-a-texture.md) | Binned feature data is drawn as a texture | Proposed | 2026-11-02 |
| [0012](0012-density-panel-drawn-as-one-image.md) | The density panel is drawn as one image, its rectangle as two ranges | Accepted | 2026-11-02 |
| [0013](0013-panel-brush-drags-are-live.md) | A panel brush drag is live; its rule is set on release | Accepted | 2026-11-05 |
| [0014](0014-images-registered-by-landmarks-in-the-browser.md) | Images are registered by landmarks in the browser | Proposed | 2026-11-03 |
