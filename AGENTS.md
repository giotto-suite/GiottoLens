# GiottoLens

Interactive viewer for GiottoDisk-backed spatial data. `launch_lens()` starts an httpuv
server and opens a deck.gl viewer in the browser, with two-way communication with the R
session over a WebSocket. The `LensViewer` R6 methods are also the agent API: anything a user
can do in the browser has an R equivalent.

## Documentation map

This file is the entry point for code work: navigation, constraints, invariants. Rationale
and direction live elsewhere:

| Doc | Role |
|---|---|
| `AGENTS.md` (this file) | Code navigation, constraints, invariants. Read first when modifying code. |
| `vignettes/articles/design.Rmd` | Architecture and rationale: serving, the cell index, selection rules, the store, tile reads, the R/agent API, measurements. |
| `vignettes/articles/roadmap.Rmd` | Direction: panels, the large-data path, data delivery, images, plugins. |
| `adr/` | Architecture Decision Records: why a choice was made, what was rejected, what it costs. Dated and immutable; read before changing a decision. Format and index in `adr/README.md`. |
| `.claude/skills/giottolens-change/` | Checklist for changing the viewer or the R API (both sides, bundle, tests, docs). |
| `NEWS.md` | User-visible changes per version. Add an entry when you change behaviour, an argument or an export. |
| `README.md` | User-facing: install, quick start, R and agent API. |
| `SECURITY.md` | What the server exposes, how it is protected, how to report problems. |

When a decision looks arbitrary and you are tempted to undo it, check `adr/` first; the
alternatives were often measured. Write a new ADR when you make a call a future reader could
reasonably reverse, especially one backed by a measurement, and add the `adr/NNNN` pointer at
the code it constrains.

## Package structure

```
R/
  viewer.R     launch_lens(), LensViewer (R API), viewer registry, IDE detection, input checks
  server.R     httpuv app: static paths, Range data handler, WebSocket token/Origin
  protocol.R   message types, parsing, selection bitmasks
  rules.R      selection rules: validation, evaluation in R, summaries/code, lens_*() builders
  export.R     export_manifest(): manifest.json + cells.parquet from tile stores or spatial locations
  marks.R      cell marks for cells without polygons: user mark, bin grid fit, neighbour spacing
  metadata.R   prep_meta(), .write_metadata()
  images.R     .image_source() (the file an image is read from), .pick_images(), manifest entries
tests/testthat/   unit, server integration (websocket client), e2e (chromote)
inst/viewer-src/  Vite source (edit here, then npm run build:dev)
  main.js            bootstrap and wiring
  core/       state.js (runtime), store.ts (config + selection), persist.ts (config saved
              through R), comms.js (protocol), remote.js (R commands), constants.js
  data/       parquet.ts (reads, transfer modes, codecs), point-decode.ts, cells.ts, meta.ts,
              tiles.js, schedule.js, wkb.ts, tx-decode.ts + tx-worker.ts + tx-pool.js,
              images.ts (pixel sources per level), j2k.ts + img-worker.ts + img-pool.ts
  selection/  rules.ts (evaluate/combine/masks), geometry.ts, selection.ts (tools)
  render/     render.js, schedule.js (requestRender), colors.ts, marks.ts (cell dots and marks)
  ui/         input.js, annotations.js, panel.js, legend.js, tooltip.js, rules.js, release.js,
              dom.js, images.js
  panels/     dock.ts (dockview: slots, placement, layout), scatter.js, histogram.js,
              density.ts (2D bins as one image), spec.js (pushed Vega-Lite), controls.js
  test/       vitest (+ fixtures/)
inst/viewer/  built bundle, served at runtime: committed by CI after merge, never in PRs
inst/viewer-dev/  local build (npm run build:dev), untracked and not in the package build
adr/          decision records
dev/          development scripts, not in the package (dev/atera_images.R: until GiottoDisk's
              VRT fix, points the Atera images back at their original OME-TIFFs)
```

## Workflow

```bash
cd inst/viewer-src && npm ci && npm test && npm run typecheck && npm run build:dev
```

```r
devtools::load_all(); devtools::test()   # e2e needs Chrome and NOT_CRAN=true
viewer <- launch_lens(g); viewer$push_metadata(g, dimreds = "umap")
```

- **Branches.** Feature branches open PRs against `dev` and are deleted on merge. `dev` →
  `main` is a release: bump the version in `DESCRIPTION`. Rulesets block deleting or
  force-pushing `dev` and `main`.
- **Never commit `inst/viewer/`.** Build locally with `npm run build:dev`, which writes the
  untracked `inst/viewer-dev/`; `.viewer_dir()` serves it while it is newer than
  `inst/viewer/`. `npm run build` writes `inst/viewer/` itself (CI's build); after using it,
  `git restore inst/viewer`. A PR that changes `inst/viewer/` fails CI. After a merge into
  `dev`, CI builds it and commits it there; a release PR into `main` fails if `dev`'s bundle
  does not match its source. Installs from `dev` or `main` need no Node, and no CI writes to `main`.
- The R-CMD-check CI job cannot install the suite's dependency chain yet; test locally.

## Key invariants

### Serving (`R/server.R`)

- Nothing is copied or written next to the data. Everything is under `/lens/<token>/` (random
  per launch; any other path is a 404) and the viewer uses page-relative URLs (resolve against
  `document.baseURI`; the Vite `base` is `./`), so path-prefixing proxies work:
  - `/lens/<token>/`: bundle, from the package;
  - `.../session/`: per-viewer temp dir (manifest, `cells.parquet`, metadata, panel data),
    removed by `close()`;
  - `.../files/<layer>/`: store directories, whole files from httpuv's own thread (no R);
  - `.../data/<layer>/`: the same through `.data_response()`, Range-aware, on R's main thread;
  - `.../image/<k>`: image file k only (never its folder), through `.data_response()`;
  - `.../ws`: the WebSocket.
- httpuv `staticPath` ignores Range. Headers include `Content-Encoding: identity`
  (httpuv gzips otherwise, and fetch cannot opt out).
- Binds `127.0.0.1` on a random port. The token path is the access check for files and the
  WebSocket alike, since httpuv's static thread cannot check anything per request; the Origin
  check rejects non-loopback foreign pages and is off behind RStudio Server's proxy (adr/0006,
  `SECURITY.md`). Never serve anything outside `.lens_root(token)`.
- Tokens come from `.rand_id()` (`/dev/urandom`), never `sample()`. A store with a symlink
  leading out of it is not mounted statically: `files/` goes through `.data_response()`,
  which checks real paths (`.links_outside()`).
- Browser-supplied text printed in the console goes through `.console_text()`; strings in
  generated R code (`.rule_code()`) through `encodeString()`.
- `launch_lens()` opens RStudio's viewer pane via `getOption("viewer")`, Positron's via
  `browseURL()`, otherwise the browser (`.ide()`, `.open_viewer()`).

### Cells and selection (adr/0001, adr/0002, adr/0010)

- Cell index `i` = the cell layer's tiles concatenated in manifest order; tile rows are cells
  `offset .. offset + n - 1`. The tiles are the polygon store's, or, for a spatial unit
  without polygons, grid chunks of its spatial locations (`.build_cells_xy()`), which have no
  file. The browser holds centroids and metadata as typed arrays by index and no string IDs;
  R holds the IDs (`private$cell_ids`) and translates.
- Manifest `layers.cells`: `cells` (the table), `tiles`, `geometry` (whether tiles hold
  polygons; outlines are fetched only then), `mark` (`shape`, `size` in data units, `angle`
  in degrees: the launch mark, inferred or from `launch_lens(mark =)`) and `marks` (whether
  it is drawn by default: spatial locations yes, polygons only with a launch mark). The
  polygon store stays mounted as `data/polygons/`.
- The drawn mark is the launch mark with the config's `cellMark` on top (`drawnMark()` in
  `render/marks.ts`, `.drawn_mark()` in R; keep them the same). `cellMark` is set by
  `set_mark()` (R only: there is no browser control) and saved with the config.
- Cells are drawn by `cellMarkLayer()` (`render/marks.ts`): dots, circles sized in data units
  with a pixel minimum, or squares and hexagons (`ColumnLayer`, no pixel minimum, so dots
  until a mark is as wide as a dot). Selection is centroid membership whatever the mark.
- A selection is one rule per source (`spatial`, `scatter`, `hist:<col>`, `meta`, `panel:*`,
  `r`), combined with OR, or AND in cross-filter mode. Rules evaluate to `Uint8Array` masks
  over all cells, never only loaded tiles; masks are a cache keyed by rule object (rules are
  never mutated). Selections cross the socket as base64 bitmasks (LSB first).
- `R/rules.R` and `selection/rules.ts` implement the same evaluation; change both together
  (the e2e tests compare them). `lens_cells()` is R-only and resolves to an `ids` rule.
- Metadata is written in cell order; categorical columns as 0-based codes (-1 = NA) with levels.

### Data model (adr/0003)

- There is no browser-side data model or SQL: no DuckDB-WASM, no Mosaic. R prepares what the
  browser draws; queries beyond typed-array scans run in R (GiottoDisk picks the engine). A
  viewer with no R session is not a goal.

### Browser state

- Config and selection live in the zustand store and change only through `actions`. Renders
  follow store subscriptions through `requestRender()` (one per frame). `core/state.js` holds
  runtime data only (deck, manifest, caches, loaded tables, in-progress drawing).
- Camera moves go through `setViewState()` so tiles load. Viewport size comes from
  `#spatial-pane` (`viewportSize()`), never `window` or the canvas before deck sizes it.
- deck.gl compares `data` by reference: build binary data objects once per array (`once()` in
  `render.js`). A new object per render re-triangulates polygons and re-uploads buffers.
- The config except rules and combine mode is saved through R (`core/persist.ts`, adr/0009):
  sent on change as JSON text, kept verbatim in `private$config_json`, returned in `restore`.
  Nothing is sent before the restore, so defaults never overwrite it. Bump `CONFIG_VERSION`
  in `store.ts` and extend `migrate` when a saved field changes meaning.
- A button released outside the page (outside an IDE viewer pane) never reaches it;
  `ui/release.js` sends the missed `pointerup`/`mouseup`. Tools listen for `mouseup` on `window`.

### Protocol (`core/comms.js` ↔ `R/protocol.R`, PROTOCOL = 3)

- `{type, id?, data}`. Messages from R with an `id` are requests; the handler's return value
  comes back as `{type: 'reply', id, data | error}`; `LensViewer` private `request()` waits.
- A tab sends `ready` once its handlers are registered; R then sends the saved config
  (`restore`, always, `null` the first time), metadata, rules and pushed panels, in that order.
- Browser errors are forwarded as `client_error`, printed in the R console and kept in `log()`.
- Bump `PROTOCOL` and `.lens_protocol` together when the message format changes.

### Tiles (adr/0004, adr/0005)

- Tile reads go through `readTileColumns()` / `tileSource()` (`data/parquet.ts`) in one of two
  modes (`launch_lens(transfer =)`, manifest `transfer`): `whole` fetches `files/` in one
  request; `columns` reads the footer (64 KB first read) and the needed column blocks, merged
  when < 1 MB apart, from `data/`. `auto` starts `whole` on a localhost URL and switches
  after two whole fetches under 150 MB/s (an SSH port forward also looks like localhost).
- Transcript tiles decode in a worker pool with `data/point-decode.ts`, keeping every
  `stride`-th row (16/4/1 by zoom tier, `txStride()`) and reading only the kept dictionary
  indices. Layouts it does not cover throw `UnsupportedLayout` and fall back to hyparquet. A
  tile cached at a coarser stride is refetched on zoom-in; the transcript lasso decodes stride 1.
- A tile that leaves the view while loading is aborted (`abortTiles()`): `state.pending` maps
  each key to its `AbortController`, whose signal reaches the worker (an `abort` message),
  the request queue and `fetch`. Pass the signal through any new read on the tile path.
- Codecs: `compressors` in `data/parquet.ts` (hyparquet-compressors + hysnappy WASM): SNAPPY,
  ZSTD, GZIP, LZ4_RAW, Hadoop LZ4. BROTLI is left out (size; R's arrow cannot write it).
- `data/point-decode.ts` imports hyparquet internals (`hyparquet/src/thrift.js`,
  `encoding.js`); recheck it when bumping hyparquet.
- Polygon tiles: `geom` only, WKB to flat arrays, loaded only near outline zoom (centroids come
  from the cell table). One deck layer per tile. Every Range slice must be a 206; at most 6
  requests in flight per context.

### Images (adr/0008)

- The viewer reads `.image_source(img)` (today `@file_path`), page 1, and nothing else
  decides the file. Non-TIFF sources (a VRT, a PNG, in memory) are skipped with a message.
- Levels come from the TIFF itself (SubIFDs or COG overview IFDs), not OME-XML; Viv's
  `loadOmeTiff()` misreads Xenium's per-channel files. Levels must halve and share a tile size.
  Above 4096 px a side, a file in strips or without a pyramid is refused (`layoutProblem()`):
  Viv would read it as one tile at every zoom.
- A giottoAffineImage's `@affine` (applied as `xy %*% L + shift` to the raster's extent
  coordinates) goes to the manifest as `affine` (`.image_affine()`) and is multiplied onto
  the model matrix; the file and extent stay untransformed.
- RGB is decided from the TIFF tags (`imageKind()`: 3 or 4 samples, 8-bit, RGB or YCbCr), not
  in R. RGB images draw first with normal blending and have no colour or contrast.
- One `MultiscaleImageLayer` per shown single-channel image, additive blending, `excludeBackground` and
  `no-overlap` (overlaps would double brightness). Hidden images are left out of the layer
  list so their tiles stop loading.
- Decoding goes through `ImagePool` (`decode(fileDirectory, buffer)`); a decoder must be
  registered in `img-worker.ts`, not on the main thread. Workers are ES modules
  (`worker.format` in `vite.config.js`).
- Image state is `config.images` by name (`show`, and `color` and `contrast`, or `rgb`) plus `layers.img`;
  R's `set_image()` and `set_layer("img")` map onto it.

### Panels (adr/0009)

- Only chart panels dock (`panels/dock.ts`, dockview-core 4.13.1, pinned); the spatial view is
  not a panel. A panel's id names its slot, its selection source (`scatter` or
  `scatter:<id>`, `density` or `density:<id>`, `panel:<id>`) and its data file; never derive anything from its DOM position.
- A panel is `create(body, ctx) → { destroy, show?, view? }`. Hidden tabs keep their DOM; skip
  work while `ctx.visible()` is false (`whenVisible()` in `controls.js`) and catch up in `show()`.
- R keeps every pushed payload (`private$pushed`) until `remove_panel()` or `panel_closed`,
  and re-sends it on `ready`. Built-in panels rebuild from metadata (`refreshBuiltins()`).
- A panel's brush is drawn from its rule, not kept in the chart: the histogram redraws when
  its rule changes elsewhere, and a pushed chart's `ids` rule keeps `params.brush` (the
  extent by field) so a rebuilt chart can draw it again.

### R API (the agent API)

`LensViewer` public methods: `select()`, `set_selection()`, `rules()`, `state()`, `describe()`,
`wait_for_selection()`, `subset()`, `view_bounds()`, `set_view()`, `zoom_to()`, `color_by()`,
`set_layer()`, `set_mark()`, `set_image()`, `show_genes()`, `push_metadata()`, `push_panel()`, `remove_panel()`,
`panels()`, `push_polygons()`,
`screenshot()`, `log()`, `on()`, `send()`, `close()`. Rule builders: `lens_polygon()`,
`lens_bbox()`, `lens_range()`, `lens_categories()`, `lens_compare()`, `lens_cells()`,
`lens_union()`, `lens_intersect()`. New user-facing capability gets an R method; agent-facing helpers count as
having a consumer.

## Conventions

- R internals: `.` prefix, snake_case. Errors: `stop("[site] message", call. = FALSE)`.
- R6: a public and a private member cannot share a name.
- No `...` forwarding into GiottoClass functions that record their call with `match.call()`
  (`subsetGiotto()`); pass named arguments.
- Non-ASCII in R code fails `R CMD check`; use `\uxxxx` escapes outside comments.
- JS/TS: new modules in TypeScript; plain JS modules imported from TS need JSDoc types.
- Vitest fixtures in `inst/viewer-src/test/fixtures/` are small parquet files written by R
  (arrow or duckdb); keep them under ~500 KB.

## Common mistakes to avoid

- Opening anything but `viewer$url` (`/lens/<token>/`).
- Building absolute URLs from `location.origin`.
- Writing store state directly or calling `renderLayers()` by hand.
- Keying per-cell data by cell ID in the browser instead of the cell index.
- `getFillColor` as a binary attribute on `SolidPolygonLayer` is per vertex; use a function
  accessor for per-polygon colour.
- Waiting on status text in e2e tests; wait on state (`window.__giottolens`).
