import * as vg from 'https://esm.sh/@uwdata/vgplot';
import { state }        from './state.js';
import { loadScatterData, initScatterDeck, renderScatter, resetScatterView } from './scatter.js';
import { notify } from './coordination.js';

export { vg };

// ── Coordinator ───────────────────────────────────────────────────────────────
export const mc  = vg.coordinator();
mc.databaseConnector(vg.wasmConnector());

export let sel = vg.Selection.crossfilter();

// ── Data loading ──────────────────────────────────────────────────────────────
export async function loadMetaIntoMosaic(url) {
  await mc.exec(
    `CREATE OR REPLACE TABLE cell_meta AS SELECT * FROM read_parquet('${url}')`
  );
  // Stride-sampled view for scatter display — stride on Morton-sorted data
  // gives spatially representative coverage; full table used for bridge queries
  const countRes = await mc.query('SELECT COUNT(*)::INT AS n FROM cell_meta');
  const n      = countRes.toArray()[0].n;
  const stride = Math.max(1, Math.floor(n / 20000));
  await mc.exec(
    `CREATE OR REPLACE VIEW cell_meta_scatter AS
     SELECT * FROM (
       SELECT *, row_number() OVER () AS _rn FROM cell_meta
     ) t WHERE _rn % ${stride} = 0`
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
    notify('cellSelection');
    return;
  }
  try {
    const where = clauses.map(c => `(${c.predicate})`).join(' AND ');
    const result = await mc.query(`SELECT cell_ID FROM cell_meta WHERE ${where}`);
    state.selectedCells = new Set(result?.toArray().map(r => String(r.cell_ID)) ?? []);
    state.selVersion++;
    notify('cellSelection');
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

// ── Scatter panel (deck.gl) ───────────────────────────────────────────────────
export async function initScatterPanel(bodyId, metaCols) {
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

  // Mode toggle buttons — same style as the spatial toolbar
  let umapMode = 'pan';
  const ctrlBar = document.getElementById(bodyId)?.querySelector('.stats-controls');
  if (ctrlBar) {
    const sep = document.createElement('span');
    sep.style.cssText = 'width:1px;height:14px;background:#374151;margin:0 4px;flex-shrink:0;align-self:center;';
    ctrlBar.appendChild(sep);
    ['pan', 'lasso'].forEach(m => {
      const btn = document.createElement('button');
      btn.className = 'tool-btn' + (m === 'pan' ? ' active' : '');
      btn.style.fontSize = '10px';
      btn.title = m;
      const icon = document.createElement('i');
      icon.setAttribute('data-lucide', m === 'pan' ? 'hand' : 'lasso');
      btn.appendChild(icon);
      btn.addEventListener('click', () => {
        umapMode = m;
        ctrlBar.querySelectorAll('.tool-btn').forEach(b =>
          b.classList.toggle('active', b === btn));
        document.getElementById(bodyId)?.querySelector('canvas')?._setMode?.(m);
      });
      ctrlBar.appendChild(btn);
    });
    // Clear selection button
    const sep2 = document.createElement('span');
    sep2.style.cssText = 'width:1px;height:14px;background:#374151;margin:0 4px;flex-shrink:0;align-self:center;';
    ctrlBar.appendChild(sep2);

    [
      { icon: 'circle-x',   title: 'clear selection', fn: () => {
          state.selectedCells = new Set();
          state.selVersion++;
          notify('cellSelection');
          try { sel.update({ source: 'umap-clear', predicate: null }); } catch(_) {}
        }},
      { icon: 'maximize-2', title: 'zoom to fit',      fn: () => resetScatterView() },
    ].forEach(({ icon, title, fn }) => {
      const btn = document.createElement('button');
      btn.className = 'tool-btn'; btn.title = title;
      const i = document.createElement('i');
      i.setAttribute('data-lucide', icon);
      btn.appendChild(i);
      btn.addEventListener('click', fn);
      ctrlBar.appendChild(btn);
    });

    lucide.createIcons({ nodes: ctrlBar.querySelectorAll('[data-lucide]') });
  }

  const area = getOrCreateChartArea(bodyId);
  setTitle(bodyId, 'scatter');

  const reloadData = async () => {
    await loadScatterData(ctrls.x.value, ctrls.y.value, ctrls.color.value || null);
    initScatterDeck(area.id || (area.id = `${bodyId}-deck`));
    document.getElementById(bodyId)?.querySelector('canvas')?._setMode?.(umapMode);
  };

  ['x','y','color'].forEach(k => ctrls[k].addEventListener('change', reloadData));

  await reloadData();
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
export async function initMosaicPanels(metaCols) {
  sel = vg.Selection.crossfilter();  // fresh selection on every (re-)init
  await initScatterPanel('stats-body-1', metaCols);
  initDistPanel('stats-body-2', metaCols);
}
