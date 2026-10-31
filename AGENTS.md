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
  export.R     export_manifest(): manifest.json + cells.parquet from tile stores
  metadata.R   prep_meta(), .write_metadata()
tests/testthat/   unit, server integration (websocket client), e2e (chromote)
inst/viewer-src/  Vite source (edit here, then npm run build)
  main.js            bootstrap and wiring
  core/       state.js (runtime), store.ts (config + selection), comms.js (protocol),
              remote.js (R commands), constants.js
  data/       parquet.ts (reads, transfer modes, codecs), point-decode.ts, cells.ts, meta.ts,
              tiles.js, schedule.js, wkb.ts, tx-decode.ts + tx-worker.ts + tx-pool.js
  selection/  rules.ts (evaluate/combine/masks), geometry.ts, selection.ts (tools)
  render/     render.js, schedule.js (requestRender), colors.ts
  ui/         input.js, annotations.js, panel.js, legend.js, tooltip.js, rules.js, release.js, dom.js
  panels/     scatter.js, histogram.js, spec.js (pushed Vega-Lite), controls.js
  test/       vitest (+ fixtures/)
inst/viewer/  built bundle, served at runtime: committed by CI after merge, never in PRs
adr/          decision records
```

## Workflow

```bash
cd inst/viewer-src && npm ci && npm test && npm run typecheck && npm run build
```

```r
devtools::load_all(); devtools::test()   # e2e needs Chrome and NOT_CRAN=true
viewer <- launch_lens(g); viewer$push_metadata(g, dimreds = "umap")
```

- **Branches.** Feature branches open PRs against `dev` and are deleted on merge. `dev` →
  `main` is a release: bump the version in `DESCRIPTION`. Rulesets block deleting or
  force-pushing `dev` and `main`.
- **Never commit `inst/viewer/`.** Build it locally to test, then `git restore inst/viewer`
  before committing; a PR that changes it fails CI. After a merge, CI builds it and commits
  it on `dev` or `main`, so installs from those branches need no Node.
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

### Cells and selection (adr/0001, adr/0002)

- Cell index `i` = polygon tiles concatenated in manifest order; tile rows are cells
  `offset .. offset + n - 1`. The browser holds centroids and metadata as typed arrays by
  index and no string IDs; R holds the IDs (`private$cell_ids`) and translates.
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
- A button released outside the page (outside an IDE viewer pane) never reaches it;
  `ui/release.js` sends the missed `pointerup`/`mouseup`. Tools listen for `mouseup` on `window`.

### Protocol (`core/comms.js` ↔ `R/protocol.R`, PROTOCOL = 2)

- `{type, id?, data}`. Messages from R with an `id` are requests; the handler's return value
  comes back as `{type: 'reply', id, data | error}`; `LensViewer` private `request()` waits.
- A tab sends `ready` once its handlers are registered; R then sends metadata and rules.
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

### R API (the agent API)

`LensViewer` public methods: `select()`, `set_selection()`, `rules()`, `state()`, `describe()`,
`wait_for_selection()`, `subset()`, `view_bounds()`, `set_view()`, `zoom_to()`, `color_by()`,
`set_layer()`, `show_genes()`, `push_metadata()`, `push_panel()`, `push_polygons()`,
`screenshot()`, `log()`, `on()`, `send()`, `close()`. Rule builders: `lens_polygon()`,
`lens_bbox()`, `lens_range()`, `lens_categories()`, `lens_compare()`, `lens_cells()`,
`lens_union()`. New user-facing capability gets an R method; agent-facing helpers count as
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
