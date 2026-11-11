// Histogram / bar panel over one metadata column, drawn with Vega-Lite (it
// replaces Mosaic: adr/0003).
// Bins are counted in JS from the typed arrays; Vega-Lite only draws the bins
// and reports the brush, which becomes a 'range' or 'categories' rule.
// Grey bars: all cells. Blue: cells passing every *other* source (crossfilter)
// or the whole selection ('or' mode).
// The brush shows the panel's rule wherever the rule came from (this brush, R,
// the rules restored after a reload), so a restored range can still be
// scrubbed; a rule changed elsewhere redraws the chart to match. A drag of
// the brush is live (adr/0013): the rule is set on release.
import { state } from '../core/state.js';
import { needColumns } from '../data/meta.ts';
import { store, actions } from '../core/store.ts';
import { maskExcept, setRangeRule } from '../selection/selection.ts';
import { addLiveConsumer, beginLive, endLive, liveSource, moveLive, prepareLive } from '../selection/live.ts';
import { buildControlBar, chartArea, whenVisible } from './controls.js';

const BINS = 40;
// A brush drag with the left button only: Vega-Lite's default takes any button,
// and the middle one pans elsewhere in the viewer
const LEFT_DRAG = '[pointerdown[event.button === 0], window:pointerup] > window:pointermove!';
let _embed = null;   // vega-embed, loaded on first use (keeps it out of first paint)
const loadEmbed = () => (_embed ??= import('vega-embed').then(m => m.default));

export function createHistogramPanel(body, ctx) {
  const cols = [...state.metaInfo.values()];
  const def  = cols.find(c => c.kind === 'continuous' && !/umap|tsne|pca/i.test(c.name)) ?? cols[0];
  const ctrls = buildControlBar(body, [
    { key: 'col', label: 'column', options: cols.map(c => c.name), value: def?.name },
  ]);
  const area = chartArea(body);
  let view = null, col = null, source = null, edges = null, gen = 0;
  let own = null;   // the rule this panel last set or drew
  const unsub = [];

  // Bins of a column: their number, and the bin of cell i (-1: NA)
  function binsOf(c) {
    const v = c.values;
    if (c.kind === 'categorical') return { bins: c.levels.length, bin: i => v[i] };
    const lo = c.min, w = (c.max - c.min) / BINS || 1;
    return { bins: BINS, bin: i => { const x = v[i]; return x === x ? Math.min(BINS - 1, ((x - lo) / w) | 0) : -1; } };
  }
  // Counts over all cells, kept per column: only the foreground changes.
  // `live`: foreground counts from a drag (adr/0013). Null while the column
  // loads (new metadata gave it a new file): draw() runs again once it has.
  let allFor = null;
  function counts(live) {
    const c = state.meta.get(col);
    if (!c) return null;
    const { bins, bin } = binsOf(c);
    if (allFor?.c !== c) {
      const all = new Uint32Array(bins);
      for (let i = 0, n = c.values.length; i < n; i++) { const k = bin(i); if (k >= 0) all[k]++; }
      allFor = { c, all };
    }
    let sel = live;
    if (!sel) {
      const s = store.getState();
      const fg = s.combine === 'and' ? maskExcept(source) : s.selection.mask;
      if (fg) {
        sel = new Uint32Array(bins);
        for (let i = 0, n = fg.length; i < n; i++) if (fg[i]) { const k = bin(i); if (k >= 0) sel[k]++; }
      }
    }
    const all = allFor.all;
    if (c.kind === 'categorical') return c.levels.map((label, j) => ({ label, all: all[j], sel: sel ? sel[j] : 0 }));
    const lo = c.min, w = (c.max - c.min) / BINS || 1;
    edges = Array.from({ length: BINS + 1 }, (_, j) => lo + j * w);
    return Array.from(all, (a, j) => ({ bin0: edges[j], bin1: edges[j + 1], all: a, sel: sel ? sel[j] : 0 }));
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
            : { name: 'brush', select: { type: 'interval', encodings: ['x'], on: LEFT_DRAG, translate: LEFT_DRAG },
                ...(value && { value }) }],
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

  // A drag of a range brush is live: the rule is set on release
  let latest = null, frame = 0, down = false;
  function commit() {
    const c = state.meta.get(col);
    const values = latest?.label, range = latest?.bin0;
    const rule = c?.kind === 'categorical'
      ? (values?.length ? { source, kind: 'categories', space: col, params: { values } } : null)
      : (range ? { source, kind: 'range', space: col, params: { min: Math.min(...range), max: Math.max(...range) } } : null);
    if (same(rule, ruleOf())) return;   // e.g. the brush drawn from the rule
    own = rule;
    actions.setRule(source, rule);
  }
  function release() {
    down = false;
    if (!source || liveSource() !== source) return;
    cancelAnimationFrame(frame); frame = 0;
    endLive();
    commit();
  }
  area.addEventListener('pointerdown', e => {
    if (e.button !== 0) return;
    down = true;
    window.addEventListener('pointerup', release, { once: true });
    window.addEventListener('pointercancel', release, { once: true });
  }, true);
  area.addEventListener('pointerenter', () => {
    const c = state.meta.get(col);
    if (c?.kind === 'continuous') prepareLive([c]);
  });

  async function draw() {
    const my = ++gen;
    view?.finalize(); view = null;
    col = ctrls.col.value;
    source = `hist:${col}`;
    ctx.setTitle(col);
    if (!state.meta.has(col)) {
      await needColumns([col]);
      if (my !== gen) return;
    }
    const c = state.meta.get(col);
    if (!c) return;
    const embed = await loadEmbed();
    if (my !== gen) return;
    own = ruleOf();
    const res = await embed(area, spec(c, counts(), brushFrom(c, own)), { actions: false, renderer: 'canvas' });
    if (my !== gen) { res.view.finalize(); return; }
    view = res.view;
    const cat = c.kind === 'categorical';
    // The latest brush once per frame (a pause-based debounce never fired
    // while the brush kept moving): a range moves live while the button is
    // down; a pick, or a brush drawn from a rule, is set at once
    cancelAnimationFrame(frame); frame = 0;
    view.addSignalListener(cat ? 'pick' : 'brush', (_, v) => {
      latest = v;
      frame ||= requestAnimationFrame(() => {
        frame = 0;
        if (my !== gen) return;   // redrawn for another column meanwhile
        if (cat || !down) { commit(); return; }
        if (liveSource() !== source) beginLive(source, [c]);
        const range = latest?.bin0;
        moveLive(range ? [[Math.min(...range), Math.max(...range)]] : null);
      });
    });
  }

  function refresh() {
    const rows = view && counts();
    if (rows) view.data('bins', rows).runAsync();
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
  // Bars that follow another panel's drag
  unsub.push(addLiveConsumer({
    source: () => source,
    bins: () => (view && ctx.visible() && state.meta.get(col) ? binsOf(state.meta.get(col)) : null),
    show: sel => { const rows = view && counts(sel); if (rows) view.data('bins', rows).runAsync(); },
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
      if (source && liveSource() === source) endLive();
      unsub.forEach(u => u());
      if (source) setRangeRule(source, col, null);
      view?.finalize(); view = null;
    },
  };
}
