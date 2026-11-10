# GiottoLens (development version)

* Integer metadata columns are continuous by default (before, categorical), like double
  columns; factor, character and logical columns stay categorical. Any numeric column can be
  shown as categories, one per distinct value (at most 1000), with the "treat as" menu in the
  cells panel or `viewer$set_column_type(column, "categorical")`, and back with
  `"continuous"`. Rules on the column are dropped when its type changes; the setting is kept
  for later `push_metadata()` calls unless `cols` sets the column's type. A kept setting on a
  column with more than 1000 distinct values is dropped with a warning. New inbound message
  type `set_column_type`.
* `push_metadata()` keeps no copy of the metadata in R: R reads columns from the viewer's
  metadata files when it needs them.
* Metadata is one file per column. The viewer loads a column when it is used, and the rest
  in the background while all columns fit 256 MB; above that the tooltip shows the loaded
  columns. A type change rewrites one column, and columns that did not change stay loaded
  after a new push. The message format changed (protocol 4).
* Continuous color-by columns can use other color scales: presets (blue-red, the default;
  viridis, magma, inferno, plasma, cividis, turbo, gray, blue-white-red), reversed, or a
  custom scale of 2 to 9 colors edited in the cells panel legend.
  `viewer$set_color_scale(column =, preset =, colors =, reverse =, reset =)` sets the same
  from R. Scales are kept per column and are part of the saved config
  (`state()$config$colorScales`).
* The side panel is gone: its sections dock as panels in a column beside the charts (cells,
  transcripts, images, register, annotations and layers, the old opacity section). They can be
  moved, tabbed, closed and added back from the `+` menu, and `push_panel(ref = "cells")`
  places a chart next to them. A closed control stays closed after a reload.
* `viewer$panels()` lists panels in layout order, and a chart pushed without `ref` goes next to
  the charts.

# GiottoLens 0.1.5

* Panels dock beside the spatial view as tabs and splits that can be dragged around, closed,
  and added back from the `+` menu.
* `viewer$push_panel()` takes `id`, `where` (`"tab"`, `"right"`, `"below"`) and `ref`, and
  returns the panel's id; pushing to an existing id replaces that chart. The `pane` argument
  is gone. `viewer$remove_panel()` and `viewer$panels()` are new.
* Reloading the page keeps the panels, layers, images, colouring, genes and annotations, and
  a restored or R-set brush can still be dragged.
* Cells without polygons (Visium spots, VisiumHD bins, centroid-only cells) launch with
  `launch_lens(g, spat_unit =)` and get metadata, selection and panels without a GiottoDisk
  store.
* Such cells are drawn as dots zoomed out and as marks at their true size zoomed in: squares
  fitted to the bin grid, otherwise circles. `launch_lens(mark =)` and `viewer$set_mark()` set
  the shape, size or angle; segmented cells can show a mark before their outlines load.
* A density panel (from the `+` menu) bins two metadata columns and selects with a draggable
  rectangle, which R sets with `lens_intersect(lens_range(), lens_range())` and source
  `"density"`.
* Dragging a density rectangle or a histogram range stays smooth at millions of cells; the
  selection is set and sent to R on release.
* Holding Space or dragging with the middle button pans the spatial view and the scatter
  panel with any tool, without interrupting a ruler or polygon in progress. Histogram ranges
  and the density rectangle take the left button only.
* Image registration by landmarks: `viewer$register_image(image, reference)` (or Register in
  the side panel) shows the image in its own pane beside the reference. Matching points fit a
  least-squares affine from three pairs, with each pair's residual and the RMSE.
* `viewer$registration` holds the result: `registration_matrix()` and `write_registration()`
  (Xenium Explorer `imagealignment.csv` and `keypoints.csv`) export it,
  `viewer$register_image(alignment =, keypoints =)` loads one, and
  `viewer$add_registered_image(g)` adds the image to a giotto object as a `giottoAffineImage`.
* `launch_lens(image_files =)` shows image files that are not in the object yet, drawn inside
  the data's extent until registered.
* `viewer$set_view(zoom =)`, `viewer$set_view(bounds =)`, `viewer$zoom_to()` and an
  annotation's zoom button now apply after the view was zoomed by hand.

# GiottoLens 0.1.4

* Image support added:
  * Compatibility for pyramidal OME-TIFF (Xenium's JPEG-2000 files) and COG.
  * Affine transformed images are supported.
  * `launch_lens(images =)` picks which images to include, and `viewer$set_image()` shows,
    hides, colours or sets the contrast of one from R.
  * An image that cannot be read by tile (not a TIFF, or large and stored without tiles or a
    pyramid) is skipped with a message rather than loaded whole.

# GiottoLens 0.1.3

* Lasso and brush strokes work the same in both combine modes: a plain stroke replaces the
  view's selection, Shift adds to it, and Alt (Option) or Ctrl/Cmd subtracts from it. Before,
  strokes added in "or" mode while the lassos replaced in cross-filter mode.
* `lens_intersect()` combines rules by intersection; `rules(code = TRUE)` uses it for
  subtracted regions.
* Brushing a histogram updates the selection as the brush moves; before, it only updated
  once the brush stopped.
* The status line shows "ready" again once the viewer has loaded; since 0.1.2 it showed a
  tile count instead.

# GiottoLens 0.1.2

* The viewer is served under a random path that changes every launch (`viewer$url`), and the
  server answers nothing outside it. Other users of a shared machine can no longer read the
  data being shown through the viewer's port. The path's token comes from the operating
  system's random source, so `set.seed()` no longer makes it predictable, and launching no
  longer changes your random number stream. See `SECURITY.md`.
* `viewer$rules(code = TRUE)` quotes and escapes column names and labels, so the code it
  prints cannot run anything else when labels contain quotes.
* Tiles that leave the view while loading stop downloading, so panning quickly fills the new
  view sooner, most noticeably over a slow connection (#1).

# GiottoLens 0.1.1

* Tiles written with ZSTD, GZIP or LZ4 compression now load; before, only SNAPPY did
  (GiottoDisk's Xenium zarr converter writes ZSTD). SNAPPY decoding is faster (#2).
* Charts pushed with `viewer$push_panel()` fit their pane, axis labels and titles included (#3).

# GiottoLens 0.1.0

## Breaking changes

* `launch_lens()` serves on `127.0.0.1` and a random port by default (`host`, `port`); the
  `clean` argument is gone. Open the viewer with `viewer$url`, which carries a session token.
* `export_manifest()` no longer takes `serve_root` or `url_prefix`; tile URLs are relative.
* The density overview is not shown until R writes overview data again.

## New features

* Selections are rules that cover all cells, evaluated the same way in the browser and in R:
  `viewer$select()`, `viewer$rules()`, and the `lens_*()` builders.
* An R API for driving and reading the viewer, including from an agent: `state()`,
  `describe()`, `wait_for_selection()`, `subset()`, `set_view()`, `zoom_to()`, `color_by()`,
  `screenshot()`, `log()`.
* `viewer$push_panel()` shows a Vega-Lite spec linked to the selection.
* Faster loading: all cells on screen at once, tiles decoded in background workers, and no
  DuckDB-WASM (bundle 43 MB to 2.3 MB). Opens in RStudio's viewer pane.
