// A panel drawn from a Vega-Lite spec pushed from R (viewer$push_panel(),
// e.g. GiottoVisuals::renderSpec(engine = "vegalite")). Rows carrying `_idx`
// (a cell index, added by R from cell_ID) are linked: they dim when not
// selected, and an interval param named `brush` becomes a selection rule
// over the cells whose rows fall inside it.
import { state } from '../core/state.js';
import { store, actions } from '../core/store.ts';
import { rangeBuffer, readColumns, numRows } from '../data/parquet.ts';
import { primeMask, encodeMask } from '../selection/rules.ts';
import { chartArea, setTitle } from './controls.js';

const loadEmbed = () => import('vega-embed').then(m => m.default);

async function readRows(url) {
  const cols = await readColumns(await rangeBuffer(new URL(url, document.baseURI).href), null);
  const names = Object.keys(cols), n = numRows(cols);
  const rows = new Array(n);
  for (let i = 0; i < n; i++) { const r = {}; for (const k of names) r[k] = cols[k][i]; rows[i] = r; }
  return rows;
}

export async function createSpecPanel(body, { spec, title, data_url }) {
  body.querySelector('.stats-controls')?.remove();
  const area = chartArea(body);
  area.replaceChildren();
  setTitle(body, title ?? spec.title ?? 'panel');
  const unsub = [];
  let view = null, destroyed = false;
  const source = `panel:${body.id}`;

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
  const s = { ...spec, data: { name: 'cells' }, ...paneSize(),
              autosize: { type: 'fit', contains: 'padding' }, background: 'transparent' };
  delete s.$schema;
  if (linked && !s.layer && !s.encoding?.opacity)
    s.encoding = { ...s.encoding, opacity: { condition: { test: 'datum._sel == 1', value: 0.9 }, value: 0.15 } };
  s.config = { view: { stroke: null },
    axis: { labelColor: '#9ca3af', titleColor: '#9ca3af', domainColor: '#374151', tickColor: '#374151', gridColor: '#1f2937' },
    legend: { labelColor: '#9ca3af', titleColor: '#9ca3af' }, ...s.config };

  const embed = await loadEmbed();
  if (destroyed) return { destroy() {} };
  const res = await embed(area, s, { actions: false, renderer: 'canvas' });
  view = res.view;
  await view.data('cells', rows).runAsync();
  const resize = new ResizeObserver(() => {
    const { width, height } = paneSize();
    if (view && (width !== view.width() || height !== view.height())) view.width(width).height(height).runAsync();
  });
  resize.observe(area);
  unsub.push(() => resize.disconnect());

  if (linked) {
    unsub.push(store.subscribe(st => st.selection.version, () => {
      markSel();
      view?.data('cells', rows.slice()).runAsync();
    }));
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
    const rule = { source, kind: 'ids', params: { mask: encodeMask(m, m.length) } };
    primeMask(rule, m);
    actions.setRule(source, rule);
  }

  return {
    view,
    destroy() {
      destroyed = true;
      unsub.forEach(u => u());
      actions.setRule(source, null);
      view?.finalize(); view = null;
    },
  };
}

