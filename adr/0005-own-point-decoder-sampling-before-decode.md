# 0005. Transcript tiles use an own JS decoder that samples before decoding

- **Status:** Accepted
- **Date:** 2026-10-30
- **Supersedes:** —
- **Superseded by:** —

## Context

With transfer fixed (adr/0004), hyparquet's decode dominated: 1.1 s of CPU for 10 Atera tiles
(7.1M rows), because it builds a JS value per row per column, plus 0.27 s mapping gene names
per row. At zoomed-out tiers the viewer drew 1/16 of the points but decoded all of them. All
three drawn columns are dictionary-encoded. Profile of a page-level decoder: Snappy ~25%,
index unpacking ~30%, the rest per-row work.

## Decision

Decode `x_index`, `y_index` and `feat_ID` with `data/point-decode.ts`: dictionary indices
read only for the kept rows (bit-packed runs allow direct access), gene names mapped once per
dictionary entry, output straight into typed arrays, in Web Workers. Keep it in JavaScript,
and fall back to hyparquet for layouts it does not cover.

## Consequences

- 2.6x faster than hyparquet for all rows, 3.4x at 1/16, identical output; with WASM Snappy
  453 ms and 340 ms for the 10 tiles.
- It reads hyparquet internals (thrift, RLE); recheck on hyparquet upgrades.
- Zoomed-out loads are now bound by bytes, not decoding; the next gain is a coarse tier.

## Alternatives considered

- **Rust/WASM decoder** — the remaining cost is mostly Snappy and allocation; estimated ~1.3x
  more for a second toolchain in the build and CI.
- **Sample after hyparquet** — saves ~240 of ~1400 ms.
- **parquet-wasm** — multi-MB WASM; hung on servers without Range in an earlier test.

## References

`data/point-decode.ts`, `data/tx-decode.ts`, `data/tx-worker.ts`;
`test/point-decode.test.ts`; design.Rmd "Reading tiles".
