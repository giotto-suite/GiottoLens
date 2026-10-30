import * as duckdb from '@duckdb/duckdb-wasm';
import duckdb_wasm from '@duckdb/duckdb-wasm/dist/duckdb-mvp.wasm?url';
import mvp_worker from '@duckdb/duckdb-wasm/dist/duckdb-browser-mvp.worker.js?url';
import { parquetReadObjects } from 'hyparquet';
import { state } from './state.js';
import { PALETTE, PALETTES } from './constants.js';

// ── DuckDB init ───────────────────────────────────────────────────────────────
export async function initDB() {
  const bundle = await duckdb.selectBundle({
    mvp: { mainModule: duckdb_wasm, mainWorker: mvp_worker }
  });
  const worker = new Worker(bundle.mainWorker);
  state.db = new duckdb.AsyncDuckDB(new duckdb.VoidLogger(), worker);
  await state.db.instantiate(bundle.mainModule, bundle.pthreadWorker);
  state.conn         = await state.db.connect(); // transcript tile loads
  state.overviewConn = await state.db.connect(); // gene overview queries
  state.polyConn     = await state.db.connect(); // polygon tile loads
  try {
    document.getElementById('status').textContent = 'loading spatial extension…';
    await state.polyConn.query('INSTALL spatial');
    await state.polyConn.query('LOAD spatial');
    state.spatialLoaded = true;
  } catch (e) {
    console.warn('Spatial extension unavailable:', e.message);
  }
}

// ── Tile visibility ───────────────────────────────────────────────────────────
export function visibleTiles(viewState, tiles) {
  const { target: [cx, cy], zoom } = viewState;
  const scale = Math.pow(2, zoom);
  const hw = (window.innerWidth  / 2) / scale;
  const hh = (window.innerHeight / 2) / scale;
  const vp = { xmin: cx - hw, xmax: cx + hw, ymin: cy - hh, ymax: cy + hh };
  return tiles.filter(t =>
    t.xmax > vp.xmin && t.xmin < vp.xmax && t.ymax > vp.ymin && t.ymin < vp.ymax
  );
}

// Disable content-encoding on all parquet fetches so browsers don't try to
// decompress raw parquet bytes as gzip (ERR_CONTENT_DECODING_FAILED).
const _RAW = { 'Accept-Encoding': 'identity' };

// ── Parquet fetch helper ──────────────────────────────────────────────────────
let _parqSeq = 0;
async function _loadParquet(url) {
  const name = `_p${++_parqSeq}`;
  const buf = new Uint8Array(await fetch(url, { headers: _RAW }).then(r => r.arrayBuffer()));
  await state.db.registerFileBuffer(name, buf);
  return name;
}
function _dropParquet(name) { state.db.dropFile(name).catch(() => {}); }

// ── Polygon tile fetch ────────────────────────────────────────────────────────
async function _fetchPoly(name, idCol) {
  const gjSel   = state.spatialLoaded ? 'ST_AsWKB(geom) AS gj' : 'geom AS gj';
  const hasId   = idCol != null;
  const selList = hasId ? `${idCol} AS _id, x_index, y_index, ${gjSel}` : `x_index, y_index, ${gjSel}`;
  const tbl     = await state.polyConn.query(`SELECT ${selList} FROM read_parquet('${name}')`);
  const polys = [], cx = [], ids = [];
  for (const batch of tbl.batches) {
    const off = hasId ? 1 : 0;
    const idB = hasId ? batch.getChildAt(0) : null;
    const xs  = batch.getChildAt(off), ys = batch.getChildAt(off + 1), gs = batch.getChildAt(off + 2);
    for (let i = 0; i < batch.numRows; i++) {
      const id = idB ? idB.get(i) : null;
      cx.push(xs.get(i), ys.get(i));
      ids.push(id);
      _parsePolyGeom(gs.get(i), id, polys);
    }
  }
  return { polys, centroids: new Float32Array(cx), ids };
}

function _parsePolyGeom(raw, id, polys) {
  let bytes = null;
  if (raw instanceof Uint8Array)  bytes = raw;
  else if (raw instanceof ArrayBuffer) bytes = new Uint8Array(raw);
  else if (raw?.buffer) bytes = new Uint8Array(raw.buffer, raw.byteOffset, raw.byteLength);
  if (bytes) { const rings = decodeWKBPolygon(bytes); if (rings) polys.push({ polygon: rings, id }); }
}

export async function fetchPolygonTile(url) {
  const name = await _loadParquet(url);
  try {
    const idCol = state.manifest?.layers?.polygons?.id_col;
    if (idCol && !state.polyIdColFailed) {
      try {
        return await _fetchPoly(name, idCol);
      } catch (_) {
        state.polyIdColFailed = true;
      }
    }
    return await _fetchPoly(name, null);
  } finally {
    _dropParquet(name);
  }
}

function decodeWKBPolygon(wkb) {
  if (!wkb || wkb.byteLength < 9) return null;
  const v = new DataView(wkb.buffer, wkb.byteOffset, wkb.byteLength);
  let off = 0;
  const le = v.getUint8(off++) === 1;
  const type = v.getUint32(off, le); off += 4;
  const baseType = type & 0xffff;
  if (type & 0x20000000) off += 4;
  if (baseType === 3) return readWKBRings(v, off, le);
  if (baseType === 6) {
    const n = v.getUint32(off, le); off += 4;
    if (!n) return null;
    off++; const st = v.getUint32(off, le) & 0xffff; off += 4;
    return st === 3 ? readWKBRings(v, off, le) : null;
  }
  return null;
}

function readWKBRings(v, off, le) {
  const nRings = v.getUint32(off, le); off += 4;
  const rings = [];
  for (let r = 0; r < nRings; r++) {
    const nPts = v.getUint32(off, le); off += 4;
    const ring = new Array(nPts);
    for (let p = 0; p < nPts; p++) {
      ring[p] = [v.getFloat64(off, le), v.getFloat64(off+8, le)]; off += 16;
    }
    rings.push(ring);
  }
  return rings.length ? rings : null;
}

// ── LZ4 decompressor for hyparquet ───────────────────────────────────────────
// Parquet LZ4 codec uses "LZ4 Hadoop" format: 4-byte BE uncompressed size +
// 4-byte BE compressed size + raw LZ4 block. hyparquet passes the full page
// bytes with no pre-stripping.
function _lz4BlockDecompress(src, dstSize) {
  const dst = new Uint8Array(dstSize);
  let si = 0, di = 0;
  while (si < src.length) {
    const tok = src[si++];
    let litLen = tok >>> 4;
    if (litLen === 15) { let x; do { x = src[si++]; litLen += x; } while (x === 255); }
    for (let k = 0; k < litLen; k++) dst[di++] = src[si++];
    if (si >= src.length) break;
    const offset = src[si] | (src[si + 1] << 8); si += 2;
    let matchLen = (tok & 0xf) + 4;
    if ((tok & 0xf) === 15) { let x; do { x = src[si++]; matchLen += x; } while (x === 255); }
    let mp = di - offset;
    for (let k = 0; k < matchLen; k++) dst[di++] = dst[mp++];
  }
  return dst;
}
const _lz4Compressors = {
  LZ4: (input, outputLength) => {
    const v = new DataView(input.buffer, input.byteOffset, input.byteLength);
    const data = v.getUint32(0, false) === outputLength ? input.subarray(8) : input;
    return _lz4BlockDecompress(data, outputLength);
  }
};

// ── Range buffer ──────────────────────────────────────────────────────────────
// asyncBufferFromUrl makes a HEAD request to get file size, which hangs in
// Positron's webview. Instead, issue a GET range request for the last 8 bytes:
// the 206 response includes Content-Range: bytes X-Y/Total, giving us the size
// without a HEAD. Falls back to full download if range requests aren't supported.
async function _rangeBuffer(url) {
  // Probe with bytes=0-0: universally supported, and the Content-Range response
  // header gives the total file size without a HEAD request or negative offset.
  const probe = await fetch(url, { headers: { Range: 'bytes=0-0', ..._RAW } });
  if (probe.status === 206) {
    const cr = probe.headers.get('content-range') ?? '';
    const byteLength = parseInt(cr.split('/')[1]);
    await probe.body?.cancel();
    if (byteLength > 0) {
      return {
        byteLength,
        slice: async (start, end) => {
          const e = end ?? byteLength;
          const rng = await fetch(url, { headers: { Range: `bytes=${start}-${e - 1}`, ..._RAW } });
          return rng.arrayBuffer();
        }
      };
    }
  }
  // Server doesn't support range requests — full download fallback
  const ab = probe.status === 200
    ? await probe.arrayBuffer()
    : await fetch(url, { headers: _RAW }).then(x => x.arrayBuffer());
  return { byteLength: ab.byteLength, slice: (s, e) => ab.slice(s, e) };
}

// ── Transcript tile fetch ─────────────────────────────────────────────────────
// Uses hyparquet with HTTP range requests — downloads only the 3 needed
// columns instead of the full ~26 MB file (which contains hundreds of gene
// expression columns). Fully parallel; bypasses DuckDB WASM entirely.
export async function fetchTranscriptTile(url) {
  const file = await _rangeBuffer(url);
  const rows = await parquetReadObjects({
    file,
    columns:     ['x_index', 'y_index', 'feat_ID'],
    compressors: _lz4Compressors,
  });
  const n = rows?.length ?? 0;
  const pos      = new Float32Array(n * 2);
  const geneIdxs = new Uint16Array(n);
  for (let i = 0; i < n; i++) {
    pos[i * 2]     = rows[i].x_index;
    pos[i * 2 + 1] = rows[i].y_index;
    geneIdxs[i]    = state.geneIndex.get(rows[i].feat_ID) ?? 0;
  }
  return { pos, geneIdxs };
}

// ── Tile loading (onLoad callback avoids circular import with render.js) ──────
export async function loadTile(layerName, tile, onLoad) {
  const key = `${layerName}:${tile.index}`;
  if (state.cache.has(key) || state.pending.has(key) || state.failed.has(key)) return;
  state.pending.add(key);
  updateStatus();
  try {
    const data = layerName === 'polygons'
      ? await fetchPolygonTile(tile.url)
      : await fetchTranscriptTile(tile.url);
    if (state.cancelled.has(key)) {
      state.cancelled.delete(key);
    } else {
      state.cache.set(key, data);
      if (layerName === 'transcripts') invalidateTx();
      if (layerName === 'polygons') {
        invalidatePoly();
        if (data?.ids) data.ids.forEach(id => { if (id != null) state.allPolyIds.add(id); });
      }
    }
  } catch (e) {
    console.warn(`Failed to load tile ${key}:`, e);
    if (layerName !== 'polygons') state.failed.add(key);
  } finally {
    state.pending.delete(key);
    updateStatus();
    onLoad(state.currentViewState);
  }
}

// ── Data caches ───────────────────────────────────────────────────────────────
export function invalidateTx()     { state.txDirty   = true; }
export function invalidatePoly()   { state.polyDirty  = true; }

export function getCachedTxData() {
  if (state.txDirty) { state.txBuild = buildTranscriptData(); state.txDirty = false; }
  return state.txBuild;
}

export function getCachedPolyData() {
  if (state.polyDirty) { state.polyBuild = buildPolygonData(); state.polyDirty = false; }
  return state.polyBuild;
}

function buildTranscriptData() {
  const filtering = state.selectedGenes.size > 0;
  const useColor  = filtering || state.colorAll;
  const stride    = [16, 4, 1, 1][Math.min(3, Math.max(0, state.txZoomTier))];
  let total = 0;
  const parts = [];
  for (const [k, entry] of state.cache) {
    if (!k.startsWith('transcripts:')) continue;
    const { pos, geneIdxs } = entry;
    let count = 0;
    for (let i = 0; i < geneIdxs.length; i += stride)
      if (!filtering || state.selectedGenes.has(geneIdxs[i])) count++;
    if (count) { parts.push({ pos, geneIdxs, count }); total += count; }
  }
  if (!total) return null;
  const outPos    = new Float32Array(total * 2);
  const outColors = new Uint8Array(total * 4);
  let off = 0;
  for (const { pos, geneIdxs } of parts) {
    for (let i = 0; i < geneIdxs.length; i += stride) {
      const gi = geneIdxs[i];
      if (filtering && !state.selectedGenes.has(gi)) continue;
      outPos[off*2]   = pos[i*2];
      outPos[off*2+1] = pos[i*2+1];
      const pal = PALETTES[state.txPaletteIdx] ?? PALETTES[0];
      const c = useColor ? pal[gi % pal.length] : [100, 180, 255];
      outColors[off*4] = c[0]; outColors[off*4+1] = c[1];
      outColors[off*4+2] = c[2]; outColors[off*4+3] = useColor ? 210 : 160;
      off++;
    }
  }
  return { length: total, pos: outPos, colors: outColors };
}

function buildPolygonData() {
  const polys = [], cx = [], ids = [];
  for (const [k, data] of state.cache) {
    if (!k.startsWith('polygons:') || !data) continue;
    for (const p of data.polys)     polys.push(p);
    for (const v of data.centroids) cx.push(v);
    for (const id of data.ids)      ids.push(id);
  }
  if (!cx.length) return null;
  return { polys, centroids: new Float32Array(cx), ids };
}

// ── Cell metadata coloring ────────────────────────────────────────────────────
// Color scale for one metadata column, shared by the spatial and scatter
// panels so a column gets the same colors wherever it is drawn.
// Categories take palette slots in first-seen order of `values`.
export function makeColorScale(values, numeric) {
  if (numeric) {
    let min = Infinity, max = -Infinity;
    for (const v of values) if (v != null) { if (v < min) min = v; if (v > max) max = v; }
    const range = max - min || 1;
    return {
      color: v => {
        if (v == null) return [80, 80, 80, 180];
        const t = Math.max(0, Math.min(1, (v - min) / range));
        return [Math.round(t*255), 0, Math.round((1-t)*255), 220];
      },
      legend: { type: 'continuous', min, max },
    };
  }
  const cats = new Map();
  for (const v of values) {
    const k = String(v ?? 'NA');
    if (!cats.has(k)) cats.set(k, PALETTE[cats.size % PALETTE.length]);
  }
  return {
    color: v => [...(cats.get(String(v ?? 'NA')) ?? [160, 160, 160]), 220],
    legend: { type: 'categorical', items: [...cats.entries()].map(([label, color]) => ({ label, color })) },
  };
}

export function isNumericMetaCol(name) {
  return state.metaCols.find(c => c.name === name)?.numeric ?? false;
}

export async function buildMetaColors() {
  if (!state.metaCol) { state.metaColors = null; state.metaLegend = null; return; }
  try {
    const rows = (await state.polyConn.query(
      `SELECT cell_ID, "${state.metaCol}" AS val FROM cell_meta`
    )).toArray();
    const scale  = makeColorScale(rows.map(r => r.val), isNumericMetaCol(state.metaCol));
    const colors = new Map();
    for (const r of rows) colors.set(r.cell_ID, scale.color(r.val));
    state.metaColors = colors;
    state.metaLegend = scale.legend;
  } catch (e) {
    console.warn('buildMetaColors failed:', e);
    state.metaColors = null;
  }
}

// Cache full cell_meta as a JS Map for instant hover lookup.
// Called once after metadata is loaded. ~170k cells × ~20 cols is a few MB.
export async function buildCellMetaCache() {
  try {
    const tbl = await state.polyConn.query(`SELECT * FROM cell_meta`);
    const colNames = tbl.schema.fields.map(f => f.name);
    const idColIdx = colNames.indexOf('cell_ID');
    if (idColIdx < 0) { state.cellMetaCache = null; return; }
    const cache = new Map();
    for (const batch of tbl.batches) {
      const cols = colNames.map((_, i) => batch.getChildAt(i));
      for (let i = 0; i < batch.numRows; i++) {
        const id = cols[idColIdx].get(i);
        if (id == null) continue;
        const row = {};
        for (let c = 0; c < colNames.length; c++) {
          if (c === idColIdx) continue;
          row[colNames[c]] = cols[c].get(i);
        }
        cache.set(id, row);
      }
    }
    state.cellMetaCache = cache;
  } catch (e) {
    console.warn('buildCellMetaCache failed:', e);
    state.cellMetaCache = null;
  }
}

function updateStatus() {
  const $s = document.getElementById('status');
  if ($s) $s.textContent = state.pending.size
    ? `loading ${state.pending.size} tile(s)…`
    : `${state.cache.size} tile(s) loaded`;
}
