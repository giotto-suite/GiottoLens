import * as duckdb from 'https://cdn.jsdelivr.net/npm/@duckdb/duckdb-wasm@1.29.0/+esm';
import { state } from './state.js';
import { PALETTE } from './constants.js';

// ── DuckDB init ───────────────────────────────────────────────────────────────
export async function initDB() {
  const bundle    = await duckdb.selectBundle(duckdb.getJsDelivrBundles());
  const workerUrl = URL.createObjectURL(
    new Blob([`importScripts("${bundle.mainWorker}")`], { type: 'text/javascript' })
  );
  state.db = new duckdb.AsyncDuckDB(new duckdb.VoidLogger(), new Worker(workerUrl));
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

// ── Polygon tile fetch ────────────────────────────────────────────────────────
export async function fetchPolygonTile(url) {
  if (state.spatialLoaded) {
    const tbl = await state.polyConn.query(
      `SELECT x_index, y_index, ST_AsGeoJSON(geom) AS gj FROM read_parquet('${url}')`
    );
    const polys = [], cx = [];
    for (const batch of tbl.batches) {
      const xs = batch.getChildAt(0), ys = batch.getChildAt(1), gs = batch.getChildAt(2);
      for (let i = 0; i < batch.numRows; i++) {
        cx.push(xs.get(i), ys.get(i));
        try {
          const gj   = JSON.parse(gs.get(i));
          const rings = gj.type === 'Polygon'      ? gj.coordinates
                      : gj.type === 'MultiPolygon' ? gj.coordinates[0]
                      : null;
          if (rings) polys.push({ polygon: rings });
        } catch (_) {}
      }
    }
    return { polys, centroids: new Float32Array(cx) };
  } else {
    const tbl = await state.polyConn.query(`SELECT x_index, y_index, geom FROM read_parquet('${url}')`);
    const polys = [], cx = [];
    for (const batch of tbl.batches) {
      const xs = batch.getChildAt(0), ys = batch.getChildAt(1), gs = batch.getChildAt(2);
      for (let i = 0; i < batch.numRows; i++) {
        cx.push(xs.get(i), ys.get(i));
        const raw = gs.get(i);
        let bytes = null;
        if (raw instanceof Uint8Array) bytes = raw;
        else if (raw instanceof ArrayBuffer) bytes = new Uint8Array(raw);
        else if (raw?.buffer) bytes = new Uint8Array(raw.buffer, raw.byteOffset, raw.byteLength);
        if (bytes) { const rings = decodeWKBPolygon(bytes); if (rings) polys.push({ polygon: rings }); }
      }
    }
    return { polys, centroids: new Float32Array(cx) };
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

// ── Transcript tile fetch ─────────────────────────────────────────────────────
export async function fetchTranscriptTile(url) {
  const tbl = await state.conn.query(`SELECT x_index, y_index, feat_ID FROM read_parquet('${url}')`);
  const n   = tbl.numRows;
  const pos = new Float32Array(n * 2);
  const geneIdxs = new Uint16Array(n);
  let off = 0;
  for (const batch of tbl.batches) {
    const xs = batch.getChildAt(0), ys = batch.getChildAt(1), fs = batch.getChildAt(2);
    for (let i = 0; i < batch.numRows; i++) {
      pos[off*2]    = xs.get(i);
      pos[off*2+1]  = ys.get(i);
      geneIdxs[off] = state.geneIndex.get(fs.get(i)) ?? 0;
      off++;
    }
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
      if (layerName === 'polygons')    invalidatePoly();
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
  let total = 0;
  const parts = [];
  for (const [k, entry] of state.cache) {
    if (!k.startsWith('transcripts:')) continue;
    const { pos, geneIdxs } = entry;
    let count = filtering ? 0 : geneIdxs.length;
    if (filtering)
      for (let i = 0; i < geneIdxs.length; i++)
        if (state.selectedGenes.has(geneIdxs[i])) count++;
    if (count) { parts.push({ pos, geneIdxs, count }); total += count; }
  }
  if (!total) return null;
  const outPos    = new Float32Array(total * 2);
  const outColors = new Uint8Array(total * 4);
  let off = 0;
  for (const { pos, geneIdxs } of parts) {
    for (let i = 0; i < geneIdxs.length; i++) {
      const gi = geneIdxs[i];
      if (filtering && !state.selectedGenes.has(gi)) continue;
      outPos[off*2]   = pos[i*2];
      outPos[off*2+1] = pos[i*2+1];
      const c = useColor ? PALETTE[gi % PALETTE.length] : [100, 180, 255];
      outColors[off*4] = c[0]; outColors[off*4+1] = c[1];
      outColors[off*4+2] = c[2]; outColors[off*4+3] = useColor ? 210 : 160;
      off++;
    }
  }
  return { length: total, pos: outPos, colors: outColors };
}

function buildPolygonData() {
  const polys = [], cx = [];
  for (const [k, data] of state.cache) {
    if (!k.startsWith('polygons:') || !data) continue;
    for (const p of data.polys)     polys.push(p);
    for (const v of data.centroids) cx.push(v);
  }
  if (!cx.length) return null;
  return { polys, centroids: new Float32Array(cx) };
}

function updateStatus() {
  const $s = document.getElementById('status');
  if ($s) $s.textContent = state.pending.size
    ? `loading ${state.pending.size} tile(s)…`
    : `${state.cache.size} tile(s) loaded`;
}
