# 0001. Selections are rules over all cells, evaluated in the browser and in R

- **Status:** Accepted
- **Date:** 2026-10-30
- **Supersedes:** —
- **Superseded by:** —

## Context

The viewer kept a selection as a `Set` of cell ID strings built from whatever polygon tiles
happened to be loaded. A lasso drawn zoomed out over unloaded tiles selected nothing there,
invert complemented against the cells seen so far, and Mosaic held a parallel selection as SQL
clauses that the spatial view could only mirror as `cell_ID IN (...)` lists. Selections sent
to R were full ID lists on every mouse move. An agent in R could not express or repeat a
selection except as an ID list.

Measured over typed arrays: a whole-view lasso over 10M centroids takes 248 ms with
band-bucketed point-in-polygon; range and AND/OR passes take 5–50 ms; a cross-filter step on
Atera (170k cells) 2.8 ms.

## Decision

A selection is one typed rule per source (`polygon`, `stroke`, `range`, `categories`,
`compare`, `ids`, `union`, optionally negated), combined with OR or AND. Rules evaluate to
masks over **all** cells; masks are a cache keyed by rule object. The same evaluation exists
in the browser (`selection/rules.ts`) and in R (`R/rules.R`), and selections cross the socket
as bitmasks plus the rules.

## Consequences

- A rule means the same cells wherever it is evaluated and whatever is loaded; R can set,
  read, describe (`rules()`) and print rules as code.
- Two implementations must stay in step. The e2e tests compare them on every rule kind;
  change both together.
- Full-length masks cost one byte per cell. Revisit above roughly 10–20M cells (per-tile
  masks, R-side evaluation; roadmap).
- Rules are never mutated in place, or cached masks go stale.

## Alternatives considered

- **Keep ID sets** — tied to loaded tiles; large to send; not reproducible by an agent.
- **Mosaic selections (SQL clauses)** — cannot be tested per tile in JS, cannot express a
  lasso without an ID list, and are a second model next to the giotto object (adr/0003).
- **Evaluate only in R** — every brush move would round-trip to R; interactive feel lost.

## References

`selection/rules.ts`, `selection/geometry.ts` (`ringTester`), `R/rules.R`;
`tests/testthat/test-e2e.R` ("selections do not depend on what is loaded, and match R");
design.Rmd "Selection rules".
