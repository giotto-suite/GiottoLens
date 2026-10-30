# GiottoLens — Claude Code Guide

## What this is
A spatial viewer for GiottoDisk-backed data. `launch_lens()` starts an httpuv server and opens a
deck.gl viewer in the browser, with two-way R communication over a WebSocket. The R6 `LensViewer`
methods are also the agent API: anything a user can do in the browser has an R equivalent.

Plans: `vignettes/articles/state_selection.md` and `plugins.md` (branch
`docs/state-selection-plan`), `data_delivery.md` (branch `docs/data-delivery-plan`).

## npm dependencies (pinned in `inst/viewer-src/package.json`)
| Package | Version | Use |
|---|---|---|
| `deck.gl` | 9.3.2 | rendering |
| `@luma.gl/core` / `engine` / `webgl` | 9.3.3 | deck.gl peers |
| `hyparquet` | 1.25.8 | all parquet reads (tiles, cells, metadata, panels) |
| `hyparquet-compressors` / `hysnappy` | 1.1.2 / 1.1.1 | ZSTD, GZIP, LZ4; WASM SNAPPY |
| `zustand` | 5.0.16 | store |
| `vega` / `vega-lite` / `vega-embed` | 6.4.0 / 6.5.0 / 7.3.0 | histogram and pushed panels, loaded on demand |
| `lucide` | 1.14.0 | icons |
| `split.js` | 1.6.5 | layout |
| dev: `vite` 5.4.0, `vitest` 2.1.9, `typescript` 5.9.3 | | build, tests, typecheck |

Codecs: `compressors` in `data/parquet.ts` (hyparquet-compressors + hysnappy WASM): SNAPPY,
ZSTD, GZIP, LZ4_RAW, Hadoop LZ4. BROTLI is left out on purpose (size; R's arrow cannot
write it).

`data/point-decode.ts` imports hyparquet internals (`hyparquet/src/thrift.js`, `encoding.js`);
recheck it when bumping hyparquet.

No DuckDB-WASM and no Mosaic: both were removed (state_selection.md steps 4 and 8).

## Package structure
```
R/
  viewer.R     launch_lens(), LensViewer (R API), viewer registry, input checks
  server.R     httpuv app: static paths, Range-aware data handler, WS token/Origin
  protocol.R   message types, parsing, selection bitmasks
  rules.R      selection rules: validation, evaluation in R, lens_*() builders
  export.R     export_manifest(): manifest.json + cells.parquet from tile stores
  metadata.R   prep_meta(), .write_metadata()
tests/testthat/  unit, server integration (websocket client), e2e (chromote)
inst/viewer-src/  Vite source (edit here, then npm run build)
  main.js            bootstrap and wiring
  core/   state.js (runtime), store.ts (config + selection), comms.js (protocol),
          remote.js (R commands), constants.js
  data/   parquet.ts (Range reader), cells.ts, meta.ts, tiles.js, schedule.js,
          wkb.ts, tx-decode.ts + tx-worker.ts + tx-pool.js (transcript workers)
  selection/  rules.ts (evaluate/combine/masks), geometry.ts, selection.ts (tools)
  render/ render.js, schedule.js (requestRender), colors.ts
  ui/     input.js (tools), annotations.js, panel.js, legend.js, tooltip.js, dom.js
  panels/ scatter.js, histogram.js, spec.js (pushed Vega-Lite), controls.js
  test/   vitest
inst/viewer/  built bundle — committed, served at runtime
```

## Workflow
```bash
cd inst/viewer-src && npm ci && npm test && npm run typecheck && npm run build
```
```r
devtools::load_all(); devtools::test()   # e2e needs Chrome and NOT_CRAN=true
viewer <- launch_lens(g); viewer$push_metadata(g, dimreds = "umap")
```
**Commit `inst/viewer/` after rebuilding.** CI checks it matches a fresh build.

## Key conventions

**Serving (R/server.R):**
- Nothing is copied or written next to the data. All URLs are under `/lens/` and the viewer
  uses page-relative URLs, so path-prefixing proxies work:
  `/lens/` bundle (from the package), `/lens/session/` per-viewer temp dir (manifest,
  `cells.parquet`, metadata, panel data; removed by `close()`), `/lens/data/<layer>/` store
  directories through `.data_response()` (Range, R main thread), and `/lens/files/<layer>/`
  the same files whole from httpuv's own thread (no R).
- httpuv `staticPath` **ignores Range**. `.data_response()` answers single ranges with 206 on
  R's main thread. Headers include `Content-Encoding: identity` (httpuv gzips otherwise).
- Binds `127.0.0.1` on a random port. The WebSocket needs the per-launch `?token=`; the Origin
  check only rejects non-loopback foreign pages.

**Cells and selection:**
- Cell index `i` = polygon tiles concatenated in manifest order; tile rows are cells
  `offset .. offset + n - 1`. The browser holds centroids and metadata as typed arrays by
  index; R holds the IDs (`private$cell_ids`) and translates.
- A selection is one rule per source (`spatial`, `scatter`, `hist:<col>`, `meta`, `panel:*`,
  `r`), combined with OR, or AND in cross-filter mode. Rules evaluate to `Uint8Array` masks
  over all cells, never only loaded tiles. Selections cross the socket as base64 bitmasks.
- `R/rules.R` and `selection/rules.ts` implement the same evaluation; keep them in step (the
  e2e tests compare them).
- Metadata is written in cell order; categorical columns as 0-based codes (-1 = NA) with levels.

**Browser state:**
- Config and selection live in the zustand store and change only through `actions`. Renders
  follow store subscriptions through `requestRender()` (one per frame). `core/state.js` holds
  runtime data only (deck, manifest, caches, loaded tables, in-progress drawing).
- Camera moves go through `setViewState()` so tiles load. Viewport size comes from
  `#spatial-pane` (`viewportSize()`), never `window` or the canvas before deck sizes it.
- deck.gl compares `data` by reference: build binary data objects once per array (`once()` in
  render.js). A new object per render re-triangulates polygons and re-uploads buffers.

**Protocol (core/comms.js ↔ R/protocol.R, PROTOCOL = 2):**
- `{type, id?, data}`. Messages from R with an `id` are requests; the handler's return value
  comes back as `{type: 'reply', id, data | error}`. `LensViewer$request()` waits for it.
- A tab sends `ready` once its handlers are registered; R then sends metadata and rules.
- Browser errors are forwarded as `client_error` and printed in the R console.

**Tiles:**
- Tile reads go through `readTileColumns()` (data/parquet.ts), in one of two modes
  (`launch_lens(transfer =)`, manifest `transfer`): `whole` fetches the file from `/lens/files/`
  in one request with no R involved; `columns` reads the footer (64 KB first read) and the
  needed column blocks, merged when < 1 MB apart, from `/lens/data/` (~2 requests per tile).
  `auto` starts `whole` on a localhost URL and switches to `columns` after two slow
  (< 150 MB/s) whole fetches, since an SSH port forward also looks like localhost.
  Measured (Atera, 10 tx tiles + outlines): whole 0.9 s with R free or busy; columns 1.0 s,
  but ≥ 2.8 s while R is busy (every request waits for R's main thread).
- Transcript tiles decode in a worker pool with `data/point-decode.ts`: x, y, gene straight
  into typed arrays, keeping every `stride`-th row (16/4/1 by zoom tier, `txStride()`),
  reading only the kept dictionary indices; gene names map once per dictionary entry.
  2.6× faster than hyparquet for all rows, 3.4× at 1/16, identical output (Atera, 7.1M
  rows). Unsupported layouts throw `UnsupportedLayout` and fall back to hyparquet. A tile
  cached at a coarser stride is refetched on zoom-in; the transcript lasso always decodes
  stride 1. After this, zoomed-out loads are bound by bytes moved (whole tiles: 28 MB each),
  not decoding: the next gain is a pre-sampled coarse tier or lean tiles.
- One deck layer per transcript tile. Polygon tiles: `geom`
  only, WKB to flat arrays, loaded only near outline zoom (centroids come from the cell table).
- Every Range slice must be a 206; at most 6 requests in flight per context.

**Input:** a button released outside the page (e.g. outside Positron's viewer pane, an
embedded frame) never reaches it; deck.gl then keeps panning on the next move.
`ui/release.js` sends the missed `pointerup`/`mouseup` when a move arrives with no button
down during a drag, or on blur. Tools listen for `mouseup` on `window`, so they end too.

## Common mistakes to avoid
- Do not open `/lens/index.html`; open `viewer$url` (`/lens/?token=…`).
- Do not build absolute URLs from `location.origin`; resolve against `document.baseURI`.
- Do not write store state directly or call `renderLayers()` by hand; use actions and `requestRender()`.
- Do not key per-cell data by cell ID in the browser; use the cell index.
- `getFillColor` in `SolidPolygonLayer` binary data is per vertex as an attribute; use a function accessor for per-polygon colour.
