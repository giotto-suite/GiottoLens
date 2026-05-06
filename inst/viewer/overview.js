import { state } from './state.js';

// ── Colour ramp ───────────────────────────────────────────────────────────────
export function densityColor(t) {
  const stops = [[8,15,60],[0,80,180],[0,190,160],[120,210,0],[255,200,0],[255,80,0],[180,0,0]];
  const s = t * (stops.length - 1);
  const lo = Math.floor(s), hi = Math.min(lo + 1, stops.length - 1), f = s - lo;
  return stops[lo].map((v, i) => Math.round(v + f * (stops[hi][i] - v)));
}

export function pctile(arr, p) {
  const s = Float64Array.from(arr).sort();
  return s[Math.min(Math.floor(s.length * p), s.length - 1)];
}

// Pack centers + colors with a stable index array for deck.gl
export function buildCells(centers, colors) {
  const length  = centers.length / 2;
  const indices = Array.from({ length }, (_, i) => i);
  return { length, centers, colors, indices };
}

// ── Manifest density bins (computed once after manifest loads) ────────────────
export function getManifestOverviewBins() {
  if (!state.manifestOverviewBins) state.manifestOverviewBins = buildOverviewBinsFromManifest();
  return state.manifestOverviewBins;
}

function buildOverviewBinsFromManifest() {
  const ov = state.manifest?.layers?.transcripts?.overview;
  if (!ov) return null;
  const ext  = state.manifest.layers.transcripts.extent;
  const { col, row, n } = ov;
  const ceil = pctile(n, 0.98);
  if (!ceil) return null;
  const centers = new Float32Array(n.length * 2);
  const colors  = new Uint8Array(n.length * 4);
  for (let i = 0; i < n.length; i++) {
    centers[i*2]   = ext.xmin + (col[i] + 0.5) * ov.cell_size;
    centers[i*2+1] = ext.ymin + (row[i] + 0.5) * ov.cell_size;
    const t = Math.min(Math.pow(n[i] / ceil, 0.5), 1.0);
    const [r, g, b] = densityColor(t);
    colors[i*4] = r; colors[i*4+1] = g; colors[i*4+2] = b;
    colors[i*4+3] = Math.round(120 + 120 * t);
  }
  return buildCells(centers, colors);
}

// ── Per-gene overview via DuckDB ──────────────────────────────────────────────
export function geneSelectionKey() { return [...state.selectedGenes].sort().join(','); }

export async function ensureGeneOverview(geneName) {
  if (state.geneOverviewCache.has(geneName)) return;
  const url = state.manifest.layers.transcripts.overview.gene_overview_url;
  try {
    const result = await state.overviewConn.query(
      `SELECT col, row, n::INTEGER AS n FROM read_parquet('${url}') WHERE feat_ID = '${geneName}'`
    );
    const nr  = result.numRows;
    const col = new Int32Array(nr), row = new Int32Array(nr), n = new Int32Array(nr);
    let off = 0;
    for (const batch of result.batches) {
      const cs = batch.getChildAt(0), rs = batch.getChildAt(1), ns = batch.getChildAt(2);
      for (let i = 0; i < batch.numRows; i++) {
        col[off] = cs.get(i); row[off] = rs.get(i); n[off] = ns.get(i); off++;
      }
    }
    state.geneOverviewCache.set(geneName, { col, row, n });
  } catch (e) {
    console.warn(`Gene overview failed for ${geneName}:`, e);
    state.geneOverviewCache.set(geneName, null);
  }
}

export async function updateGeneOverview(onUpdate) {
  const genes = state.manifest.layers.transcripts.genes;
  for (const gi of state.selectedGenes) {
    await ensureGeneOverview(genes[gi]);
    const bins = buildCompositeOverview();
    if (bins) state.overviewBins = bins;
    onUpdate();
  }
}

export function buildCompositeOverview() {
  if (state.selectedGenes.size === 0) return getManifestOverviewBins();
  const genes   = state.manifest.layers.transcripts.genes;
  const ext     = state.manifest.layers.transcripts.extent;
  const cs      = state.manifest.layers.transcripts.overview.cell_size;
  const cellSum = new Map();
  for (const gi of state.selectedGenes) {
    const data = state.geneOverviewCache.get(genes[gi]);
    if (!data) continue;
    const { col, row, n } = data;
    for (let i = 0; i < n.length; i++) {
      const key = col[i] * 100000 + row[i];
      const ex  = cellSum.get(key);
      if (ex) ex.sum += n[i];
      else cellSum.set(key, { sum: n[i], col: col[i], row: row[i] });
    }
  }
  if (!cellSum.size) return null;
  const sums    = Array.from(cellSum.values(), v => v.sum);
  const ceil    = pctile(sums, 0.98) || 1;
  const centers = new Float32Array(cellSum.size * 2);
  const colors  = new Uint8Array(cellSum.size * 4);
  let off = 0;
  for (const { sum, col, row } of cellSum.values()) {
    centers[off*2]   = ext.xmin + (col + 0.5) * cs;
    centers[off*2+1] = ext.ymin + (row + 0.5) * cs;
    const t = Math.min(Math.pow(sum / ceil, 0.5), 1.0);
    const [r, g, b] = densityColor(t);
    colors[off*4] = r; colors[off*4+1] = g; colors[off*4+2] = b;
    colors[off*4+3] = Math.round(120 + 120 * t);
    off++;
  }
  return buildCells(centers, colors);
}
