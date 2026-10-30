# 0004. Tiles are read whole on a fast link and as merged column ranges on a slow one

- **Status:** Accepted
- **Date:** 2026-10-30
- **Supersedes:** —
- **Superseded by:** —

## Context

httpuv's `staticPath` ignores Range (always 200 and the whole file), so a Range handler was
added in R. hyparquet then fetched each column chunk separately: about 31 requests per
transcript tile, each served on R's main thread. In Positron panning slowed, and while R is
busy every request waits. Measured on Atera, 10 transcript tiles plus outlines: whole files
from httpuv's own thread 0.82–0.98 s with R free and 0.89–0.91 s with R busy for 2 s; merged
column ranges (about two requests per tile, 6x fewer bytes) 0.91–1.08 s free, 2.8–3.2 s busy.
Over a slow link bytes dominate. An SSH port forward also shows as `localhost`.

## Decision

Mount each store twice under the viewer's path: whole files from httpuv's static thread
(`files/`) and the Range handler (`data/`). The viewer reads a tile either whole, or as its footer plus
the needed column blocks merged when less than 1 MB apart. `auto` starts whole on a localhost
URL and switches to columns after two whole fetches under 150 MB/s; `launch_lens(transfer =)`
overrides.

## Consequences

- Local viewing never waits on R. Slow links move only the drawn columns.
- Column mode still runs through R's main thread; remote viewing through R needs Range
  serving off the main thread, or lean tiles (roadmap).
- Every Range slice must be a 206; a 200 would be misread as the slice.

## Alternatives considered

- **Range handler only** — the panning regression above.
- **Whole files only** — 28 MB per tile over a tunnel.
- **Choose by hostname** — misclassifies SSH port forwards.

## References

`data/parquet.ts` (`tileSource`, `transferMode`, `mergedRanges`), `R/server.R`
(`.lens_app`, `.data_response`); design.Rmd "Reading tiles".
