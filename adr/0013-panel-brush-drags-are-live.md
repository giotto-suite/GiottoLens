# 0013. A panel brush drag is live; its rule is set on release

- **Status:** Accepted
- **Date:** 2026-11-05
- **Supersedes:** —
- **Superseded by:** —

## Context

A drag of a panel's brush (the density rectangle, a histogram range) used to set its rule
every frame. Each frame then evaluated the rule over every cell, combined the masks,
rebuilt the selected positions and re-uploaded them to the GPU, recounted every visible
panel (the unselected totals included), and while the drag paused, encoded the mask for R.
On Mosaic's 5M-star Gaia sample, laid out as Mosaic's example (density of bp_rp x
magnitude, two histograms, the sky as the spatial view; a scripted drag in headless Chrome
on an M3 Max), a rectangle moved at 4–5 frames/s: 19.1 s of
main-thread time over a 23.6 s drag. Shares at 5M were the GPU upload of the selected
positions 28 %, histogram counts 26 %, rule evaluation 20 %, density rebin 15 %, selected
positions 7 %. At 1M it was about 30 frames/s. Mosaic's Gaia example is interactive at 5M,
from pre-aggregation rather than from a faster scan.

## Decision

While the button is down, a brush drag is a live session (`selection/live.ts`), and its
rule is set once, on release. Every per-cell result (the selection mask, the rule chips, the
selection sent to R, the scatter and pushed panels) then updates once, exactly.

- **Index.** The brushed columns' cells are ordered by bucket (1,024 a side in 2D, 16,384 in
  1D), built once per column set when the pointer enters the panel (about 60 ms at 5M,
  20 MB). A move tests only the cells in the buckets between the old and new edges. Buckets
  inside both boxes are skipped, and the edge buckets' cells are tested exactly, with the
  same inclusive test as a range rule. The counts are exact, not snapped to buckets.
- **Counts.** Every visible panel registers as a consumer: a bin per cell, and counts it
  shows. In OR mode a panel shows the other rules' cells plus the box's. Its counts start
  at the other rules' cells, and the box's cells are added where those rules do not already
  select them. In cross-filter mode a panel shows the box within the rules other than its
  own; the brushed panel itself does not change. Totals over all cells are cached per
  column (and per domain for the density panel); only the foreground is recounted.
- **Spatial view.** One layer over every cell, filtered on the GPU (`DataFilterExtension`)
  by the brushed columns, with a 0/1 category for the other rules. Its buffers upload once
  per column set. A move changes only the filter range. In OR mode the other rules' cells
  are drawn under it from positions built once at the start of the drag.

## Consequences

- Gaia, 5M, spatial cells hidden: drawing the rectangle runs at 60 frames/s; moving it runs
  at a median 17 ms frame (p90 50 ms). Main-thread time over the same drag falls from
  19.1 s to 3.1 s. At 1M: 60 frames/s, p90 17 ms. The committed selection matched R's
  evaluation of the rule in every run.
- With the spatial cells shown, drawing them is now the limit: every frame redraws every
  cell, 36 ms at 1M and about 210 ms at 5M zoomed out. That is overlap, not point count:
  zoomed out, Gaia stacks hundreds of stars on a pixel along the galactic plane, and blended
  dots on one pixel are drawn in turn. The same 5M points spread evenly over the screen
  draw in 24–33 ms. The fix is an aggregated spatial view when zoomed out, not more work
  here.
- R hears of a drag once, on release; nothing goes over the socket while it moves.
- The rule chips, the scatter panel and pushed panels follow on release, not during the drag.
- Memory per brushed column set: an `Int32` per cell (index) plus a `Float32` per cell and
  column (GPU filter values), and a byte per cell while dragging.
- A drag's cost depends on how many cells the edges sweep, not on the number of cells. A
  fast drag through a dense region still tests many cells.

## Alternatives considered

- **Mosaic-style pre-aggregated counts.** On activation, build counts per (brush bin x panel
  bin) as prefix sums; a move is a lookup. Small for a 2D brush feeding a 40-bin histogram
  (about 17 MB), but a histogram brush feeding the 256 x 256 density panel needs a table per
  brush bin of 65k bins. Counts are also snapped to the brush bins while dragging. The
  bucket index has a fixed cost per column set and stays exact.
- **The same full recompute, throttled.** At 5M one recompute is about 200 ms: a throttle
  turns the stutter into lag and does not remove it.
- **Upload a per-cell mask to the GPU each frame** rather than filter by range. That is 5 MB
  a frame at 5M, which the old selected-positions upload already showed to be the largest
  cost.
- **Float32 metadata columns** (half the memory at 10M cells). Deferred: the browser and R
  would evaluate range rules on different values, and a cell within float32 rounding of a
  range end could fall on either side (adr/0001 parity).

## References

- `selection/live.ts`; `panels/density.ts`, `panels/histogram.js` (consumers and brushes);
  `render/render.js` (the GPU-filtered layer).
- adr/0001 (rules over all cells, R parity), adr/0003 (no browser data model), adr/0012.
- Mosaic's Gaia example: https://idl.uw.edu/mosaic/examples/gaia.html
