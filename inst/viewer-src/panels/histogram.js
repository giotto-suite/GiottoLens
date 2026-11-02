// Histogram / bar panel over one metadata column, drawn with Vega-Lite (it
// replaces Mosaic: adr/0003).
// Bins are counted in JS from the typed arrays; Vega-Lite only draws the bins
// and reports the brush, which becomes a 'range' or 'categories' rule.
// Grey bars: all cells. Blue: cells passing every *other* source (crossfilter)
// or the whole selection ('or' mode).
// The brush shows the panel's rule wherever the rule came from (this brush, R,
// the rules restored after a reload), so a restored range can still be
// scrubbed; a rule changed elsewhere redraws the chart to match.
import { state } from '../core/state.js';
import { store, actions } from '../core/store.ts';
import { maskExcept, setRangeRule } from '../selection/selection.ts';
import { buildControlBar, chartArea, whenVisible } from './controls.js';

const BINS = 40;
let _embed = null;   // vega-embed, loaded on first use (keeps it out of first paint)
const loadEmbed = () => (_embed ??= import('vega-embed').then(m => m.default));

export function createHistogramPanel(body, ctx) {
  const cols = [...state.meta.values()];
  const def  = cols.find(c => c.kind === 'continuous' && !/umap|tsne|pca/i.test(c.name)) ?? cols[0];
  const ctrls = buildControlBar(body, [
    { key: 'col', label: 'column', options: cols.map(c => c.name), value: def?.name },
  ]);
  const area = chartArea(body);
  let view = null, col = null, source = null, edges = null, gen = 0;
  let own = null;   // the rule this panel last set or drew
  const unsub = [];

  function counts() {
    const c = state.meta.get(col);
    const s = store.getState();
    const fg = s.combine === 'and' ? maskExcept(source) : s.selection.mask;
    const v = c.values, n = v.length;
    if (c.kind === 'categorical') {
      const k = c.levels.length;
      const all = new Uint32Array(k), sel = new Uint32Array(k);
      for (let i = 0; i < n; i++) { const x = v[i]; if (x < 0) continue; all[x]++; if (fg?.[i]) sel[x]++; }
      return c.levels.map((label, j) => ({ label, all: all[j], sel: fg ? sel[j] : 0 }));
    }
    const lo = c.min, w = (c.max - c.min) / BINS || 1;
    const all = new Uint32Array(BINS), sel = new Uint32Array(BINS);
    for (let i = 0; i < n; i++) {
      const x = v[i];
      if (x !== x) continue;
      const b = Math.min(BINS - 1, ((x - lo) / w) | 0);
      all[b]++; if (fg?.[i]) sel[b]++;
    }
    edges = Array.from({ length: BINS + 1 }, (_, j) => lo + j * w);
    return Array.from(all, (a, j) => ({ bin0: edges[j], bin1: edges[j + 1], all: a, sel: fg ? sel[j] : 0 }));
  }

  const ruleOf = () => (source ? store.getState().rules[source] : undefined) ?? null;
  const same = (a, b) => (!a && !b) || (!!a && !!b && a.kind === b.kind && a.space === b.space &&
    !a.negate === !b.negate && JSON.stringify(a.params) === JSON.stringify(b.params));

  // The brush's starting value from a rule on this column, if any
  function brushFrom(c, rule) {
    if (!rule || rule.space !== c.name || rule.negate) return undefined;
    if (c.kind === 'categorical') return rule.kind === 'categories' ? rule.params.values.map(label => ({ label })) : undefined;
    return rule.kind === 'range' ? { x: [rule.params.min, rule.params.max] } : undefined;
  }

  function spec(c, rows, value) {
    const cat = c.kind === 'categorical';
    const x = cat
      ? { field: 'label', type: 'nominal', sort: '-y', axis: { labelLimit: 80, title: null } }
      : { field: 'bin0', type: 'quantitative', bin: { binned: true, step: edges[1] - edges[0] }, title: null };
    const x2 = cat ? {} : { x2: { field: 'bin1' } };
    return {
      $schema: 'https://vega.github.io/schema/vega-lite/v6.json',
      width: 'container', height: 'container', autosize: { type: 'fit', contains: 'padding' },
      background: 'transparent',
      data: { name: 'bins', values: rows },
      layer: [
        { params: [cat
            ? { name: 'pick', select: { type: 'point', fields: ['label'], toggle: 'true' }, ...(value && { value }) }
            : { name: 'brush', select: { type: 'interval', encodings: ['x'] }, ...(value && { value }) }],
          mark: { type: 'bar', color: '#4b5563' },
          encoding: { x, ...x2, y: { field: 'all', type: 'quantitative', title: null } } },
        { mark: { type: 'bar', color: '#3b82f6', opacity: 0.85 },
          encoding: { x, ...x2, y: { field: 'sel', type: 'quantitative' } } },
      ],
      config: {
        view: { stroke: null },
        axis: { labelColor: '#9ca3af', domainColor: '#374151', tickColor: '#374151', gridColor: '#1f2937', labelFontSize: 10 },
      },
    };
  }

  async function draw() {
    const my = ++gen;
    view?.finalize(); view = null;
    col = ctrls.col.value;
    source = `hist:${col}`;
    const c = state.meta.get(col);
    if (!c) return;
    ctx.setTitle(col);
    const embed = await loadEmbed();
    if (my !== gen) return;
    own = ruleOf();
    const res = await embed(area, spec(c, counts(), brushFrom(c, own)), { actions: false, renderer: 'canvas' });
    if (my !== gen) { res.view.finalize(); return; }
    view = res.view;
    const cat = c.kind === 'categorical';
    // The latest brush is applied once per frame, so the selection follows a
    // scrub (an update costs ~2 ms at 170k cells). A pause-based debounce
    // never fired while the brush kept moving.
    let latest = null, frame = 0;
    view.addSignalListener(cat ? 'pick' : 'brush', (_, v) => {
      latest = v;
      frame ||= requestAnimationFrame(() => {
        frame = 0;
        if (my !== gen) return;   // redrawn for another column meanwhile
        const values = latest?.label, range = latest?.bin0;
        const rule = cat
          ? (values?.length ? { source, kind: 'categories', space: col, params: { values } } : null)
          : (range ? { source, kind: 'range', space: col, params: { min: range[0], max: range[1] } } : null);
        if (same(rule, ruleOf())) return;   // e.g. the brush drawn from the rule
        own = rule;
        actions.setRule(source, rule);
      });
    });
  }

  function refresh() {
    if (!view) return;
    view.data('bins', counts()).runAsync();
  }

  ctrls.col.addEventListener('change', () => {
    // The old column's rule goes with it
    own = null;
    if (source) setRangeRule(source, col, null);
    draw();
  });
  // A rule on this column set or dropped elsewhere: draw the brush to match
  unsub.push(store.subscribe(s => s.rules, () => {
    const r = ruleOf();
    if (r === own || same(r, own)) return;
    own = r;
    draw();
  }));
  const counted = whenVisible(ctx, refresh);
  unsub.push(store.subscribe(s => s.selection.version, counted.update));
  unsub.push(store.subscribe(s => s.combine, counted.update));
  draw();

  return {
    show: counted.show,
    get view() { return view; },
    destroy() {
      gen++;
      unsub.forEach(u => u());
      if (source) setRangeRule(source, col, null);
      view?.finalize(); view = null;
    },
  };
}
