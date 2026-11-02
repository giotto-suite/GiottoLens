# 0010. Cells are a table drawn as marks; polygons are optional detail

- **Status:** Proposed
- **Date:** 2026-11-02
- **Supersedes:** 0002 (numbering by polygon tile), once accepted
- **Superseded by:** —

## Context

Cells exist in the viewer only when a polygon tile store is given (adr/0002). Without one,
`push_metadata()` stops, and there is no cell selection, scatter or histogram. Many datasets
have no cell polygons: Visium spots, Slide-seq beads, segmentation-free cell calls, and
VisiumHD bin spatial units (`bin008`, `bin016`), which GiottoDisk's reader loads as spatial
locations plus metadata (`in_tissue`, `array_row`, `array_col`) and no polygons.

Polygons already matter less than this suggests. The browser draws every cell from
`cells.parquet` (ID, x, y) as a 2 px dot at every zoom, and fetches polygon tiles only for
outlines near outline zoom. Selection is centroid membership (adr/0007); rules, metadata,
tooltips and R-side evaluation read only the cell table. Polygons supply the cell order and
the per-tile offsets and bounds that prune rule evaluation.

The upstream way out works today: stamp a shape at each location (GiottoClass `polyStamp()`
with `circleVertices()`, as Giotto's Visium reader does for spots), save, reload. It writes a
geometry store of invented outlines, and sizes only show once those tiles load.

A 6.5 mm VisiumHD capture area holds about 165k bins at 16 µm and 660k at 8 µm, within what
instanced deck.gl marks and the browser's rule masks already handle (adr/0001).

## Decision

A cell layer is three parts:

- **Cell table:** ID, x, y in a fixed order, split into chunks with offsets and centroid
  bounds. From the polygon tiles when the spatial unit has polygons; otherwise from its
  spatial locations, sorted by R into grid chunks. Cells are numbered in table order.
- **Mark:** `{shape, size, angle}` for one cell at true size; shape is circle, square or
  hex, size is in data units. R infers it: a fit of x, y against `array_row`/`array_col`
  when the metadata has them (exact spacing and angle), otherwise the median
  nearest-neighbour spacing and angle 0. `launch_lens(mark =)` overrides any field. This
  launch mark is a default: the viewer's configuration holds a setting over it (from
  `set_mark()` or the mark control), saved and restored with the rest of the configuration.
  Cells from spatial locations draw their mark by default; segmented cells carry one but
  draw dots until it is turned on.
- **Geometry (optional):** polygon tiles aligned with the chunks.

The browser draws marks in data units: dots when zoomed out, true size when zoomed in.
Circles are a `ScatterplotLayer` with a pixel minimum, so they grow continuously. Squares
and hexagons are a `ColumnLayer` with custom `vertices` and `angle`, which has no pixel
minimum, so dots stand in until a mark is as wide as a dot. Where geometry exists, outlines
replace the marks once their tiles load, as they replace dots today.

## Consequences

- Spot, bead, bin and centroid-only datasets get metadata, selection and panels without
  writing a store.
- Which cells a rule selects does not depend on the mark; selection stays centroid
  membership.
- The manifest's `layers.polygons` becomes `layers.cells` (`cells`, `tiles`, `geometry`,
  optional `mark`); its tiles are polygon tiles or chunks without a file, and the scheduler
  fetches tiles only when `geometry` is true.
- Spatial locations are in memory and read whole at launch, so the 10–20M cell ceiling of
  adr/0001 applies to them too.
- An inferred size is a guess for irregular data: circles overlap where cells are dense and
  leave gaps where sparse. For Visium spots it is the centre spacing (290 px on a local
  sample) where the spots are 189 px across. The override is the remedy; platform sizes are
  on the roadmap.
- One mark per layer: datasets whose cells need individual sizes are out of scope. Revisit
  if one turns up.
- An inferred mark is computed for every cell layer, also segmented ones that may never
  draw it: one neighbour-spacing pass at launch (0.9 s for 660k cells).
- Changing the mark needs no relaunch, and a wrong inferred size is fixed in the viewer.

## Alternatives considered

- **Stamp polygons upstream** (`polyStamp()`): works today with no viewer change, but writes
  a geometry store of invented shapes, and true sizes show only once tiles load.
- **Swap dots for sized marks at a zoom threshold:** two layers and a visible jump; a size
  in data units with a pixel minimum does the same continuously.
- **Per-cell mark sizes:** more bytes per cell for no dataset that needs them yet.
- **Bin units as a grid texture:** a second rendering path with its own picking,
  highlighting and selection display, for a load instanced marks handle. The texture is kept
  for binned *features* (adr/0011).

## References

`R/export.R` (`.build_cells`, `.build_cells_xy`), `R/marks.R`, `R/viewer.R`
(`.resolve_layers`, `.spat_locations`), `render/marks.ts`, `render/render.js`,
`data/schedule.js`; `tests/testthat/test-marks.R`, `test-e2e.R` ("bins without polygons"); GiottoClass
`polyStamp()`, `circleVertices()`; Giotto `.visiumhd_cellmeta()`; GiottoDisk
`convenience-visiumhd.R`; roadmap.Rmd "Cells without polygons".
