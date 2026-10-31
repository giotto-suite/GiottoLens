# GiottoLens (development version)

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
