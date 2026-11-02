# 0011. Binned feature data is drawn as a texture

- **Status:** Proposed
- **Date:** 2026-11-02
- **Supersedes:** —
- **Superseded by:** —

## Context

Giotto treats VisiumHD's 2 µm bins as feature data, like transcripts: a `giottoBinPoints`
with one point per bin with counts, and the counts as a features x bins store. On a backed
object the points are a GiottoDisk points tile store whose `feat_ID` is the bin's row in the
counts store, with x and y and no grid indices. A 6.5 mm capture area holds about 10.6M such
bins.

`launch_lens()` rejects it, as it is not a `giottoPoints`. The transcript layer could not take
it anyway: a row is a bin, not a detection of a gene, and gene values live in the counts
store. The bins lie on one regular grid with a single spacing and rotation.

## Decision

Binned feature data is its own layer kind, drawn as a texture: one texel per bin at its grid
position, placed by one transform (spacing, angle, origin); bins without counts are
transparent. At launch R works out each bin's grid position, from the bin barcodes if they
encode row and column (to verify on real data), otherwise joined from
`tissue_positions.parquet` through the counts store's bin IDs. To colour by a gene, R reads
that gene's non-zero bins from the counts store and sends (bin, value) pairs; the browser
writes them into the texture. Hover maps a pixel to a grid position, then to a bin.

## Consequences

- Memory is one value per bin per shown gene, not a position and colour per instance;
  recolouring writes only the non-zero bins.
- A 3,250-texel square fits desktop GPUs (commonly 16,384), but WebGL2 guarantees only
  2,048, so the texture may need splitting into tiles on small devices.
- Needs a per-gene data channel from R, which does not exist yet (roadmap "Per-cell data
  beyond metadata").
- Selection over bins is not part of this decision; cell selection stays on cell layers
  (adr/0010).
- Applies to any binned feature data on a regular grid; it does not depend on adr/0010.

## Alternatives considered

- **Instanced squares** (adr/0010's marks): about 10.6M instances, each with a position and
  colour, and no use made of the grid that a texture gets for free (exact tiling, hover
  without a picking pass).
- **Treat the bins as cells:** Giotto does not; it would put 10.6M rows into every
  per-cell structure and still need per-gene values.
- **The transcript layer:** its rows are detections keyed by gene; these are bins keyed by
  row, with gene values elsewhere.

## References

GiottoClass `classes-binpoints.R`; GiottoDisk `binpoints-disk.R` (`.binpoints_store`),
`convenience-visiumhd.R`; R/viewer.R (`.check_tile_store`); roadmap.Rmd "Cells without
polygons".
