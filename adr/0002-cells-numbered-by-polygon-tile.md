# 0002. Cells are numbered by concatenated polygon tiles; the browser holds no string IDs

- **Status:** Accepted
- **Date:** 2026-10-30
- **Supersedes:** —
- **Superseded by:** —

## Context

Per-cell data in the browser was keyed by cell ID strings: colour maps, the hover cache (one
object per cell), selection sets and the metadata table joined on `cell_ID`. String-keyed maps
of millions of entries are slow and large, and every polygon tile row needed an ID lookup to
colour or highlight it. Rule masks (adr/0001) need a dense index.

## Decision

Cell `i` is defined by concatenating the polygon tiles in manifest order: tile `t` holds cells
`offset[t] .. offset[t] + n[t] - 1`. R writes `cells.parquet` (centroids and IDs) in that
order at launch, and writes pushed metadata in the same order. The browser keeps typed arrays
indexed by `i` and never needs IDs except for tooltips (read lazily). R keeps the IDs and
translates in both directions.

## Consequences

- A tile row maps to its cell by addition; all cells draw as centroids from the start
  (0.12–0.16 s for 170k on Atera, against 1.1–1.9 s waiting for polygon tiles).
- Each tile is a contiguous index range, so tile bounds prune spatial rule evaluation.
- The order depends on the polygon tiles; a re-tiled store renumbers cells. Nothing persists
  indices across launches; anything that must survive (saved selections) is a rule or IDs.
- Duplicate IDs across tile rows are warned about at launch.

## Alternatives considered

- **Metadata row order** — needs an ID join per polygon tile row to draw.
- **Index column written into the tiles** — rewrites GiottoDisk stores; the viewer must not
  write next to the data.

## References

`R/export.R` (`.build_cells`), `data/cells.ts`, `R/metadata.R` (`.write_metadata`).
