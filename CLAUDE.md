# GiottoLens — Claude Code Guide

## What this is
A static spatial biology viewer for GiottoDisk-backed data. Two R functions launch a local HTTP server and open a deck.gl + DuckDB WASM viewer in the browser with bidirectional R communication via WebSocket.

## Package structure
```
GiottoLens/
├── R/
│   ├── export.R      # export_manifest() — generates manifest.json from GiottoDisk stores
│   └── launch.R      # serve_lens(), launch_lens(), LensServer, LensViewer R6 classes
├── inst/
│   └── viewer/       # ALL viewer JS/HTML files live here (not viewer/ at root)
│       ├── index.html
│       ├── main.js       # bootstrap, updateTiles, event wiring
│       ├── state.js      # single shared mutable state object
│       ├── constants.js  # zoom thresholds, palette, limits
│       ├── data.js       # DuckDB connections, tile fetching, caching
│       ├── overview.js   # density grid, gene overview queries
│       ├── render.js     # renderLayers() only
│       ├── panel.js      # gene list UI
│       └── comms.js      # WebSocket to R
└── DESCRIPTION
```

## Development workflow
```r
# After editing R files:
devtools::load_all()   # for R-only changes

# After editing inst/viewer/ JS files:
devtools::install()    # must reinstall for inst/ changes to take effect
library(GiottoLens)

# Launch:
server <- serve_lens(gpoints, gpolygons)   # starts npx serve via processx
viewer <- launch_lens(server)               # opens browser + WebSocket
server$stop()                                # kill HTTP server (also auto-stops on session exit)
```

## Key conventions

**R side:**
- `serve_lens()` derives all paths from `store@path` — never ask user for `artifacts_dir`
- `serve_root` = `dirname(dirname(dirname(store@path)))` (3 levels up from the data files)
- Viewer files served at `serve_root/lens/`, parquet data at `serve_root/artifacts/`
- Always open browser to `/lens/` — WebSocket uses `ws://${location.host}` (same origin, no ws_port param)
- `LensServer` (R6) is a config-only object (no process); `LensViewer` (R6) owns the combined httpuv server
- httpuv `staticPath` serves files in C++ — concurrent, Range-aware, never blocks R's event loop
- Direct field assignment in `onMessage` is safe — httpuv dispatches callbacks to the main R thread
- Capture `private` env before async closures: `priv <- private` then use `priv$ws <- ws`

**JS side:**
- All shared state lives in `state.js` as a single exported object — mutate via `state.foo = bar`
- `loadTile()` takes an `onLoad` callback to avoid circular imports between `data.js` and `render.js`
- `panel.js` uses `setToggleCallback()` for the same reason
- DuckDB uses 3 connections: `conn` (transcripts), `overviewConn` (gene overview), `polyConn` (polygons)
- Polygon geometry: `ST_AsGeoJSON(geom)` directly — DuckDB spatial auto-promotes GeoParquet GEOMETRY columns, do NOT use `ST_GeomFromWKB()`
- Data caches: `txDirty/txBuild` and `polyDirty/polyBuild` — invalidate when tiles load/evict

## Common mistakes to avoid
- Do not use `ST_GeomFromWKB(geom)` — `geom` is already GEOMETRY type from GeoParquet metadata
- Do not open browser to `/lens/index.html` — serve strips .html and redirects, breaking relative imports
- Do not add polygon tiles to `failed` Set — they should always retry (only 12 tiles)
- Do not run tile eviction on polygon tiles based on zoom — polygons must always stay in scope for centroid rendering
- `getFillColor` in `SolidPolygonLayer` binary format is per-triangle not per-polygon — use function accessors
- COUNT(*) from DuckDB returns int64 (BigInt in JS) — cast with `n::INTEGER` before storing in Int32Array
