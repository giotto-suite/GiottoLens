# GiottoAtlas Design Document

## Goals
A static, zero-infrastructure spatial biology viewer for GiottoDisk-backed data. Requirements:
- No geographic CRS — data is in local micron coordinates
- Handle 278M+ transcripts and 170k+ polygons
- Static hosting capable (S3 + one URL)
- Bidirectional R communication for annotation workflows
- No build toolchain for the viewer

## Data architecture

### Source: GiottoDisk hive-partitioned parquet
GiottoDisk stores spatial data as hive-partitioned parquet:
```
artifacts/
├── {uid}/data/source_id={uid}/tile_index={NNN}/tile_index=000/part-0.parquet
└── gene_overview/gene_overview.parquet
```

Transcripts: 858 tiles (~300k rows each). Polygons: 12 tiles (~14k each).  
Each tile has `x_index`, `y_index` (precomputed centroids), `geom` (WKB), `feat_ID` (transcripts only).

### Why parquet over .duckdb
Parquet footer contains pre-computed row group statistics and byte offsets — DuckDB reads the footer once and fetches only the relevant byte ranges via HTTP range requests. `.duckdb` files require navigating B-tree pointer chains (multiple round trips per query). The DuckDB team recommends parquet for HTTP/cloud access.

### Manifest (generated at export time)
`atlas/manifest.json` contains tile bounding boxes, URLs, gene list, and pre-computed overview data. The viewer fetches this once at startup and never re-reads it.

Pre-computed overviews (when generated):
- **All-genes density grid**: ~5850 cells at 100-micron resolution, stored inline as col/row/n arrays
- **Per-gene density**: single sorted parquet (`gene_overview.parquet`) — DuckDB uses row-group min/max stats on `feat_ID` to skip to relevant genes (1-2 range requests per gene regardless of file size)

## Coordinate system
No geographic CRS. All coordinates are in local micron space (e.g., x: 0–9888, y: 0–5957). The viewer uses deck.gl's `OrthographicView` with `COORDINATE_SYSTEM.CARTESIAN`. There is no map tile pyramid and tippecanoe/PMTiles are not used.

## DuckDB WASM architecture

Three separate connections to prevent blocking:
| Connection | Used for |
|---|---|
| `conn` | Transcript tile loads |
| `overviewConn` | Gene overview parquet queries |
| `polyConn` | Polygon tile loads + spatial extension |

The spatial extension (`INSTALL spatial; LOAD spatial;`) is loaded once on `polyConn` at startup. DuckDB's GeoParquet support auto-promotes the `geom` column to `GEOMETRY` type — use `ST_AsGeoJSON(geom)` directly, not `ST_GeomFromWKB(geom)`.

### Browser/WASM limitations
- HTTP/1.1 caps at 6 concurrent connections per host
- DuckDB WASM cannot efficiently read across hundreds of parquet files simultaneously
- Memory is limited to the browser tab (~2–4GB practical)
- Consequence: pre-compute heavy aggregations at export time; use spatial tile partitioning for bounded viewport queries

## Zoom level design

| Zoom | What renders |
|---|---|
| Any zoom | Polygon centroids (dots) — once tiles loaded |
| ≥ POLYGON_ZOOM_THRESHOLD (-0.5) | Polygon outlines replace centroids |
| ≥ TRANSCRIPT_ZOOM_THRESHOLD (0) | Transcript scatter points |
| < TRANSCRIPT_ZOOM_THRESHOLD | Overview density grid (if available) |

Polygon tiles (12 total) are always kept in scope regardless of zoom — centroids need to be visible everywhere and the 12-tile cost is negligible.

## Tile loading strategy

**Polygons:** All visible tiles loaded at startup, never evicted. 12 tiles total.

**Transcripts:** Viewport-based loading with eviction:
1. Compute viewport bounds in data coordinates
2. Filter 858 tile bounding boxes to intersecting tiles
3. Sort by distance from viewport center
4. Load up to `MAX_TRANSCRIPT_TILES=25` concurrently (transcript-only count)
5. Evict tiles that leave the viewport

## Performance caching

All expensive builds are cached with dirty flags:
- `txBuild / txDirty` — transcript position+color arrays. Rebuilt only when tiles load/evict or gene selection changes, not on pan/zoom.
- `polyBuild / polyDirty` — merged polygon arrays. Same pattern.
- `manifestOverviewBins` — computed once from manifest data, never invalidated.

These prevent `buildTranscriptData()` (O(n) over millions of points) from running on every viewport change.

## R communication architecture

### Two-step launch
```r
server <- serve_atlas(gpoints, gpolygons)  # HTTP server + file setup
viewer <- launch_atlas(server)              # browser + WebSocket
```

### HTTP server (`AtlasServer`)
Started via `processx` (background process, `cleanup = TRUE`). Runs `npx serve` from `serve_root` (the parent of `artifacts/`). Serves both parquet data and viewer HTML from one origin — no CORS boundary.

URL structure: `http://localhost:3000/artifacts/{uid}/...` for data, `http://localhost:3000/atlas/` for viewer.

### WebSocket (`AtlasViewer`)
`httpuv::startServer()` runs non-blocking via the `later` event loop — R console stays free. Callbacks use `later::later()` to run in the R event loop, not inside the httpuv handler thread.

Private env capture pattern (R6 + async):
```r
priv <- private   # capture env reference before closure
ws$onMessage(function(binary, msg) {
    priv$ws <- ws   # mutations visible via same env reference
})
```

### Message protocol
```
viewer → R:   { type: "annotation", data: { geojson: "..." } }
R → viewer:   { type: "highlight_genes", data: ["GAPDH", "TP53"] }
              { type: "color_cells",     data: { cell_id: [...], color: [...] } }
```

## Planned features

### Annotation tool
Draw polygons in the viewer (deck.gl `DrawPolygonMode` / `nebula.gl`). On completion, serialize ring coordinates as GeoJSON and send via WebSocket. R converts to `giottoPolygon` via `terra::vect()`.

### Mosaic integration
[Mosaic](https://uwdata.github.io/mosaic/) provides linked statistical views (histograms, composition charts, co-expression scatter) via a shared DuckDB coordinator. It is entirely browser-side JavaScript — no Python/Node required for end users. Add as additional script imports in `index.html`. Wire spatial selection from deck.gl to Mosaic selection predicates.

### Overview density (currently optional)
Requires re-running `export_manifest()` with the full `export.R` (including `.compute_overview()` and `.compute_gene_overviews()`). The viewer handles missing overview gracefully.

## Deployment (S3)
Single bucket, single URL prefix. Replace `url_prefix = "http://localhost:3000"` with the S3 bucket URL. CORS headers must expose `Content-Range` and `Accept-Ranges` for DuckDB range requests to work. No server-side compute required.
