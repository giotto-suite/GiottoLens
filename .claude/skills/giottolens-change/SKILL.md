---
name: giottolens-change
description: Checklist for changing GiottoLens — the viewer (inst/viewer-src), the R API (LensViewer, lens_*()), selection rules, the protocol, or tile reading. Use when adding a viewer feature, an R method, a rule kind or a message type, or when changing how tiles are served or decoded. Keeps the R and browser sides, the built bundle, the tests and the docs in step.
---

# Changing GiottoLens

GiottoLens has two halves that must agree: R (`R/`) and the browser
(`inst/viewer-src/`), joined by a WebSocket protocol and by selection rules
that both sides evaluate. Most bugs this skill prevents are one half changing
without the other, or the built bundle not matching the source.

## Orientation

1. `AGENTS.md`: invariants and where code lives.
2. `adr/` before changing anything a pointer in the code names (`adr/NNNN`).
3. `vignettes/articles/design.Rmd` for how the pieces fit.

## Which change is it?

**A new thing a user can do in the browser.** Give it an R equivalent on
`LensViewer` (the R API is the agent API): a message type handled in
`core/remote.js` (request/reply if R needs an answer) and a method in
`R/viewer.R`. Store state changes only through `actions` in `core/store.ts`;
renders follow subscriptions, never call `renderLayers()` directly.

**A new selection rule kind, or a change to how one evaluates.** Change both
`selection/rules.ts` and `R/rules.R` (`.validate_rule`, `.eval_rule`,
`.rule_summary`, `.rule_code`), plus `ruleLabel()` in `ui/rules.js`. Add the
kind to the JS/R comparison in `tests/testthat/test-e2e.R` and a unit test on
each side. Rules are never mutated in place: masks are cached by rule object.

**A new message type or payload change.** Both `core/comms.js` /
`core/remote.js` and `R/protocol.R` / `R/viewer.R`. If the format changes
incompatibly, bump `PROTOCOL` (comms.js) and `.lens_protocol` (protocol.R)
together. Inbound types must be listed in `.lens_inbound_types`.

**Per-cell data.** Index by cell (`state.cells`, typed arrays), never by cell ID
string. R translates IDs (`private$cell_ids`). Metadata arrives in cell order.

**Tile reading or serving.** Reads go through `tileSource()` /
`readTileColumns()` in `data/parquet.ts` so both transfer modes keep working;
transcript decoding through `data/point-decode.ts` with its hyparquet
fallback. Measure on the Atera example before and after (headless Chrome via
chromote; see the e2e helpers), and record a decision backed by a measurement
as an ADR.

**deck.gl layers.** Build binary `data` objects once per underlying array
(`once()` in `render/render.js`); a new object each render re-triangulates and
re-uploads.

## Before you finish

```bash
cd inst/viewer-src
npm test && npm run typecheck && npm run build     # commit inst/viewer/ with the source
```

```r
devtools::document()
devtools::test()          # with NOT_CRAN=true and Chrome for the e2e tests
devtools::check()         # 0 errors, 0 warnings; non-ASCII only in comments
```

- `NEWS.md`: an entry for any user-visible change.
- `README.md`: new R API methods (and the agent section if agents would use them).
- `AGENTS.md`: new invariants or files; `design.Rmd`: changed architecture;
  `roadmap.Rmd`: items done or added.
- An ADR (`adr/README.md`) for a decision someone could reasonably reverse, with
  an `adr/NNNN` pointer at the code it constrains.
- Merging to `main` is a release: bump the version in `DESCRIPTION`.
