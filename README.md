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
# or cells from spatial locations alone (spots, bins), drawn as fitted squares or circles
viewer <- launch_lens(g, spat_unit = "bin008", feat_type = NULL)

viewer$push_metadata(g, dimreds = "umap")   # colour-by, tooltip, scatter and histogram
viewer$selection                            # cells selected in the browser
viewer$close()                              # work not saved stays in the project
```

`launch_lens()` serves the viewer on `127.0.0.1` and a free port, under a random path that
changes every launch, and opens it in the browser or viewer pane. One window shows the viewer
at a time: another window that opens `viewer$url` shows a code and waits until you type that
code in the first window or run `viewer$allow(code)`; in a script, after
`launch_lens(open = FALSE)`, run `viewer$allow()` before opening the URL. Set
`options(GiottoLens.viewer = "browser")` to open in the system's default browser. Keep `viewer$url` to yourself while the viewer runs
(see [SECURITY.md](SECURITY.md)). The project folder is never served, only the stores the viewer mounts. Use `host = "0.0.0.0"` to
expose it to the network, and `url_prefix` when the browser reaches R through a proxy or port
forward (for example R on an HPC node).

## R API

```r
# What the viewer shows: a snapshot of a GiottoDisk project
viewer$save("tumor_regions")        # the work in the viewer, with the snapshot shown
viewer$saves(); viewer$open_save("tumor_regions")
viewer$set_object(g)                # another object; refuses to drop work not saved without discard = TRUE
g <- viewer$gobject()               # the object shown, loaded from its snapshot
viewer$checkout("clustered")        # another snapshot of the project
viewer$open_project("~/proj")       # the project's start page; name = "clustered" opens one

# Read what the user did
viewer$selection            # selected cell IDs
viewer$selection_rules      # the rules behind them (lasso, brush, histogram range, ...)
viewer$annotations          # drawn shapes as GeoJSON, by name
viewer$log()                # recent user actions and browser errors
viewer$state()              # layers, colouring, rules, view, counts

# Drive the viewer
viewer$select(lens_polygon(ring))                 # same evaluation as the lasso
viewer$select(lens_range("nr_feats", 50, 200), source = "hist", replace = FALSE,
              combine = "and")                    # cross-filter with the current selection
viewer$set_selection(ids)
viewer$set_view(x = 500, y = -800, zoom = 2)      # or bounds = c(xmin, xmax, ymin, ymax)
viewer$color_by("leiden_clus")
cat <- viewer$catalog()
viewer$color_by(cat[cat$item == "CD3E" & cat$name %in% "normalized", ])
                                                  # one gene, not added to the metadata
viewer$set_outline(color = "black", width = 2, alpha = 1)  # cell outline color, width (px), opacity
viewer$set_selection_color("#00e5ff")             # selected cells' color; NULL: the preference
viewer$set_theme("light")                         # light panels; the spatial view stays dark
viewer$style_categories(colors = c(Myeloid = "#d62728"),   # per-category color, on/off, fill opacity
                        alpha = c(0.2, Myeloid = 1))
viewer$set_column_type("leiden_clus", "categorical")       # numeric column shown as categories
viewer$catalog()                                  # what the object holds that can be pulled
viewer$pull(c("CD3E", "leiden_clus"), types = list(leiden_clus = "categorical"))
                                                  # adds them to the metadata; or rows of catalog()
viewer$select(lens_cells(ids), source = "table")  # pick rows in the cell table
viewer$save_region("tumor")                       # the selection, saved under a name; regions() lists them
de <- viewer$compare_regions("tumor", "stroma")   # scran t-test as a job, docked as a volcano plot;
                                                  # b = NULL: every other cell
viewer$set_color_scale("nr_feats", style = "sequential", preset = "viridis")  # Giotto's styles:
viewer$set_color_scale("nr_feats", style = "divergent", midpoint = 100,      # divergent (default)
                       limits = c(0, 500))                                   # or sequential
viewer$set_color_scale("nr_feats", colors = c("black", "red", "yellow"))  # custom colors
viewer$set_layer("tx", show = TRUE)
viewer$set_mark(shape = "circle", size = 55)      # how cells are drawn zoomed in; set_mark() resets
viewer$set_image("18s", show = TRUE, color = "red", contrast = c(0, 3000))
viewer$add_image("he.ome.tif", type = "he")       # a TIFF added after launch, to register
viewer$register_image("he", reference = "dapi")   # landmark tool; result in viewer$registration
write_registration(viewer$registration, "align")  # Xenium Explorer imagealignment.csv, keypoints.csv
g <- viewer$add_registered_image(g)                # the registered image as a giottoAffineImage
viewer$show_genes(c("CD3E", "MS4A1"))
viewer$push_panel(GiottoVisuals::renderSpec(g, spec, engine = "vegalite"),
                  where = "right")                # a docked panel; returns its id
viewer$panels()                                   # what is docked, and where
viewer$remove_panel("panel-1")
viewer$push_polygons(regions)                     # SpatVector, sf or WKT
viewer$screenshot("view.png")

# An analysis of the object shown: Giotto's first steps with a panel per parameter, and more
a <- viewer$analysis(analyses = c("interactions", "niches"))   # opens the Analysis panel
a$set("leiden", resolution = 0.5)                 # reruns Leiden and the steps below it
a$run("niches")                                   # runs an added analysis
a$code()                                          # the Giotto calls, as R code

# Preferences: defaults for every viewer (also the gear in the tools bar)
lens_preferences()                                # every preference; attr "set": those set
lens_preferences(seq_palette = "magma", cat_palette = "okabe_ito")
lens_preferences(seq_palette = NULL)              # back to the built-in default
lens_preferences(reset = TRUE)
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
viewer$jobs()                         # work running in the background; cancel_job(id) stops one
viewer$allow(4089)                    # give the viewer to the waiting window that shows this code
viewer$allow()                        # none waiting: the next window to open the URL gets it

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
`lens_compare()`, `lens_cells()`, `lens_union()`, `lens_intersect()`) select the same cells whether they are
drawn in the browser or written in R. To see them:

```r
viewer$rules()              # one row per source: summary and cells it matches on its own
viewer$rules(code = TRUE)   # the lens_*() calls that recreate the selection
```

In the viewer, chips in the selection bar along the bottom show the same rules with their
counts; × drops one, and the bar's rules button hides them.

## Viewer

- **Cells:** centroids of every cell at all zooms (from one table loaded at start), outlines
  when zoomed in, coloured by any pushed metadata column. Cells without polygons (spots,
  bins) grow from dots into circles or squares at their true size as you zoom in.
- **Transcripts:** tiles loaded around the view, decoded in background workers; 1/16 and 1/4
  sampling when zoomed out; gene search and highlighting.
- **Selection:** lasso, brush (`[` `]` resize), invert, select by metadata, scatter lasso,
  histogram brush, and brushes on panels pushed from R. A lasso or brush stroke replaces its
  view's selection; Shift adds to it, Alt (Option) or Ctrl/Cmd subtracts from it, and × on
  its rule drops it. Sources intersect in cross-filter mode (the default), or combine as a
  union.
  Selections cover all cells, not only those loaded.
- **Images:** the object's images under the cells, each from its own TIFF file by tile
  (pyramidal OME-TIFF, including Xenium's JPEG-2000, and COG). Single-channel images have a
  colour and contrast each and add up like the channels of one image; RGB images (H&E) are
  recognised from the file and drawn in their own colours beneath them. "add image" in the
  images panel picks a TIFF in a file dialog R opens (IF, H&E, or a 10x Xenium image placed
  in microns).
- **Registration:** landmark pairs between an image (such as an H&E from
  `launch_lens(image_files =)`) and a reference image (DAPI), with flips and quarter turns, a
  live least-squares affine fit and per-pair residuals; saved as Xenium Explorer CSVs or added
  to the giotto object.
- **Panels:** a scatter of any two metadata columns (UMAP by default), a histogram or bar
  chart, and Vega-Lite specs pushed from R; rows with a `cell_ID` are linked to the
  selection.
- **Regions:** the Regions panel saves the selection under a name and compares two regions,
  or one and every other cell, by differential expression; clicking a gene in the volcano
  plot colors the cells by it.
- **Annotations and measuring:** annotations drawn as polygons, rectangles or freehand,
  named and sent to R, each able to select the cells inside it; ruler, and a transcript lasso that counts genes in a region.
- **Layout:** the spatial view, the charts and the controls are panels. Drag a tab to move
  or split one, × closes it, and `+` adds one, including a closed spatial view. The tools bar
  at the left edge holds the project dialog, the panels toggle and the selection's actions.
  The bar along the bottom holds R's connection, the selected count and the rules.

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
    image/<k>       image files,      Viv layers; JPEG-2000 decoded in
                    by Range          workers (OpenJPEG WASM)
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
npm run build:dev   # writes inst/viewer-dev/ (untracked), which load_all() serves while it is
                    # newer than inst/viewer/; CI builds and commits inst/viewer/ after merge
```

```r
devtools::load_all()
devtools::test()    # unit, server and end-to-end tests (end-to-end needs Chrome, NOT_CRAN=true)
```

## License

MIT
