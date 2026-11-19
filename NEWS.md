# GiottoLens (development version)

* Saves: `viewer$save(name)` keeps the work done in the viewer (rules, annotations, regions,
  pushed panels and metadata, column types, added images, an image registration, comparisons
  and the viewer's settings) with the snapshot shown, in the project's `lens/` folder.
  `saves()` lists them, `open_save()` opens one, `delete_save()` deletes one. The tools bar's
  save button and the start page do the same. An analysis is not saved yet. See adr/0026.
* The viewer's work is written as it happens to a working bundle in the project, and
  `close()` keeps work not saved there, to open again with `open_save()`;
  `close(discard = TRUE)` deletes it. `set_object()`, `checkout()` and `open_project()`
  refuse only work not saved.
* Work the viewer does for the page can run as jobs in a background R process that keeps the
  object shown loaded, so R and the page stay free. The jobs button in the tools bar shows how
  many are running; its popover lists them with their progress, cancels one, and keeps the
  last few finished. `viewer$jobs()` and `viewer$cancel_job()` do the same from R. The
  protocol is 7. See adr/0025.
* Hand-over snapshots are written with qs2 when it is installed, which saves several seconds
  on large objects.
* A power button next to R's connection stops the viewer, as `viewer$close()` does (click it
  twice). A page whose viewer was stopped says so and no longer tries to reconnect.
* Cross-filter mode is on by default: the selection is the cells every source selects.
  `set_selection()` still turns it off.
* The spatial view is a panel: move, split, or close it, and add it back from a `+` menu.
  The page's controls (project, the panels toggle, cross-filter, select by metadata, invert,
  clear) are in a tools bar at the left edge. R's connection, the selected count and the
  rules are in a bar along the bottom. The view no longer shows a "GiottoLens" label. With
  no spatial view open, `set_view()`, `zoom_to()`, `screenshot()` and `view_bounds()` stop
  with an error. `panels()` lists `tools` and `spatial`. See adr/0023.
* A Data panel lists what the object shown holds beyond the metadata already pushed
  (cell metadata, expression, spatial enrichments, dim reductions) and pulls the items
  queued, all at once, adding them to the metadata. `viewer$catalog()` and `viewer$pull()`
  do the same from R. Pulls run as jobs, which the panel can cancel, and add columns to the
  viewer, not the object; `pull(wait = FALSE)` returns at once with the job's id.
* Regions: `viewer$save_region()`, `regions()`, `select_region()` and `remove_region()` keep
  named sets of cells for the object shown. `viewer$compare_regions(a, b)` tests two regions,
  or one and every other cell, with `Giotto::findScranMarkers()` as a job, and docks the
  result as a volcano plot (`de_results()` returns the tables). Clicking a gene in it colors
  the cells by that gene. The Regions panel, a tab next to the Data panel, does the same.
  Saved regions count as Lens work for `set_object()`. See adr/0020.
* Color cells by one gene, enrichment or dim reduction axis without adding it to the
  metadata: the button next to "color by" opens a searchable picker, and picked items stay
  in the menu's "recent" group. `viewer$color_by()` takes a row of `catalog()` or its `key`.
  Genes share one color scale. See adr/0024.
* A cell table panel, a tab behind the histogram: one row per cell in the other sources'
  selection (all cells when there is none), one column per metadata column, with the cell
  IDs from R. Only the rows in view are drawn, so large tables scroll smoothly. Rows picked
  in it (click, ⌘/Ctrl-click to toggle, Shift-click for a range) are the `table` source's
  rule: they add to the selection, or narrow it in cross-filter mode.
  `viewer$select(lens_cells(ids), source = "table")` picks rows from R.
* A text column whose values are all numbers can be shown as a continuous scale
  (`set_column_type()` and the "treat as" menu).
* `viewer$analysis()` opens an Analysis panel for the object shown, also offered in the "+"
  menu. Its Preprocessing tab runs Giotto's first steps (QC filter to cell-type labels) and
  reruns only the steps a change affects; further analyses (spatial interactions, spatial
  genes, co-expression modules, niches, interaction-changed genes, markers between groups)
  are added from a dialog. Steps run as jobs and nothing runs until asked. Results come back
  as metadata columns beside pulled ones, docked charts and tables; a gene clicked in a table
  colors the cells. Finished runs are kept under History. See adr/0021 and adr/0022.
* Pushed charts: an interval param named `range` sends its extent to R (`panel_pick`).
* Preferences: `lens_preferences()` and the viewer's Preferences dialog (the gear in the tools bar)
  set defaults for every viewer: sequential and divergent palettes, the scale style and the
  expression scale's style, category and transcript palettes, the background, cell outlines and fill, the
  expression values the picker opens on and region comparisons read, the column cells are
  colored by at launch, and an analysis's threads, history length and network folder. Only
  preferences that are set are saved, so the others follow the installed defaults; launch
  arguments, R options and changes made in a viewer take precedence.
* Continuous color scales take Giotto's options: `viewer$set_color_scale(style =)`
  `"divergent"` (the default, as in Giotto's plots: centered on `midpoint`, default the
  median) or `"sequential"`, `midpoint =` and `limits =` (values beyond take the end colors;
  `NA` for automatic). The default colors are Giotto's: divergent blue, white, red;
  sequential viridis. Divergent presets `RdBu`, `PuOr` and `PRGn` are added; the 7-color
  scale that was `blue-white-red` is `RdBu`, and `blue-white-red` is Giotto's three colors.
  The legend has a style menu and low, mid and high handles on the bar (double-click: back
  to automatic). Scales saved before keep their look.
* `viewer$add_image(file, type = )` adds a TIFF after launch: shown, listed in the images and
  register panels, and opened again by reloads and new tabs. `type = "if"` or `"he"` places
  it inside the data's extent, to register by landmarks; `"xenium"` reads a 10x Xenium
  morphology image with Giotto's Xenium reader and places it in microns. The images panel
  has an "add image" button: a choice of type, then a file dialog R opens (option
  `GiottoLens.choose_file` replaces it). Added images belong to the object shown and count
  as Lens work for `set_object()`.
* `viewer$set_object(g)` shows another object in the same viewer: the URL stays and open tabs
  reload. The new object starts from a clean slate. If the current object has rules,
  annotations or pushed panels, it stops and names them unless `discard = TRUE`. See
  adr/0017.
* `launch_lens()` without an object starts an empty viewer, to be filled with `set_object()`.
* A giotto object is shown from a GiottoDisk snapshot in its project: the one it matches, or
  a new `lens_<date>_<time>` snapshot (`keep = FALSE`). An object not in a project needs
  `launch_lens(g, project = <dir>)`, which writes it into one. An object with disk data not
  saved in its project is refused until saved with `g <- saveGiotto(g)`. See adr/0018.
* `viewer$gobject()` returns the object shown, and `viewer$checkout(name)` shows another
  snapshot of the project as it was saved, without a new save.
* A start page on a viewer without an object: open a GiottoDisk project from the recent
  ones, a path or (in RStudio) a folder dialog, and open one of its snapshots. The
  tools bar's project button shows it over the page. Unkept automatic saves are hidden
  behind a toggle. `viewer$open_project(path)` and `launch_lens(project = path)` start on
  it; switching asks before dropping Lens work. See adr/0019.
* Untiled point and polygon stores are read as one tile, up to 50,000 polygons and 2,000,000
  points (`options(GiottoLens.untiled_max = )`).
* The camera is kept across reloads (`state()$config$view`), and selected genes are saved by
  name (`state()$config$genes`, was positions).
* Launching from giottoPoints / giottoPolygon layers instead of a giotto object is deprecated.
* Protocol 6: `ready` carries the page's load, R sends `reload`, and the page asks R with
  `ask`, answered with `answer`.

* The selection color can be set: `viewer$set_selection_color("#00e5ff")`, or the
  `selection_color` preference for every viewer; `NULL` goes back to the preference (yellow
  unless set). It is part of the saved config (`state()$config$selectionColor`).
* A light theme for the panels and controls: `viewer$set_theme("light")`. The spatial view
  and scatter plots stay dark. The theme is part of the saved config (`state()$config$theme`).
* Opening a panel group's "+" menu closes any other one that is open.
* After `select()`, a selection the page sent before it had R's rules no longer replaces
  them in R for a moment: `rules()` and `selection` right after `select()` are R's. New
  fields `seq` (`set_rule`) and `r_seq` (`cell_selection`), and outbound type `rule_seq`.
* Cell outline color, width and opacity can be set: `viewer$set_outline(color =, width =,
  alpha =)` from R, or the "outlines" section of the cells panel (color picker, hex field,
  preset colors, width slider and number box, opacity slider, reset). Selected cells draw in
  the selection color, 1 px wider than the outline width. The width ranges from 0.01 to
  20 px; the width slider is on a log scale. The settings are part of the saved config
  (`state()$config$outline`).
* Cells colored by a categorical column fill at 90% opacity by default (was 43%), and cell
  outlines are black at 80% opacity by default (was white at 78%).
* The legend of a categorical color-by column in the cells panel is editable: per category,
  a checkbox turns its color on or off, the swatch opens a color picker, and a slider sets its
  fill opacity. Double-clicking a label draws that category at full opacity and the others at
  20%; "all on", "all off" and "reset" act on every category.
  `viewer$style_categories(column =, colors =, show =, alpha =, reset =)` sets the same from
  R; `alpha = c(0.2, Myeloid = 1)` sets every category to 0.2 and Myeloid to 1. Centroids
  draw at twice the fill opacity, capped at 1. Styles are kept per column and are part of the
  saved config (`state()$config$categoryStyles`).
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
  viridis, magma, inferno, plasma, cividis, turbo, gray, blue-white-red),
  reversed, or a custom scale of 2 to 9 colors edited in the cells panel legend.
  `viewer$set_color_scale(column =, preset =, colors =, reverse =, reset =)` sets the same
  from R. Scales are kept per column and are part of the saved config
  (`state()$config$colorScales`).
* The scatter panel releases its WebGL context when it is rebuilt.
* `push_metadata()` keeps the previous push's metadata files and deletes older ones.
* The side panel is gone: its sections dock as panels in a column beside the charts (cells,
  transcripts, images, register, annotations and layers, the old opacity section). They can be
  moved, tabbed, closed and added back from the `+` menu, and `push_panel(ref = "cells")`
  places a chart next to them. A closed control stays closed after a reload.
* `viewer$panels()` lists panels in layout order, and a chart pushed without `ref` goes next to
  the charts.
* An annotation's zoom button no longer zooms the view far out after the view was moved by
  hand.

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
