# 0007. Interactive selection does not go through `spatRelate()`

- **Status:** Accepted
- **Date:** 2026-10-30
- **Supersedes:** —
- **Superseded by:** —

## Context

The plan was for large-data selections to compile to GiottoDisk operations, with
`spatRelate()` (sedona) for spatial rules, against a ~100 ms target. Measured on Atera, one
200-vertex lasso over 170k cells, IDs returned to R: `spatRelate()` 1.4 s (sedona), 1.8 s
(terra), 5.7 s (duckdb). Bare SQL on the same files: sedona 6 ms and DuckDB 16 ms by
centroid, 54 ms and 36 ms by geometry. Browser masks: 9 ms. The difference is per-call
overhead in `spatRelate()` (engine context, view registration, narrowing checkpoint, tibble of
string IDs). Over 600M transcripts, a 420M-point lasso took sedona 5.3 s and DuckDB 49 s
returning IDs; a 1.1M-point one 0.5–0.8 s.

## Decision

Interactive selection is evaluated in the browser over typed arrays (adr/0001) and, for R,
by `R/rules.R` over the centroids. `spatRelate()` stays the analysis path. The server path for
data too large for the browser waits on an interactive fast path in GiottoDisk (a prepared
query handle returning integer indices, in a warm worker), and serves aggregates rather than
ID lists at transcript scale.

## Consequences

- Interactive selections use centroid membership; `spatRelate()` defaults to geometry
  intersects (0.13% of cells differ on this lasso). The fast path should match the viewer.
- The numbers above are the floor such a fast path can reach; keep them for comparison.

## Alternatives considered

- **Call `spatRelate()` per interaction** — 14–60x over target.
- **Bare SQL from GiottoLens** — puts a second query path beside GiottoDisk's; the viewer and
  a script would drift.

## References

design.Rmd "The large-data path"; roadmap.Rmd "The large-data path"; `R/rules.R`.
