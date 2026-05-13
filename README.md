# GiottoLens

An interactive web viewer for [GiottoDisk](https://github.com/drieslab/GiottoDisk)-backed spatial biology data. Renders 278M+ transcripts and 170k+ polygons at interactive frame rates using [deck.gl](https://deck.gl) and [DuckDB WASM](https://duckdb.org/docs/api/wasm/overview.html), with bidirectional R communication for annotation and selection workflows.

## Installation

```r
# install.packages("pak")
pak::pak("drieslab/GiottoLens")
```

## Quick start

```r
library(GiottoLens)

viewer <- launch_lens(gobject)          # from a giotto object
# or
viewer <- launch_lens(gpoints, gpolygons)  # from GiottoDisk stores directly
```

This starts a local HTTP + WebSocket server (default port 3000) and opens the viewer in your browser or RStudio viewer pane.

## R API

```r
viewer$selection      # character vector of selected cell IDs (updates live)
viewer$annotations    # list of drawn annotation polygons as GeoJSON strings

viewer$push_metadata(gobject)           # push cell metadata for color-by
viewer$push_metadata(gobject, cols = c("leiden_clus", "total_expr"))
viewer$push_metadata(gobject, dimreds = "umap", dims = 1:2)

viewer$close()        # stop the server
```

`push_metadata()` accepts a giotto object, a plain `data.frame`, or the output of `prep_meta()`. Column names are automatically sanitized to `[A-Za-z0-9_]` before writing.

## Viewer features

### Navigation
- **Pan** — drag to pan, scroll to zoom
- **Cursor coordinates** — live micron-space coordinates in the HUD
- **Zoom to fit** — resets view to the full dataset extent
- **Scale bar** — auto-scaling μm / mm indicator

### Layers
| Layer | When visible |
|---|---|
| Density overview | Low zoom — pre-computed 100 μm grid; updates with gene selection |
| Polygon centroids | All zooms once tiles load |
| Polygon outlines | Above polygon zoom threshold |
| Transcript scatter | Above transcript zoom threshold; LOD subsampling at low zoom (1/16, 1/4, full) |

All layers have independent visibility toggles and opacity sliders.

### Color by metadata
After calling `push_metadata()` from R, use the color-by selector in the sidebar to color polygons by any categorical or continuous column. Categorical columns get a legend; continuous columns use a gradient.

### Selection tools
- **Lasso** — freehand polygon cell selection
- **Brush** — paint to add/remove cells; `[` / `]` to resize
- **Invert** — flip selection
- **Select by metadata** — filter cells by column value via DuckDB query
- **Cross-filter mode** — spatial and UMAP/histogram selections intersect rather than replace

Selected cell IDs are available in R as `viewer$selection`.

### Annotation tools
- **Draw polygon / rectangle / freehand** — persistent named annotations
- **Annotation list** — sidebar panel; click to select, zoom-to-fit, or delete
- Selected annotation GeoJSON available as `viewer$annotations`

### Measure tools
- **Ruler** — click start and end points; distance label tracks the midpoint during pan/zoom
- **Transcript lasso** — freehand region query; bypasses LOD subsampling and queries all parquet tiles directly; shows top 50 genes by count with proportional bars

Measurements persist across tool switches and are cleared only by the measure group's clear button.

### Linked panels (stats column)
- **UMAP** — deck.gl scatter colored by current metadata column; lasso selection cross-links to spatial
- **Distribution** — vgplot histogram / bar chart; interval or toggle selection cross-links via Mosaic

## Architecture

```
R side                          Browser
──────                          ───────
launch_lens()                   deck.gl 9 (OrthographicView, Y-up)
  └─ httpuv (port 3000)         DuckDB WASM (3 connections)
      ├─ HTTP staticPath  ──►   inst/viewer/  (Vite bundle + DuckDB WASM)
      └─ WebSocket        ◄──►  comms.js  (selection, annotations)
```

- **Self-contained** — all JS and the DuckDB WASM binary are bundled into `inst/viewer/`; no CDN or internet access required at runtime
- **Data** — GiottoDisk hive-partitioned parquet tiles; DuckDB uses HTTP range requests against the parquet footer for sub-tile queries
- **Coordinates** — local micron space; `OrthographicView` with `flipY: false` (Y-up, matching GiottoDisk storage convention)
- **Manifest** — `lens/manifest.json` generated at export time contains tile bounding boxes, gene list, and pre-computed overview data; fetched once at startup

## Development

```r
# After editing R files:
devtools::load_all()
```

```bash
# After editing inst/viewer-src/ JS files:
cd inst/viewer-src
npm install       # first time only
npm run build     # outputs to inst/viewer/
```

```r
devtools::load_all()
viewer <- launch_lens(gpoints, gpolygons)
```

Commit `inst/viewer/` after rebuilding — it is the pre-built artifact that ships with the package.

## License

MIT
