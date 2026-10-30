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
