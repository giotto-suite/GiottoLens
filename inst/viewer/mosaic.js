import * as vg from 'https://esm.sh/@uwdata/vgplot';
import { state }        from './state.js';
import { renderLayers } from './render.js';
import { sendToR }      from './comms.js';

export { vg };

// ── Coordinator ───────────────────────────────────────────────────────────────
export const mc  = vg.coordinator();
mc.databaseConnector(vg.wasmConnector());

export const sel = vg.Selection.crossfilter();

// ── Data loading ──────────────────────────────────────────────────────────────
export async function loadMetaIntoMosaic(url) {
  await mc.exec(
    `CREATE OR REPLACE TABLE cell_meta AS SELECT * FROM read_parquet('${url}')`
  );
}

// ── Mosaic → spatial bridge ───────────────────────────────────────────────────
// Observable Plot fires 'input' synchronously, but Mosaic updates sel.clauses
// asynchronously via the coordinator. A microtask delay lets Mosaic settle
// before we read the clauses and query for matching cell_IDs.
async function runBridge() {
  const clauses = (sel.clauses ?? []).filter(c => c?.predicate != null);
  if (!clauses.length) {
    state.selectedCells = new Set();
    state.selVersion++;
    sendToR('cell_selection', { ids: [] });
    renderLayers(state.currentViewState);
    return;
  }
  try {
    const where = clauses.map(c => `(${c.predicate})`).join(' AND ');
    const result = await mc.query(`SELECT cell_ID FROM cell_meta WHERE ${where}`);
    const ids = result?.toArray().map(r => String(r.cell_ID)) ?? [];
    state.selectedCells = new Set(ids);
    state.selVersion++;
    sendToR('cell_selection', { ids });
    renderLayers(state.currentViewState);
  } catch(e) {
    console.warn('[GiottoLens bridge]', e);
  }
}

function attachBridge(el) {
  el.addEventListener('input', () => setTimeout(runBridge, 0));
  try { sel.addEventListener('value', runBridge); } catch(_) {}
}

// ── Panel helpers ─────────────────────────────────────────────────────────────
function buildControlBar(bodyId, fields) {
  const body = document.getElementById(bodyId);
  if (!body) return {};
  body.querySelector('.stats-controls')?.remove();

  const bar = document.createElement('div');
  bar.className = 'stats-controls';

  const els = {};
  for (const { key, label, options } of fields) {
    const wrap = document.createElement('label');
    wrap.className = 'stats-ctrl-wrap';
    wrap.textContent = label;
    const sel = document.createElement('select');
    sel.className = 'stats-ctrl-sel';
    options.forEach(o => {
      const opt = document.createElement('option');
      opt.value   = o.value ?? o;
      opt.textContent = o.label ?? o;
      sel.appendChild(opt);
    });
    wrap.appendChild(sel);
    bar.appendChild(wrap);
    els[key] = sel;
  }
  body.insertBefore(bar, body.firstChild);
  return els;
}

function getOrCreateChartArea(bodyId) {
  const body = document.getElementById(bodyId);
  if (!body) return null;
  let area = body.querySelector('.stats-chart-area');
  if (!area) {
    area = document.createElement('div');
    area.className = 'stats-chart-area';
    body.appendChild(area);
  }
  return area;
}

function setTitle(bodyId, title) {
  const h = document.getElementById(bodyId)
    ?.closest('.stats-pane')?.querySelector('.stats-pane-title');
  if (h) h.textContent = title;
}

// ── Scatter panel ─────────────────────────────────────────────────────────────
export function initScatterPanel(bodyId, metaCols) {
  const cols    = metaCols.map(c => c.name);
  const dims    = cols.filter(c => /umap|tsne|pca/i.test(c));
  const numCols = metaCols.filter(c => c.numeric).map(c => c.name);
  const xDef    = dims.find(c => /1$|_x$/i.test(c)) ?? dims[0] ?? numCols[0] ?? cols[0];
  const yDef    = dims.find(c => /2$|_y$/i.test(c)) ?? dims[1] ?? numCols[1] ?? cols[1];
  const colorDef = cols.find(c => /clus|type|label|class|leiden/i.test(c)) ?? '';

  const ctrls = buildControlBar(bodyId, [
    { key: 'x',     label: 'x',     options: cols },
    { key: 'y',     label: 'y',     options: cols },
    { key: 'color', label: 'color', options: [{ value: '', label: 'none' }, ...cols.map(c => ({ value: c, label: c }))] },
  ]);

  if (xDef)     ctrls.x.value     = xDef;
  if (yDef)     ctrls.y.value     = yDef;
  if (colorDef) ctrls.color.value = colorDef;

  const render = () => renderScatter(bodyId, ctrls.x.value, ctrls.y.value, ctrls.color.value || null);
  Object.values(ctrls).forEach(s => s.addEventListener('change', render));
  render();
}

function renderScatter(bodyId, x, y, color) {
  const area = getOrCreateChartArea(bodyId);
  if (!area) return;
  setTitle(bodyId, 'scatter');
  area.innerHTML = '';

  const w = Math.max(area.clientWidth  || 0, 240);
  const h = Math.max(area.clientHeight || 0, 200);

  const marks = [
    vg.dot(vg.from('cell_meta', { filterBy: sel }), {
      x,
      y,
      fill: color ?? '#60a5fa',
      fillOpacity: 0.65,
      r: 2,
    }),
    vg.intervalXY({ as: sel }),
  ];

  const el = vg.plot(...marks, vg.width(w), vg.height(h),
    vg.style({ color: '#9ca3af', background: 'transparent' }));
  area.appendChild(el);
  attachBridge(el);

  new ResizeObserver(() => {
    if (area.clientWidth > 0) el.setAttribute('width', area.clientWidth);
  }).observe(area);
}

// ── Distribution panel ────────────────────────────────────────────────────────
export function initDistPanel(bodyId, metaCols) {
  const cols   = metaCols.map(c => c.name);
  const numCol = metaCols.find(c => c.numeric && !/umap|tsne|pca/i.test(c.name));

  const ctrls = buildControlBar(bodyId, [
    { key: 'col', label: 'column', options: cols },
  ]);
  if (numCol) ctrls.col.value = numCol.name;

  const render = () => renderDist(bodyId, ctrls.col.value, metaCols);
  ctrls.col.addEventListener('change', render);
  render();
}

function renderDist(bodyId, col, metaCols) {
  const area = getOrCreateChartArea(bodyId);
  if (!area) return;
  setTitle(bodyId, col);
  area.innerHTML = '';

  const w = Math.max(area.clientWidth  || 0, 240);
  const h = Math.max(area.clientHeight || 0, 200);
  const isNumeric = metaCols.find(c => c.name === col)?.numeric ?? false;

  const mark = isNumeric
    ? vg.rectY(vg.from('cell_meta', { filterBy: sel }), {
        x: vg.bin(col), y: vg.count(), fill: '#3b82f6', fillOpacity: 0.7,
      })
    : vg.barY(vg.from('cell_meta', { filterBy: sel }), {
        x: col, y: vg.count(), fill: '#3b82f6', fillOpacity: 0.7, sort: { x: '-y' },
      });

  const interact = isNumeric ? vg.intervalX({ as: sel }) : vg.toggleX({ as: sel });
  const el = vg.plot(mark, interact, vg.width(w), vg.height(h),
    vg.style({ color: '#9ca3af', background: 'transparent' }));
  area.appendChild(el);
  attachBridge(el);

  new ResizeObserver(() => {
    if (area.clientWidth > 0) el.setAttribute('width', area.clientWidth);
  }).observe(area);
}

// ── Entry point ───────────────────────────────────────────────────────────────
export function initMosaicPanels(metaCols) {
  initScatterPanel('stats-body-1', metaCols);
  initDistPanel('stats-body-2', metaCols);
}
