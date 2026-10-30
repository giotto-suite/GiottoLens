# GiottoLens

An interactive web viewer for [GiottoDisk](https://github.com/giotto-suite/GiottoDisk)-backed
spatial data: every cell and transcript at full resolution, linked panels, and two-way
communication with the R session, so selections come back to R and R (or an agent working in
it) can drive the viewer.

## Installation

```r
# install.packages("pak")
pak::pak("giotto-suite/GiottoLens")
```

## Quick start

```r
library(GiottoLens)

viewer <- launch_lens(g)                 # a giotto object backed by GiottoDisk tile stores
# or
viewer <- launch_lens(gpoints, gpolygons)

viewer$push_metadata(g, dimreds = "umap")   # colour-by, tooltip, scatter and histogram
viewer$selection                            # cells selected in the browser
viewer$close()
```

`launch_lens()` serves the viewer on `127.0.0.1` and a free port, under a random path that
changes every launch, and opens it in the browser or viewer pane. Treat `viewer$url` like a
password while the viewer runs (see [SECURITY.md](SECURITY.md)). Nothing is copied or written next to your data. Use `host = "0.0.0.0"` to
expose it to the network, and `url_prefix` when the browser reaches R through a proxy or port
forward (for example R on an HPC node).

## R API

```r
# Read what the user did
viewer$selection            # selected cell IDs
viewer$selection_rules      # the rules behind them (lasso, brush, histogram range, ...)
viewer$annotations          # drawn polygons as GeoJSON
viewer$log()                # recent user actions and browser errors
viewer$state()              # layers, colouring, rules, view, counts

# Drive the viewer
viewer$select(lens_polygon(ring))                 # same evaluation as the lasso
viewer$select(lens_range("nr_feats", 50, 200), source = "hist", replace = FALSE,
              combine = "and")                    # cross-filter with the current selection
viewer$set_selection(ids)
viewer$set_view(x = 500, y = -800, zoom = 2)      # or bounds = c(xmin, xmax, ymin, ymax)
viewer$color_by("leiden_clus")
viewer$set_layer("tx", show = TRUE)
viewer$show_genes(c("CD3E", "MS4A1"))
viewer$push_panel(GiottoVisuals::renderSpec(g, spec, engine = "vegalite"))
viewer$push_polygons(regions)                     # SpatVector, sf or WKT
viewer$screenshot("view.png")
```

Selection rules are evaluated in R as well as in the browser, so `viewer$select()` resolves
cells even before a browser connects, and a rule drawn in the browser gives the same cells
when evaluated in R. `lens_polygon()`, `lens_range()`, `lens_categories()` and
`lens_compare()` build rules.

## Working with an agent

The R API is also the agent API: an agent working in your R session can read and drive the
viewer without seeing the screen.

```r
viewer$describe(by = "leiden_clus")   # what is on screen and what is selected, as text
viewer$log()                          # what the user did, and any browser errors

# Ask the user to draw, then work with what they chose
sel <- viewer$wait_for_selection()    # returns once the user lassos or brushes
g_sub <- viewer$subset(g)             # the selection as a Giotto object

# Drive the view and selection
viewer$zoom_to(sel)                          # fit the view to cells
viewer$select(lens_bbox(viewer$view_bounds()))  # select what is on screen
viewer$select(lens_categories("leiden_clus", "3"))
viewer$screenshot("view.png")                # when a picture is needed
```

Rules (`lens_polygon()`, `lens_bbox()`, `lens_range()`, `lens_categories()`,
`lens_compare()`, `lens_cells()`, `lens_union()`) select the same cells whether they are
drawn in the browser or written in R. To see them:

```r
viewer$rules()              # one row per source: summary and cells it matches on its own
viewer$rules(code = TRUE)   # the lens_*() calls that recreate the selection
```

In the viewer, chips under the HUD show the same rules with their counts; × drops one,
and the toolbar's rules button hides the strip.

## Viewer

- **Cells:** centroids of every cell at all zooms (from one table loaded at start), outlines
  when zoomed in, coloured by any pushed metadata column.
- **Transcripts:** tiles loaded around the view, decoded in background workers; 1/16 and 1/4
  sampling when zoomed out; gene search and highlighting.
- **Selection:** lasso, brush (`[` `]` resize), invert, select by metadata, scatter lasso,
  histogram brush, and brushes on panels pushed from R. Sources combine as a union, or
  intersect in cross-filter mode. Selections cover all cells, not only those loaded.
- **Panels:** a scatter of any two metadata columns (UMAP by default), a histogram or bar
  chart, and Vega-Lite specs pushed from R; rows with a `cell_ID` are linked to the
  selection.
- **Annotations and measuring:** polygon, rectangle and freehand annotations (sent to R),
  ruler, and a transcript lasso that counts genes in a region.

## Architecture

```
R                                    Browser
launch_lens()                        deck.gl (OrthographicView, Y up)
  httpuv on 127.0.0.1                 zustand store: config + selection rules
  /lens/<token>/    viewer bundle     rules → masks over all cells (typed arrays)
    session/        manifest, cells,  hyparquet + own decoder, in workers
                    metadata          Vega-Lite panels (loaded on demand)
    files/          tile stores, whole
    data/           the same, by Range
    ws              WebSocket ◄────►  requests, selections, logs, errors
```

- **Self-contained:** the bundle ships in `inst/viewer/`; no CDN or internet access at runtime.
- **Cells** are numbered by concatenating polygon tiles, so the browser keeps per-cell data in
  typed arrays and exchanges selections with R as bitmasks.
- **Tiles** come whole from httpuv's own thread when the browser is on the same machine (no R
  involved, so a busy R does not stall panning), or as just the drawn columns through a
  Range handler on slow links such as SSH port forwards (`launch_lens(transfer =)`). Only the
  points the zoom level draws are decoded.

## Development

Contributors and coding agents: start with [`AGENTS.md`](AGENTS.md) (code map and
invariants). Architecture is in `vignettes/articles/design.Rmd`, direction in
`roadmap.Rmd`, and the reasons behind decisions in [`adr/`](adr/README.md).

```bash
cd inst/viewer-src
npm ci
npm test            # vitest
npm run typecheck   # tsc
npm run build       # writes inst/viewer/ — commit it
```

```r
devtools::load_all()
devtools::test()    # unit, server and end-to-end tests (end-to-end needs Chrome, NOT_CRAN=true)
```

## License

MIT
