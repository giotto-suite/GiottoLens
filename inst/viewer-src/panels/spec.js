// A panel drawn from a Vega-Lite spec pushed from R (viewer$push_panel(),
// e.g. GiottoVisuals::renderSpec(engine = "vegalite")). Rows carrying `_idx`
// (a cell index, added by R from cell_ID) are linked: they dim when not
// selected, and an interval param named `brush` becomes a selection rule
// (source `panel:<panel id>`) over the cells whose rows fall inside it. The
// rule keeps the brush's extent, so a chart rebuilt with its rule in place (a
// reload, a re-push) draws the brush again and it can still be dragged.
import { state } from '../core/state.js';
import { store, actions } from '../core/store.ts';
import { rangeBuffer, readColumns, numRows } from '../data/parquet.ts';
import { primeMask, encodeMask } from '../selection/rules.ts';
import { chartArea, whenVisible } from './controls.js';
import { chartAxis, token } from '../ui/theme.ts';

const loadEmbed = () => import('vega-embed').then(m => m.default);

// A saved brush ({field: [lo, hi]}) by encoding channel; undefined unless
// every field has one
function brushValue(spec, saved) {
  if (!saved) return undefined;
  const encs = [spec.encoding, ...(spec.layer ?? []).map(l => l.encoding)].filter(Boolean);
  const value = {};
  for (const [field, range] of Object.entries(saved)) {
    const ch = encs.flatMap(e => Object.entries(e)).find(([, d]) => d?.field === field)?.[0];
    if (!ch) return undefined;
    value[ch] = range;
  }
  return value;
}

async function readRows(url) {
  const cols = await readColumns(await rangeBuffer(new URL(url, document.baseURI).href), null);
  const names = Object.keys(cols), n = numRows(cols);
  const rows = new Array(n);
  for (let i = 0; i < n; i++) { const r = {}; for (const k of names) r[k] = cols[k][i]; rows[i] = r; }
  return rows;
}

/**
 * @param {HTMLElement} body
 * @param {{ spec: any, data_url?: string }} payload
 * @param {import('./dock.ts').PanelCtx} ctx
 */
export async function createSpecPanel(body, { spec, data_url }, ctx) {
  const area = chartArea(body);
  const unsub = [];
  let view = null, destroyed = false;
  const source = `panel:${ctx.id}`;

  const rows = data_url ? await readRows(data_url) : (spec.data?.values ?? []);
  const linked = rows.length > 0 && '_idx' in rows[0];
  const markSel = () => {
    const m = store.getState().selection.mask;
    for (const r of rows) r._sel = !m || m[r._idx] ? 1 : 0;
  };
  if (linked) markSel();

  // Pixel size of the pane, not 'container': with axis titles and a legend,
  // 'container' sizing lets the chart overflow the pane (issue #3). 'fit' with
  // explicit pixels shrinks the plot so axes, titles and legend fit inside.
  const paneSize = () => ({ width: Math.max(area.clientWidth, 120), height: Math.max(area.clientHeight, 120) });
  const brush = brushValue(spec, store.getState().rules[source]?.params?.brush);
  const s = { ...spec, data: { name: 'cells' }, ...paneSize(),
              autosize: { type: 'fit', contains: 'padding' }, background: 'transparent' };
  delete s.$schema;
  if (linked && !s.layer && !s.encoding?.opacity)
    s.encoding = { ...s.encoding, opacity: { condition: { test: 'datum._sel == 1', value: 0.9 }, value: 0.15 } };
  s.config = { view: { stroke: null },
    axis: { ...chartAxis(), titleColor: token('fg-2') },
    legend: { labelColor: token('fg-2'), titleColor: token('fg-2') }, ...s.config };

  const embed = await loadEmbed();
  if (destroyed) return { destroy() {} };
  const res = await embed(area, s, { actions: false, renderer: 'canvas' });
  view = res.view;
  await view.data('cells', rows).runAsync();
  // The brush is set in pixels once the data has made the scales: a param
  // `value` would be placed before the data arrives, against empty scales
  if (brush) {
    try {
      for (const [ch, [lo, hi]] of Object.entries(brush)) {
        const sc = view.scale(ch);
        view.signal(`brush_${ch}`, [sc(lo), sc(hi)]);
      }
      await view.runAsync();
    } catch (_) { /* a spec whose brush is not in its top-level view */ }
  }
  const resize = new ResizeObserver(() => {
    const { width, height } = paneSize();
    if (view && (width !== view.width() || height !== view.height())) view.width(width).height(height).runAsync();
  });
  resize.observe(area);
  unsub.push(() => resize.disconnect());

  // Hidden behind another tab, it catches up when shown
  const dim = whenVisible(ctx, () => {
    markSel();
    view?.data('cells', rows.slice()).runAsync();
  });
  if (linked) {
    unsub.push(store.subscribe(st => st.selection.version, dim.update));
    let t;
    try {
      view.addSignalListener('brush', (_, v) => {
        clearTimeout(t);
        t = setTimeout(() => brushToRule(v), 60);
      });
    } catch (_) { /* the spec has no brush param */ }
  }

  function brushToRule(v) {
    const fields = Object.entries(v ?? {});
    if (!fields.length || !state.cells) { actions.setRule(source, null); return; }
    const m = new Uint8Array(state.cells.n);
    for (const r of rows) {
      let inside = true;
      for (const [f, [lo, hi]] of fields) {
        const x = r[f];
        if (!(x >= Math.min(lo, hi) && x <= Math.max(lo, hi))) { inside = false; break; }
      }
      if (inside) m[r._idx] = 1;
    }
    const rule = { source, kind: 'ids', params: { mask: encodeMask(m, m.length), brush: Object.fromEntries(fields) } };
    primeMask(rule, m);
    actions.setRule(source, rule);
  }

  return {
    view,
    show: dim.show,
    destroy() {
      destroyed = true;
      unsub.forEach(u => u());
      actions.setRule(source, null);
      view?.finalize(); view = null;
    },
  };
}

