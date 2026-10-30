// Tile fetching, decoding and the per-layer caches.
import { state } from '../core/state.js';
import { store } from '../core/store.ts';
import { PALETTES } from '../core/constants.js';
import { readTileColumns } from './parquet.ts';
import { decodePolygons } from './wkb.ts';

// ── Tile visibility ───────────────────────────────────────────────────────────
// `size`: the spatial view in CSS pixels (ui/dom.js viewportSize())
export function visibleTiles(viewState, tiles, { width, height }) {
  const { target: [cx, cy], zoom } = viewState;
  const scale = Math.pow(2, zoom);
  const hw = (width  / 2) / scale;
  const hh = (height / 2) / scale;
  const vp = { xmin: cx - hw, xmax: cx + hw, ymin: cy - hh, ymax: cy + hh };
  return tiles.filter(t =>
    t.xmax > vp.xmin && t.xmin < vp.xmax && t.ymax > vp.ymin && t.ymin < vp.ymax
  );
}

// ── Polygon tile ──────────────────────────────────────────────────────────────
// Outlines as flat arrays for deck.gl binary layers. Row r of the tile is cell
// `tile.offset + r` (data/cells.ts), so no ID lookup is needed to colour or
// select it.
export async function fetchPolygonTile(tile) {
  const cols = await readTileColumns(tile, ['geom']);
  const polys = decodePolygons(cols.geom ?? []);
  return { ...polys, offset: tile.offset ?? 0 };
}

// ── Transcript tile ───────────────────────────────────────────────────────────
// Fetched and decoded in workers (data/tx-pool.js)
export { GENE_UNKNOWN } from './tx-decode.ts';
import { GENE_UNKNOWN } from './tx-decode.ts';
import { fetchTranscriptTile } from './tx-pool.js';
export { fetchTranscriptTile };

// ── Tile loading (onLoad callback avoids circular import with schedule.js) ────
// A transcript tile that failed is retried after this long
const RETRY_MS = 10000;

// Transcript points are decoded at the sampling stride the zoom tier needs;
// a tile cached at a coarser stride is fetched again when the view zooms in.
export const TX_STRIDES = [16, 4, 1, 1];
export const txStride = () => TX_STRIDES[Math.min(3, Math.max(0, state.txZoomTier))];

export async function loadTile(layerName, tile, onLoad) {
  const key = `${layerName}:${tile.index}`;
  const stride = layerName === 'transcripts' ? txStride() : 1;
  const cached = state.cache.get(key);
  if ((cached && !(cached.stride > stride)) || state.pending.has(key)) return;
  if (Date.now() - (state.failed.get(key) ?? -Infinity) < RETRY_MS) return;
  state.pending.add(key);
  updateStatus();
  try {
    const data = layerName === 'polygons'
      ? await fetchPolygonTile(tile)
      : await fetchTranscriptTile(tile, stride);
    if (state.cancelled.has(key)) {
      state.cancelled.delete(key);
    } else {
      state.cache.set(key, data);
    }
  } catch (e) {
    console.warn(`Failed to load tile ${key}:`, e);
    // Polygon tiles are few and always retried
    if (layerName !== 'polygons') state.failed.set(key, Date.now());
  } finally {
    state.pending.delete(key);
    updateStatus();
    onLoad(state.currentViewState);
  }
}

// ── Transcript draw buffers ───────────────────────────────────────────────────
// One buffer per tile, rebuilt only when its inputs change (gene selection,
// palette, colour-all, zoom tier). A tile arriving costs only its own points,
// and deck.gl keeps the other tiles' GPU buffers.
let _drawKey = '';
export function invalidateTx() {
  const { genes, colorAll, txPalette } = store.getState();
  _drawKey = `${genes.join(',')}|${colorAll}|${txPalette}|${state.txZoomTier}`;
}

export function txDrawTiles() {
  const out = [];
  for (const [k, entry] of state.cache) {
    if (!k.startsWith('transcripts:')) continue;
    if (entry.drawKey !== _drawKey) {
      entry.draw = buildTileDraw(entry);
      entry.drawKey = _drawKey;
    }
    if (entry.draw) out.push({ key: k, ...entry.draw });
  }
  return out;
}

function buildTileDraw({ pos, geneIdxs, stride: tileStride = 1 }) {
  const { genes, colorAll, txPalette } = store.getState();
  const selected  = new Set(genes);
  const filtering = selected.size > 0;
  const useColor  = filtering || colorAll;
  const pal       = PALETTES[txPalette] ?? PALETTES[0];
  // Tiles may hold finer samples than the current tier needs (decoded when
  // zoomed in); thin them to the tier
  const stride    = Math.max(1, Math.round(txStride() / tileStride));
  let count = 0;
  for (let i = 0; i < geneIdxs.length; i += stride)
    if (!filtering || selected.has(geneIdxs[i])) count++;
  if (!count) return null;
  const outPos    = new Float32Array(count * 2);
  const outColors = new Uint8Array(count * 4);
  let off = 0;
  for (let i = 0; i < geneIdxs.length; i += stride) {
    const gi = geneIdxs[i];
    if (filtering && !selected.has(gi)) continue;
    outPos[off * 2]     = pos[i * 2];
    outPos[off * 2 + 1] = pos[i * 2 + 1];
    const c = !useColor ? [100, 180, 255] : gi === GENE_UNKNOWN ? [128, 128, 128] : pal[gi % pal.length];
    outColors[off * 4] = c[0]; outColors[off * 4 + 1] = c[1];
    outColors[off * 4 + 2] = c[2]; outColors[off * 4 + 3] = useColor ? 210 : 160;
    off++;
  }
  return { length: count, pos: outPos, colors: outColors };
}

function updateStatus() {
  const $s = document.getElementById('status');
  if ($s) $s.textContent = state.pending.size
    ? `loading ${state.pending.size} tile(s)…`
    : `${state.cache.size} tile(s) loaded`;
}
