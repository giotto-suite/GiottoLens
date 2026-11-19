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
  projects.R   opening projects: path check, snapshot list, default keys, recent projects,
               the IDE folder dialog (adr/0019)
  metadata.R   prep_meta(), .write_metadata()
  catalog.R    what the object shown can pull (.lens_catalog()) and the plan for one
               spatValues() call over it (.pull_items(), .pull_plan()); item keys
               (.item_key(), .parse_item_key(), adr/0024)
  jobs.R       jobs: the viewer's mirai daemon holding the object shown, its helpers
               (.jw_object(), .jw_run(), .lens_progress()), adr/0025
  regions.R    region names, the comparison job (.region_de()), its expression source
               (.de_source()) and volcano spec (.de_volcano()), adr/0020
  analysis.R   LensAnalysis (step keys rooted at the snapshot, the poll loop over jobs through
               .AnalysisWorker, results to the viewer), the daemon side (.aw_*), adr/0021
  analysis-*.R the analysis steps and catalog: parameters, menu choices, run/result (adr/0022)
  images.R     .image_source() (the file an image is read from), .pick_images(), manifest entries,
               .tiff_info() (a TIFF's size, layout and pyramid from its header, base R)
  registration.R  registration_update parsing, registration_matrix(), write_registration(),
               Xenium Explorer CSVs, .registered_image() (giottoAffineImage)
tests/testthat/   unit, server integration (websocket client), e2e (chromote)
inst/viewer-src/  Vite source (edit here, then npm run build:dev)
  main.js            bootstrap and wiring
  core/       state.js (runtime), store.ts (config + selection), persist.ts (config saved
              through R), comms.js (protocol), remote.js (R commands), constants.js
  data/       parquet.ts (reads, transfer modes, codecs), point-decode.ts, cells.ts, meta.ts,
              catalog.ts (the object's sources, fetched once), items.ts (item keys, the
              item cache, fields: a column or an item),
              tiles.js, schedule.js, wkb.ts, tx-decode.ts + tx-worker.ts + tx-pool.js,
              images.ts (pixel sources per level), j2k.ts + img-worker.ts + img-pool.ts,
              registration.ts (affines, landmark fit, flips and turns)
  selection/  rules.ts (evaluate/combine/masks), geometry.ts, selection.ts (tools),
              live.ts (panel brush drags: bucket index, live counts, adr/0013)
  render/     render.js, schedule.js (requestRender), colors.ts, marks.ts (cell dots and marks),
              landmarks.ts (registration pairs)
  spatial/    view.ts (the spatial view panel: its DOM, Deck and camera), current.ts
              (spatialView(): the open view, or null)
  ui/         input.js (a view's tools), annotations.js (name popup, sync to R), tooltip.js,
              rules.js, selbar.js (selection bar), release.js, dom.js, registration.ts
              (landmark tool, image pane), start.ts (start page and project dialog, through askR()),
              jobs.ts (the tools bar's jobs button and popover; the page's list of jobs)
  panels/     dock.ts (dockview: panel types, slots, placement, layout), tools.ts (tools bar),
              scatter.js, histogram.js,
              density.ts (2D bins as one image), table.ts (the cell table), spec.js (pushed
              Vega-Lite), controls.js (chart
              control bar); controls: cells.ts (colour by, legend), transcripts.ts (genes),
              data.ts (the Data panel: what to pull from the object, through askR()),
              regions.ts (the Regions panel; regions-model.ts its helpers),
              analysis.js + analysis-model.ts (the Analysis panel),
              picker.ts (the popover a field picks a column or an item with), images.ts,
              register.ts, annotations.ts, layers.ts (layer visibility, opacity)
  test/       vitest (+ fixtures/)
inst/viewer/  built bundle, served at runtime: committed by CI after merge, never in PRs
inst/viewer-dev/  local build (npm run build:dev), untracked and not in the package build
adr/          decision records
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
  - `.../session/`: per-viewer temp dir (manifest, `cells-<load>.parquet`, metadata, panel
    data), removed by `close()`. A file whose name stays across loads (the manifest) is
    fetched with `cache: 'no-store'`;
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

### Objects in a session (adr/0017)

- The server outlives the object: `launch_lens()` and `set_object()` both go through
  `private$load()` (`load_empty()` for none). The stores and images served are in
  `private$routes`, read per request; never capture them in a closure.
- Everything that belongs to the object shown is reset by `load()` through `clear_object()`
  (config, rules, combine, pushed panels and their files, metadata and its files, column
  types, annotations, registration, `cells_xy`) or set by it (cell IDs, cell table, routes,
  the catalog).
  A new per-object field goes there, or a switch leaks it into the next object. Nothing is
  kept for an object not shown: keeping Lens work is a save's job.
- A giotto object is shown from a snapshot in its project (adr/0018): `handover()` runs
  first in `load()`, so a refusal changes nothing. The project follows the object
  (`g@source`); `project` is only for an object not in one. Never let a hand-over save move
  data: check `GiottoDisk::sourceContains(src, g)` before `snapshotSave()`. Layers and
  images are worked out again from the object as saved.
- Untiled geometry stores are one tile (`.store_tiles()`); `.check_tile_store()` caps them
  (`.lens_untiled_max`, measured; update the comment when re-measuring).
- `set_object()` refuses to drop work (`lens_work()`: rules, annotations, pushed panels,
  registration; settings alone are not counted) without `discard = TRUE`, and checks before
  changing anything. A switch from the page will go through the same argument after the
  page's own confirmation; never add a second rule there.

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
  `r`), combined with AND (cross-filter, the default in both `store.ts` and R), or OR. Rules evaluate to `Uint8Array` masks
  over all cells, never only loaded tiles; masks are a cache keyed by rule object (rules are
  never mutated). Selections cross the socket as base64 bitmasks (LSB first).
- The cell table's rows are the other sources' selection (`maskExcept()`), never its own
  rule, so picking rows does not change them; its picks are an `ids` rule (source `table`,
  or `table:<id>`). It asks R for the IDs of the rows in view only (`cell_ids`, at most
  5000): the page keeps them for display, bounded, and keys nothing by them.
- `R/rules.R` and `selection/rules.ts` implement the same evaluation; change both together
  (the e2e tests compare them). `lens_cells()` is R-only and resolves to an `ids` rule.
- Metadata is written in cell order; categorical columns as 0-based codes (-1 = NA) with levels.
  One parquet file per column (`session/metadata/<column>-<md5>.parquet`, column `value`),
  named by content; the payload gives each column its `url`. The files are the only copy: R
  keeps the payload (`cached_meta`) and reads columns through `private$meta_column()`; never
  hold the pushed data.frame. Files of the current and the previous payload are kept.
- Pulled columns (`pull()`, the Data panel) and items come from one `spatValues()` call
  (`.plan_values()`) run as a job over the daemon's object, never `gobject()` on the main
  thread. The `item` and `pull` asks answer when their job ends (`ask()` returns NULL and
  calls `reply`); asks for an item being read share its job (`need_item()`). Pulled columns
  are added to the payload (`.merge_meta()`); `push_metadata()` replaces it. A pull names a dim reduction axis
  `<reduction>_<axis>`, as `prep_meta()` does; `columnFor()` in `data/catalog.ts` names
  columns the same way, so change both together. Payload entries are read with `$`, which
  partial-matches: no new field may start with an existing one's name (`number_text`, not
  `numeric_text`).
- A field that shows one value (store `colorBy`) holds a metadata column name or an item
  key (adr/0024): `@` and slot, feature type, source name, method and item, percent-encoded
  and joined by `/`. `.item_key()` (R) and `itemKey()` (`data/items.ts`) write the same
  string; change both together (the tests check one key on each side). Items never enter
  the metadata: R reads one into `session/items/` once per object (`read_item()`, cleared by
  `clear_object()`), and the page keeps them in its item cache (128 MB, least recently used
  out, the colour-by item pinned). Read a field's values with `fieldColumn()` /
  `needFields()`, which take either. Expression items share one colour scale
  (`scaleKey()`). `color_by()` reads an item before its request, so the page does not ask
  back while R waits.
- In the browser `state.metaInfo` lists every column and `state.meta` holds the loaded ones.
  Code that needs a column's values asks for it (`needColumns()`, `metaColumn()` in
  `data/meta.ts`) and works once it has loaded; lists of columns (menus, kinds) read
  `state.metaInfo`. Rules wait for their columns before evaluating (`recompute()`).

### Data model (adr/0003)

- There is no browser-side data model or SQL: no DuckDB-WASM, no Mosaic. R prepares what the
  browser draws; queries beyond typed-array scans run in R (GiottoDisk picks the engine). A
  viewer with no R session is not a goal.

### Browser state

- Config and selection live in the zustand store and change only through `actions`. Renders
  follow store subscriptions through `requestRender()` (one per frame). `core/state.js` holds
  runtime data only (manifest, caches, loaded tables, in-progress drawing).
- The spatial view is a panel that can be closed (adr/0023): its Deck, camera, canvas and
  overlays are on the view `spatialView()` returns (`spatial/current.ts`), never on `state`
  and never found by id. Code that draws, moves the camera or reads the view does nothing
  without one; R commands that need one call `needView()`, which throws.
- Camera moves go through `setViewState()` so tiles load. Viewport size comes from the view's
  pane (`viewportSize(view)`, 0 x 0 until it is laid out), never `window` or the canvas before
  deck sizes it. A view starts (fits or takes the saved camera) at its first size.
- deck.gl compares `data` by reference: build binary data objects once per array (`once()` in
  `render.js`). A new object per render re-triangulates polygons and re-uploads buffers.
- Selected genes are saved by name and the camera (`view`) in data coordinates; a saved view
  replaces the fitted one when the config is restored (a reload of the same object).
- The config except rules and combine mode is saved through R (`core/persist.ts`, adr/0009):
  sent on change as JSON text, kept verbatim in `private$config_json`, returned in `restore`.
  Nothing is sent before the restore, so defaults never overwrite it. Bump `CONFIG_VERSION`
  in `store.ts` and extend `migrate` when a saved field changes meaning.
- A button released outside the page (outside an IDE viewer pane) never reaches it;
  `ui/release.js` sends the missed `pointerup`/`mouseup`. Tools listen for `mouseup` on `window`.

### Jobs (adr/0025)

- Work R does for the page that takes more than a moment runs as a job: private
  `start_job(label, fun, args, apply, ref, on_end, progress)` (or `run_job()` to wait),
  never on the main thread. `fun(g, ...)` runs in the viewer's mirai daemon over the object
  shown, which the daemon loads from the project path and snapshot name once and keeps
  (`cleanup = FALSE`); `apply()` runs on the main thread, and only if the object shown has not
  changed (`load_seq`). `load()` cancels running jobs; `close()` stops the daemon.
- The daemon runs installed packages only: `fun` and the helpers run there as plain functions
  (`.job_fun()`), calling packages by `pkg::`. arrow loads first (`.job_packages`). Never
  `library()` in a job.
- A job writes to the project's vault (the daemon's artifact dump); never a temp source.
- Cancelling interrupts (`stop_mirai()`, dispatcher on); a cancel rejects the job's promise
  like an error, so it is told apart by the job's own flag.

### Analysis (adr/0021, adr/0022)

- `viewer$analysis()` makes the `LensAnalysis` of the object shown (`private$lens_analysis`),
  or the page does with `analysis_open` when the Analysis panel opens. Nothing runs until a
  step is run or a parameter set (`started`). `clear_object()` closes it; `lens_work()` counts
  it once a step has run.
- Steps run as jobs: `.AnalysisWorker` gives the poll loop (`tick()`) `call()`/`read()` over
  `start_job()`. Daemon-side functions (`.aw_*`) take the held object first and keep the
  analysis in the daemon's `.lens_a`: the base object (the snapshot with the analysis's unit
  and type active), the step cache by key (capped by `GiottoLens.analysis_cache_mb`) and
  spatial networks. `.aw_init()` sets it up before the first job, and again when a step finds
  it gone (`lens_missing_input`).
- Step keys are a step's parameters and its input's key, rooted at `snapshot:<tag>`
  (`step_keys()`). A gene from a result table is an item key whose `method` is
  `analysis:<hash of the step key>`; `need_item()` asks the analysis for its job
  (`item_job()`, `.aw_item()`), so its values never change under its key.
- The analysis's metadata columns go through `own_columns("analysis", df)`: they replace its
  previous columns beside pushed and pulled ones, and rules on dropped columns go.
- Step `run()`/`result()` run in the daemon with globalenv as their environment: they call
  packages with `::` and the `.lens_*` helpers `.aw_init()` assigns (`.aw_helpers()`), never
  package internals. `view()` and `pick()` run on the main thread. Progress is the job's
  (`.lens_progress()`, and a progressr handler for Giotto's `with_pbar()`).
- Spatial networks: `.lens_network()` keys a network by an md5 of the sorted cell IDs, their
  coordinates and the network settings, keeps it in the daemon and writes it to
  `network_dir`. A step using another step's network includes that step's key and waits for
  it (`network_dep()`).
- The analysis's spatial unit and feature type are active on its base object; steps call
  Giotto without `spat_unit`/`feat_type`.
- Parameter types `values` and `spatial_network` are menus `LensAnalysis` fills
  (`values_schema()`, `network_schema()`; sent as `type = "choice"`). Steps read them with
  `.lens_values(p)` (`.values_of()`) and `.lens_net(p)` (`.network_of()`), which also take
  the value from the nearest step above. Result names of the Preprocessing steps come from
  `.lens_names()` (`.pre_names()`); the viewer gets the cluster and cell type column names
  in `analysis_markers` (`columns`).

### Protocol (`core/comms.js` ↔ `R/protocol.R`, PROTOCOL = 7)

- `{type, id?, data}`. Messages from R with an `id` are requests; the handler's return value
  comes back as `{type: 'reply', id, data | error}`; `LensViewer` private `request()` waits.
- The other way, the page asks R with `askR(op, args)`: `{type: 'ask', id, data: {op, ...}}`,
  answered to that page only as `{type: 'answer', data: {id, data | error, code}}` (private
  `answer()` / `ask()`). The start page's ops: `projects`, `browse`, `snapshots`, `open`
  (adr/0019); the Data panel's `catalog`, `pull`, and the item cache's `item`, answered only to a page showing the
  current load (`.lens_object_ops`). The cell table's: `cell_ids` (also refused to a page on an
  earlier load). The Regions panel's `region` (save, remove, select, compare; a compare
  answered when its job ends) is too. An ask is never queued while disconnected.
- A tab sends `ready` once its handlers are registered; R then sends the saved config
  (`restore`, always, `null` the first time), metadata, rules and pushed panels, in that order.
- `ready` carries the load the page's manifest came from (`setHello()`). R tells a tab with an
  older load to `reload`, and drops `.lens_object_types` messages from a tab that has not
  reloaded since the last `set_object()` (adr/0017).
- Browser errors are forwarded as `client_error`, printed in the R console and kept in `log()`.
- Jobs: R broadcasts `job` `{id, label, ref, state, message?, progress?}` as each starts, reports
  progress and ends (`running`, `done`, `error`, `cancelled`), and sends the running ones to a
  tab on `ready`; the page cancels one with the `cancel_job` ask. The page keeps the running
  jobs and the last few finished ones (`ui/jobs.ts`), shown in the tools bar's jobs popover
  only, never the status line.
- `close()` sends `closed` to every tab before stopping; a page that has it stops
  reconnecting (status `closed`). The page's stop button sends `close`, which R handles on
  the next `later` turn, never inside the server's own callback.
- Bump `PROTOCOL` and `.lens_protocol` together when the message format changes.
- R numbers its rule changes: `set_rule` carries `seq` (`rule_message()`; a re-send keeps
  the number), and a connecting tab with no rules to re-send gets `rule_seq`. A
  `cell_selection` reports the latest `seq` its selection was computed with (`r_seq`); R
  drops one older than its count, which would otherwise undo `select()`. Never send a
  clearing `set_rule` on connect: the page may hold rules R has not heard of yet.

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
- `.image_entries()` returns `sources` (the image's own file, used for `registered_image()`)
  beside the served `files`.
- `launch_lens(image_files =)` entries have `place: 'fit'`: drawn inside the manifest extent
  (`fitPlacement()`), not at their extent.
- Image state is `config.images` by name (`show`, and `color` and `contrast`, or `rgb`) plus `layers.img`;
  R's `set_image()` and `set_layer("img")` map onto it.

### Image registration (adr/0014)

- `config.registration` (saved with the config): `image`, `reference`, `base` (pixels to data
  before a fit), `landmarks` (`moving` in image pixels, `fixed` in data coordinates), `orient`
  (pixels to the image's pane: flips and quarter turns, display only), `preview`, `link`. The
  image draws with `currentTransform()`: the least-squares affine from three complete pairs,
  else `base`.
- In mode `landmark` the spatial pane has class `registering`: a second Deck (the view's
  `regDeck`, on `el.regCanvas`, finalized with the view) on the left half draws only the image, in `orient` coordinates; the main
  canvas takes the right half and `viewportSize()` halves its width. The main view leaves the
  image out unless `preview`. `render/landmarks.ts` draws each pane's own points (draggable)
  and, with a fit, the other pane's points mapped through it. `link` moves either pane with
  the other through the fit (`onMainView()`, `paneViewChange()`).
- Affines are `[a, b, c, d, e, f]` (x' = a x + b y + c) in the browser and 3 x 3 matrices on
  column vectors in R. GiottoClass applies an image's `@affine` as `xy %*% m[1:2, 1:2]`, so
  `.registered_image()` passes the transposed linear part.
- Every registration change is sent as `registration_update` (debounced) and kept as
  `LensViewer$registration`; `set_registration` (R to viewer) starts, loads (`fixed_ref` and
  `alignment` in reference pixels) or resets it.
- A click in one pane places that side of a pair, a click in the other its partner, in either
  order; a click that ends a pan or a drag places nothing. A pane does not pan while the
  pointer is over one of its points; a drag starts after 4 px. Delete removes the open or last
  pair, Escape the open one.

### Panels (adr/0009, adr/0016, adr/0023)

- Everything but the selection bar docks (`panels/dock.ts`, dockview-core 4.13.1, pinned).
  Built-in kinds are listed once in `TYPES`: charts (`meta`) need metadata and can repeat;
  `single` panels are one per viewer with their kind as id and are left closed after a reload
  once closed (`closedPanels`); controls are single panels with a `slot`, placed in a column at
  the dock's right edge (at most two tabs each: more do not fit). `spatial` is single and
  closable; `tools` is `fixed` (no close, not in the `+` menus). `placeFixed()` adds either to
  a layout without them. Keep `.lens_builtin_panels` in R in step. A pushed panel without
  `ref` goes next to the charts, never beside a single panel.
- The tools bar is one or two columns wide (`TOOLS_WIDTH`, `TOOLS_MAX`, the icon grid in
  `index.html`) and keeps its width (`holdTools()`): dockview shares a removed group's width
  evenly along its row and splits a group with a new neighbour. Nothing docks into its
  group, and the bar never becomes a tab of another (refused in `onWillShowOverlay` and
  `onWillDrop`, since a group lock still shows drop targets). Its group has low layout
  priority through dockview's private `_priority`; recheck these when bumping dockview.
- The selection bar (`ui/selbar.js`, `ui/rules.js`, static markup with ids in `index.html`,
  outside the dock) shows R's connection with the stop button (`close`; also on the start
  page, `initRStatus()`), the page's selection (the rules toggle, the count
  with a fixed minimum width, the rule chips) and the status line. Keep buttons out of it
  after the count, since they would move as the count changes. The actions on the selection (combine mode, select by
  metadata, invert, clear) are the tools bar's (`panels/tools.ts`). Tools that act in a view
  stay in the view.
- A control builds its own DOM and keeps references to it: no `getElementById`, no ids, no
  markup in `index.html`, styles by class; e2e tests select `[data-panel=<id>] .class`. A tab's
  content is mounted when first shown (`dock_tab()` in the tests) and leaves the document when
  closed, so nothing may look it up from outside.
- A panel's id names its slot, its selection source (`scatter` or
  `scatter:<id>`, `density` or `density:<id>`, `panel:<id>`) and its data file; never derive anything from its DOM position.
- A panel is `create(body, ctx) → { destroy, show?, view? }`. Hidden tabs keep their DOM; skip
  work while `ctx.visible()` is false (`whenVisible()` in `controls.js`) and catch up in `show()`.
- R keeps every pushed payload (`private$pushed`) until `remove_panel()` or `panel_closed`,
  and re-sends it on `ready`. Built-in panels rebuild from metadata (`refreshBuiltins()`).
- A panel's brush is drawn from its rule, not kept in the chart: the histogram redraws when
  its rule changes elsewhere, and a pushed chart's `ids` rule keeps `params.brush` (the
  extent by field) so a rebuilt chart can draw it again.
- A pushed spec's point param named `pick` sends the clicked row's fields to R
  (`panel_pick`, not the click that ends a drag). R acts on picks of a panel it knows: a
  comparison's volcano plot colours that page's cells by the gene's item key.
- A range or rectangle brush drag is live (adr/0013): `beginLive`/`moveLive` while the
  button is down, the rule set once on release. Panels that show counts register with
  `addLiveConsumer()` (a bin per cell) and cache their totals over all cells; never set a
  rule per frame of a drag. The spatial view draws the drag as one GPU-filtered layer.

### R API (the agent API)

`LensViewer` public methods: `select()`, `set_selection()`, `rules()`, `state()`, `describe()`,
`wait_for_selection()`, `subset()`, `view_bounds()`, `set_view()`, `zoom_to()`, `color_by()`,
`set_layer()`, `set_mark()`, `set_theme()`, `set_image()`, `register_image()`, `clear_registration()`,
`registered_image()`, `add_registered_image()`, `show_genes()`, `push_metadata()`, `catalog()`, `pull()`,
`push_panel()`, `remove_panel()`, `jobs()`, `cancel_job()`, `save_region()`, `regions()`,
`select_region()`, `remove_region()`, `compare_regions()`, `de_results()`,
`panels()`, `push_polygons()`,
`analysis()`, `screenshot()`, `log()`, `on()`, `send()`, `close()`. Rule builders: `lens_polygon()`,
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
