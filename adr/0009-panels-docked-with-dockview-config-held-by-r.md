# 0009. Panels are docked with dockview-core 4; R holds the saved config

- **Status:** Accepted
- **Date:** 2026-11-02
- **Supersedes:** —
- **Superseded by:** —

## Context

The stats column had two fixed panes, and `push_panel(pane = 1|2)` replaced one of them. A
pushed panel's selection source was named after its pane's element, so it could not move.
Panels need tabs and splits, placement from R, and moving in the viewer, with only the chart
panels docked: the spatial view stays one view, where it is. A page reload, which IDE viewer
panes do often, reset everything but the metadata and rules.

## Decision

Chart panels dock with dockview-core 4.13.1, pinned. Every panel has a stable id that names
its dock slot, its selection source (`panel:<id>`, `scatter:<id>`) and its data file, so
moving it changes nothing else. The layout (dockview's `toJSON()`) is store config like any
other.

The config is saved through R: zustand's `persist` middleware sends it on change (merged over
300 ms, identical copies dropped) as JSON text, R keeps the latest copy verbatim, and R sends
it back first when a page connects (`restore`), then the metadata, rules and pushed panels it
holds. Rules stay out of the saved config, since R already restores them.

## Consequences

- Bundle: +169 KB minified JS (+41 KB gzipped, main chunk 2,076 to 2,245 KB) and a 37 KB
  stylesheet (4 KB gzipped).
- A reload brings back the layout, pushed panels, layers, images, genes, colouring and
  annotations. Closing the viewer loses them; saving to a file is issue #21.
- The saved config is the page's own JSON text; R never parses and re-serialises it (jsonlite
  would turn `{}` into `[]`).
- A pushed panel exists until it is closed in the viewer (`panel_closed`) or by
  `remove_panel()`; R re-sends its payload to every new page.
- Hidden tabs keep their DOM (`defaultRenderer: 'always'`), so a moved deck.gl canvas or
  Vega view survives; panels skip updates while hidden and catch up when shown.

## Alternatives considered

Sizes measured on 2026-11-02 (esbuild, minified / gzipped):

- **dockview-core 8.8.3** (latest): 368 / 88 KB JS; every feature module is bundled, none can
  be left out. Its module build ships no stylesheet: the CSS (142 KB minified) is only inside
  the standalone browser build. Majors 5 to 8 came in nine months.
- **golden-layout 2.6**: 128 / 30 KB JS + 9 KB CSS, but no release since February 2023.
- **Built on Split.js** (already a dependency): no added size, but tabs, drag-to-dock, drop
  targets and layout serialisation written and kept by us.
- **Browser storage for the config** (`localStorage`/`sessionStorage`): works for a reload
  (same origin), but R would not know the layout to re-push panels into, `state()` could not
  answer without a page, and a later save to file could not start from R's copy. Untested
  inside Positron's viewer pane.

## References

`panels/dock.ts`, `core/persist.ts`, `core/store.ts`; `R/viewer.R` (`push_panel()`,
`remove_panel()`, `panels()`, the `ready` handler); design.Rmd "Panels".
