# 0012. The density panel is drawn as one image, its rectangle as two ranges

- **Status:** Accepted
- **Date:** 2026-11-02
- **Supersedes:** —
- **Superseded by:** —

## Context

A scatter shows where cells are but not how many sit in a crowded spot, or how many of them
pass the other filters. A 2D binned panel shows both, as the histogram does for one column,
and its rectangle brush gates on two columns at once (QC, a UMAP region). Vega-Lite gives
the axes and a draggable interval brush; the question is how to draw the bins.

## Decision

Bins are counted in JS from the typed metadata arrays (`binDensity()`), 256 x 256, and
coloured by cells per bin on a log scale (viridis). With a selection, the counts are of the
foreground (cells passing the other sources in cross-filter mode, else the selection), and
bins without any are grey. They are drawn as one image on an own canvas placed under
Vega-Lite's plot area (its origin plus its padding); Vega-Lite draws only the axes and the
interval brush, with its SVG renderer, over a transparent rect that carries the scales. A
selection change repaints that canvas and does not run Vega. The rectangle is the rule
`intersect(range(x), range(y))`, source `density` (or `density:<id>`), and the brush is drawn
from it wherever it came from, as the histogram's is.

## Consequences

- Atera (170,057 cells): a selection change elsewhere, rebinning and painting included,
  takes 2.1 ms median (10 ms max); a drag of the rectangle gives a selection update every
  frame (60 of 60), no long tasks, and no blank frame (0 of 121 watched). Binning and
  painting cost about 8 ms per million cells (Node, synthetic data).
- The canvas is placed from Vega's `origin()`, `width()` and `height()` after every resize.
- R evaluates, summarises and writes code for the rectangle with no new rule kind
  (`lens_intersect(lens_range(), lens_range())`).
- Bins are 256 a side over the plot's current domains: the wheel zooms the plot (a second,
  scale-bound interval; the hand tool or Shift+drag pans) and the cells are rebinned over
  what is in view, so zooming in shows finer bins, not bigger pixels. In select mode the
  plain drag draws or moves the rectangle. Vega's event filters cannot read signals, so
  switching tools rebuilds the chart at the same zoom.

## Alternatives considered

- **Vega-Lite rect marks, one per bin:** 11.9 / 20 ms per update at 64 x 64, which loses
  most of a UMAP's structure; 256 x 256 would be up to 65k marks per redraw.
- **Vega's canvas renderer for the axes and brush:** while the rectangle was dragged,
  regions of the panel went pure black, axes and bins included, in Positron and desktop
  Chrome (GPU canvases; never in headless Chrome, which composites in software). Vega
  redraws only the changed region of its canvas on each move. With SVG it no longer
  happens; an SVG of a few axis ticks and one rectangle is cheap.
- **A Vega-Lite `image` mark fed a data URL:** 19.8 / 33 ms per update, and Vega loads each
  new URL asynchronously and draws nothing meanwhile, so the bins flashed while scrubbing.
- **A grey ramp with the foreground in blue** (the first version): low contrast between
  densities; viridis separates them and stays readable in common colour blindness.
- **A deck.gl texture with an own rectangle brush and axes:** no Vega in the loop, but the
  axes and a draggable, resizable brush written and kept by us, for an update the image
  route already does well inside a frame.

## References

`panels/density.ts`, `test/density.test.ts`; design.Rmd "Panels"; adr/0009.
