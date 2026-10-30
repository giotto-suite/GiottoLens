# 0003. No browser-side data model: DuckDB-WASM and Mosaic removed

- **Status:** Accepted
- **Date:** 2026-10-30
- **Supersedes:** —
- **Superseded by:** —

## Context

DuckDB-WASM (40 MB) read polygon tiles, held cell metadata as a SQL table and served the
metadata filter and the transcript lasso. Mosaic drew one histogram and, through a bare
`wasmConnector()`, started a second DuckDB-WASM from a CDN, breaking offline use and loading
the metadata twice. Measured: hyparquet plus the existing JS WKB decoder read all 11 Atera
polygon tiles in 245 ms, against 1.1–1.9 s through DuckDB. With rule masks (adr/0001) every
remaining query is a typed-array scan.

GiottoLens is used with an R session alongside it, and the data model belongs to the giotto
object and GiottoClass/GiottoDisk.

## Decision

The browser keeps no second data model: no DuckDB-WASM, no Mosaic, no browser SQL. R prepares
what the browser draws; queries beyond typed-array scans run in R. A viewer with no R session
is not a goal.

## Consequences

- Bundle 43 MB → 2.3 MB; no runtime network fetches; faster boot.
- No free-form SQL in the browser and no serverless SQL viewer. Ad hoc queries are done in
  R, where agents work.
- Mosaic-style aggregate crossfiltering over very large tables is not available in the
  viewer; aggregates come from typed arrays or R (roadmap).
- Revisit only if a viewer without R becomes a goal.

## Alternatives considered

- **Keep DuckDB-WASM, share it with Mosaic** — removes the CDN instance but keeps 40 MB and a
  SQL model to keep aligned with the giotto object.
- **Commit to Mosaic for selection** — SQL-clause selections cannot be evaluated per tile or
  in R as rules.

## References

`data/parquet.ts`, `panels/histogram.js`; design.Rmd "Goals", "Panels".
