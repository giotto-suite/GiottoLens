# GiottoAtlas — Claude Code Guide

## What this is
A static spatial biology viewer for GiottoDisk-backed data. Two R functions launch a local HTTP server and open a deck.gl + DuckDB WASM viewer in the browser with bidirectional R communication via WebSocket.

## Package structure
```
GiottoAtlas/
├── R/
│   ├── export.R      # export_manifest() — generates manifest.json from GiottoDisk stores
│   └── launch.R      # serve_atlas(), launch_atlas(), AtlasServer, AtlasViewer R6 classes
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
library(GiottoAtlas)

# Launch:
server <- serve_atlas(gpoints, gpolygons)   # starts npx serve via processx
viewer <- launch_atlas(server)               # opens browser + WebSocket
server$stop()                                # kill HTTP server (also auto-stops on session exit)
```

## Key conventions

**R side:**
- `serve_atlas()` derives all paths from `store@path` — never ask user for `artifacts_dir`
- `serve_root` = `dirname(dirname(dirname(store@path)))` (3 levels up from the data files)
- Viewer files served at `serve_root/atlas/`, parquet data at `serve_root/artifacts/`
- Always open browser to `/atlas/?ws_port=PORT` (with trailing slash — avoids serve redirect bug)
- `AtlasServer` (R6) manages the npx serve process; `AtlasViewer` (R6) manages the WebSocket
- httpuv callbacks must use `later::later()` to run in the R event loop, not inside the handler
- Capture `private` env before async callbacks: `priv <- private` then `priv$ws <- ws`

**JS side:**
- All shared state lives in `state.js` as a single exported object — mutate via `state.foo = bar`
- `loadTile()` takes an `onLoad` callback to avoid circular imports between `data.js` and `render.js`
- `panel.js` uses `setToggleCallback()` for the same reason
- DuckDB uses 3 connections: `conn` (transcripts), `overviewConn` (gene overview), `polyConn` (polygons)
- Polygon geometry: `ST_AsGeoJSON(geom)` directly — DuckDB spatial auto-promotes GeoParquet GEOMETRY columns, do NOT use `ST_GeomFromWKB()`
- Data caches: `txDirty/txBuild` and `polyDirty/polyBuild` — invalidate when tiles load/evict

## Common mistakes to avoid
- Do not use `ST_GeomFromWKB(geom)` — `geom` is already GEOMETRY type from GeoParquet metadata
- Do not open browser to `/atlas/index.html` — serve strips .html and redirects, breaking relative imports
- Do not add polygon tiles to `failed` Set — they should always retry (only 12 tiles)
- Do not run tile eviction on polygon tiles based on zoom — polygons must always stay in scope for centroid rendering
- `getFillColor` in `SolidPolygonLayer` binary format is per-triangle not per-polygon — use function accessors
- COUNT(*) from DuckDB returns int64 (BigInt in JS) — cast with `n::INTEGER` before storing in Int32Array
