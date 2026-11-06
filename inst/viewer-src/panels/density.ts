// 2D density panel: two continuous metadata columns binned into a grid, drawn
// as one image coloured by cells per bin (viridis, log scale), with a
// rectangle brush. With a selection, bins are coloured by the cells passing
// every *other* source (cross-filter mode) or the whole selection, and bins
// with none of them are dim grey. One image rather than a mark per bin
// (adr/0012), on an own canvas under Vega's plot area: a Vega image mark loads
// each new URL asynchronously and drew nothing meanwhile, so it flashed while
// scrubbing. Vega draws only the axes and the rectangle, as SVG: its canvas,
// redrawn in part on every move of the rectangle, went black in regions in
// Positron and Chrome, over the bins and its own axes. The rectangle is the
// intersect of two range rules, so R evaluates and describes it like any
// other; it is drawn from that rule wherever the rule came from (this brush,
// R, a reload), as the histogram's is. A drag is live (adr/0013): the rule
// is set on release, and the bins follow the rectangle meanwhile.
import { state } from '../core/state.js';
import { store, actions } from '../core/store.ts';
import { maskExcept } from '../selection/selection.ts';
import { addLiveConsumer, beginLive, endLive, liveSource, moveLive, prepareLive } from '../selection/live.ts';
import type { Rule } from '../selection/rules.ts';
import type { MetaColumn } from '../data/meta.ts';
import type { PanelCtx, PanelHandle } from './dock.ts';
// @ts-ignore: plain JS module
import { buildControlBar, chartArea, whenVisible } from './controls.js';

export const BINS = 256;

export interface Density { all: Uint32Array; sel: Uint32Array | null; maxAll: number; maxSel: number }

// Counts per bin over all cells, and over the cells in `fg` when given, within
// the domains `dx`, `dy` (default: the columns' range; zoomed in, the plot's).
// Bin (bx, by) is all[by * bins + bx], counting up from the domain's minimum.
// `known`: the counts over all cells for the same domains, so only the
// foreground is counted.
export function binDensity(x: MetaColumn, y: MetaColumn, fg: Uint8Array | null, bins = BINS,
                           dx: [number, number] = [x.min, x.max], dy: [number, number] = [y.min, y.max],
                           known?: Pick<Density, 'all' | 'maxAll'>): Density {
  const bin = binner(x, y, bins, dx, dy);
  if (known) {
    if (!fg) return { all: known.all, sel: null, maxAll: known.maxAll, maxSel: 0 };
    const sel = new Uint32Array(bins * bins);
    for (let i = 0, n = fg.length; i < n; i++) if (fg[i]) { const k = bin(i); if (k >= 0) sel[k]++; }
    return withSel(known, sel);
  }
  const all = new Uint32Array(bins * bins), sel = fg ? new Uint32Array(bins * bins) : null;
  const n = x.values.length;
  let maxAll = 0, maxSel = 0;
  for (let i = 0; i < n; i++) {
    const k = bin(i);
    if (k < 0) continue;
    const c = ++all[k];
    if (c > maxAll) maxAll = c;
    if (sel && fg![i]) { const s = ++sel[k]; if (s > maxSel) maxSel = s; }
  }
  return { all, sel, maxAll, maxSel };
}

// Bin of cell i within the domains, or -1 (outside, or NaN)
export function binner(x: MetaColumn, y: MetaColumn, bins: number, [x0, x1]: [number, number], [y0, y1]: [number, number]) {
  const sx = bins / ((x1 - x0) || 1), sy = bins / ((y1 - y0) || 1);
  const xv = x.values, yv = y.values, top = bins - 1;
  return (i: number): number => {
    const a = xv[i], b = yv[i];
    // NaN fails both tests
    if (!(a >= x0 && a <= x1 && b >= y0 && b <= y1)) return -1;
    return Math.min(top, ((b - y0) * sy) | 0) * bins + Math.min(top, ((a - x0) * sx) | 0);
  };
}

export function withSel(known: Pick<Density, 'all' | 'maxAll'>, sel: Uint32Array): Density {
  let maxSel = 0;
  for (let k = 0; k < sel.length; k++) if (sel[k] > maxSel) maxSel = sel[k];
  return { all: known.all, sel, maxAll: known.maxAll, maxSel };
}

// Viridis (matplotlib's), 9 stops: perceptually even, readable in common
// colour blindness, and its dark end still shows on the panel's background
const VIRIDIS = [[68, 1, 84], [71, 44, 122], [59, 81, 139], [44, 113, 142], [33, 144, 141],
  [39, 173, 129], [92, 200, 99], [170, 220, 50], [253, 231, 37]];
export const COLORS: Uint8Array = (() => {
  const lut = new Uint8Array(256 * 3);
  for (let i = 0; i < 256; i++) {
    const f = (i / 255) * (VIRIDIS.length - 1), j = Math.min(VIRIDIS.length - 2, Math.floor(f)), t = f - j;
    for (let c = 0; c < 3; c++) lut[i * 3 + c] = Math.round(VIRIDIS[j][c] + (VIRIDIS[j + 1][c] - VIRIDIS[j][c]) * t);
  }
  return lut;
})();
const GREY = [55, 65, 81];
// RGBA pixels, row 0 at the top (largest y). Log scale: counts span orders of
// magnitude, and a linear one shows only the densest bins.
export function densityPixels(d: Density, bins = BINS): Uint8ClampedArray {
  const px = new Uint8ClampedArray(bins * bins * 4);
  const counts = d.sel ?? d.all;
  const top = Math.log1p(d.sel ? d.maxSel : d.maxAll) || 1;
  for (let by = 0; by < bins; by++) {
    const row = (bins - 1 - by) * bins;
    for (let bx = 0; bx < bins; bx++) {
      const k = by * bins + bx;
      if (!d.all[k]) continue;
      const o = (row + bx) * 4, n = counts[k];
      if (n) {
        const i = Math.round(255 * Math.log1p(n) / top) * 3;
        px[o] = COLORS[i]; px[o + 1] = COLORS[i + 1]; px[o + 2] = COLORS[i + 2];
      } else {
        px[o] = GREY[0]; px[o + 1] = GREY[1]; px[o + 2] = GREY[2];
      }
      px[o + 3] = 255;
    }
  }
  return px;
}

// The rectangle as a rule, and back: intersect(range x, range y)
export function boxRule(source: string, xcol: string, ycol: string,
                        box: { x: [number, number]; y: [number, number] } | null): Rule | null {
  if (!box) return null;
  const range = (space: string, [a, b]: [number, number]): Rule =>
    ({ source, kind: 'range', space, params: { min: Math.min(a, b), max: Math.max(a, b) } });
  return { source, kind: 'intersect', params: { parts: [range(xcol, box.x), range(ycol, box.y)] } };
}
export function boxFrom(rule: Rule | null | undefined, xcol: string, ycol: string):
    { x: [number, number]; y: [number, number] } | null {
  if (!rule || rule.kind !== 'intersect' || rule.negate) return null;
  const parts = rule.params.parts;
  const px = parts.find(p => p.kind === 'range' && p.space === xcol && !p.negate);
  const py = parts.find(p => p.kind === 'range' && p.space === ycol && !p.negate);
  if (parts.length !== 2 || !px || !py || px === py || px.kind !== 'range' || py.kind !== 'range') return null;
  return { x: [px.params.min, px.params.max], y: [py.params.min, py.params.max] };
}

// The same rectangle, give or take float noise: a rebuilt chart re-emits its
// rectangle through pixels
export function sameBox(a: Rule | null | undefined, b: Rule | null | undefined, xcol: string, ycol: string): boolean {
  if (!a || !b) return !a && !b;
  const p = boxFrom(a, xcol, ycol), q = boxFrom(b, xcol, ycol);
  if (!p || !q) return JSON.stringify(a) === JSON.stringify(b);
  const near = (u: number, v: number) => Math.abs(u - v) <= 1e-9 * (Math.abs(u) + Math.abs(v) + 1);
  return near(p.x[0], q.x[0]) && near(p.x[1], q.x[1]) && near(p.y[0], q.y[0]) && near(p.y[1], q.y[1]);
}

let _embed: Promise<any> | null = null;
const loadEmbed = () => (_embed ??= import('vega-embed').then(m => m.default));

const AXIS = { labelColor: '#9ca3af', titleColor: '#6b7280', domainColor: '#374151', tickColor: '#374151',
  gridColor: '#1f2937', labelFontSize: 10, titleFontSize: 10, titleFontWeight: 'normal' };

export function createDensityPanel(body: HTMLElement, ctx: PanelCtx): PanelHandle {
  const cols = [...(state.meta as Map<string, MetaColumn>).values()].filter(c => c.kind === 'continuous');
  const names = cols.map(c => c.name);
  const dims = names.filter(c => /umap|tsne|pca/i.test(c));
  const xDef = dims.find(c => /1$|_x$/i.test(c)) ?? dims[0] ?? names[0];
  const yDef = dims.find(c => /2$|_y$/i.test(c)) ?? dims[1] ?? names[1] ?? xDef;
  const ctrls = buildControlBar(body, [
    { key: 'x', label: 'x', options: names, value: xDef },
    { key: 'y', label: 'y', options: names, value: yDef },
  ], [
    { icon: 'square-dashed', title: 'select: drag a rectangle (Shift+drag or the middle button pans)', toggle: 'mode', active: true,
      onClick: () => setMode('select') },
    { icon: 'hand', title: 'pan', toggle: 'mode', onClick: () => setMode('pan') },
    // Re-embedding resets the zoom; the rectangle comes back from its rule
    { icon: 'maximize-2', title: 'zoom to fit (the wheel zooms)', onClick: () => draw() },
  ]) as Record<string, HTMLSelectElement>;
  const area: HTMLElement = chartArea(body);
  // Vega's canvas (transparent) over ours, which holds the bins
  area.style.position = 'relative';
  const host = Object.assign(document.createElement('div'), { style: 'position:absolute;inset:0;z-index:1' });
  const tex = Object.assign(document.createElement('canvas'), {
    style: 'position:absolute;z-index:0;pointer-events:none;image-rendering:pixelated' });
  const bins = Object.assign(document.createElement('canvas'), { width: BINS, height: BINS });
  area.replaceChildren(host, tex);
  const source = ctx.id === 'density' ? 'density' : `density:${ctx.id}`;
  let view: any = null, gen = 0, own: Rule | null = null;
  // What a plain drag does; Shift+drag or the middle button pans in either. Vega's event filters
  // cannot read signals, so a switch rebuilds the chart at the same zoom.
  let mode: 'select' | 'pan' = 'select';
  function setMode(m: 'select' | 'pan') {
    if (m === mode) return;
    mode = m;
    draw(true);
  }
  let xc: MetaColumn, yc: MetaColumn;
  const unsub: (() => void)[] = [];

  const ruleOf = (): Rule | null => store.getState().rules[source] ?? null;
  const fg = (): Uint8Array | null => {
    const s = store.getState();
    return s.combine === 'and' ? maskExcept(source) : s.selection.mask;
  };
  const paneSize = () => ({ width: Math.max(area.clientWidth, 120), height: Math.max(area.clientHeight, 120) });

  // Our canvas over Vega's plot area, at device resolution. Vega draws the
  // plot at its padding plus origin(); origin() alone is 5 px short.
  function place() {
    if (!view) return;
    const c = host.querySelector('svg');
    if (!c) return;
    const a = area.getBoundingClientRect(), r = c.getBoundingClientRect(), pad = view.padding();
    const ox = view.origin()[0] + pad.left, oy = view.origin()[1] + pad.top;
    const w = view.width(), h = view.height(), dpr = window.devicePixelRatio || 1;
    Object.assign(tex.style, { left: `${r.left - a.left + ox}px`, top: `${r.top - a.top + oy}px`,
      width: `${w}px`, height: `${h}px` });
    const pw = Math.max(1, Math.round(w * dpr)), ph = Math.max(1, Math.round(h * dpr));
    if (tex.width !== pw || tex.height !== ph) { tex.width = pw; tex.height = ph; }
    paint();
  }
  // Counts over all cells for the current columns and domains, kept: only
  // the foreground changes with the selection
  let allFor: { x: MetaColumn; y: MetaColumn; dx: number[]; dy: number[]; d: Density } | null = null;
  const domains = () => [view.scale('x').domain(), view.scale('y').domain()] as [number, number][];
  function allCounts(): Density {
    const [dx, dy] = domains();
    const a = allFor;
    if (a && a.x === xc && a.y === yc && a.dx[0] === dx[0] && a.dx[1] === dx[1] && a.dy[0] === dy[0] && a.dy[1] === dy[1])
      return a.d;
    const d = binDensity(xc, yc, null, BINS, dx, dy);
    allFor = { x: xc, y: yc, dx, dy, d };
    return d;
  }
  // The bins over the plot's current domains, stretched over the plot area;
  // synchronous, so nothing flashes. `live`: counts from a drag (adr/0013).
  function paint(live?: Uint32Array) {
    if (!xc || !yc || !view) return;
    const [dx, dy] = domains();
    const d = live ? withSel(allCounts(), live) : binDensity(xc, yc, fg(), BINS, dx, dy, allCounts());
    bins.getContext('2d')!.putImageData(new ImageData(densityPixels(d) as any, BINS, BINS), 0, 0);
    const g = tex.getContext('2d')!;
    g.imageSmoothingEnabled = false;
    g.clearRect(0, 0, tex.width, tex.height);
    g.drawImage(bins, 0, 0, tex.width, tex.height);
  }
  type Domains = { x: [number, number]; y: [number, number] };
  function spec(box: Domains | null, zoom: Domains | null) {
    const x = { field: 'x', type: 'quantitative', title: xc.name, scale: { domain: [xc.min, xc.max], nice: false, zero: false } };
    const y = { field: 'y', type: 'quantitative', title: yc.name, scale: { domain: [yc.min, yc.max], nice: false, zero: false } };
    // The wheel zooms the plot rather than resizing the rectangle. A left
    // drag draws or moves the rectangle in select mode, and pans in pan mode
    // or with Shift held; a middle drag always pans, as in the spatial view.
    // Vega-Lite's default events take any button, so the filters name them.
    const drag = (when: string) => `[pointerdown[${when}], window:pointerup] > window:pointermove!`;
    const pan = mode === 'pan';
    const selecting = drag(pan ? 'false' : 'event.button === 0 && !event.shiftKey');
    const panning = drag(pan ? 'event.button === 0 || event.button === 1' : 'event.button === 1 || event.shiftKey');
    const brush = { name: 'brush', select: { type: 'interval', encodings: ['x', 'y'], zoom: false,
        on: selecting, translate: selecting },
      ...(box && { value: { x: box.x, y: box.y } }) };
    const nav = { name: 'nav', bind: 'scales', select: { type: 'interval', encodings: ['x', 'y'],
      translate: panning, zoom: 'wheel!', clear: false }, ...(zoom && { value: zoom }) };
    // An invisible rect over the full range carries the scales and the brush
    const layer = [{ data: { values: [{ x: xc.min, x2: xc.max, y: yc.min, y2: yc.max }] }, params: [brush, nav],
      mark: { type: 'rect', fillOpacity: 0, strokeOpacity: 0 },
      encoding: { x, x2: { field: 'x2' }, y, y2: { field: 'y2' } } }];
    return {
      ...paneSize(), autosize: { type: 'fit', contains: 'padding' }, background: 'transparent',
      layer,
      // No grid: it would be drawn over the bins
      config: { view: { stroke: null }, axis: { ...AXIS, grid: false } },
    };
  }

  // A drag of the rectangle is live: the rule is set on release
  let latest: any = null, frame = 0, down = false;
  const boxOf = (v: any): [number, number][] | null =>
    v?.x && v?.y ? [[Math.min(...v.x), Math.max(...v.x)], [Math.min(...v.y), Math.max(...v.y)]] : null;
  function commit() {
    const b = boxOf(latest);
    const rule = b ? boxRule(source, xc.name, yc.name, { x: b[0], y: b[1] }) : null;
    if (sameBox(rule, ruleOf(), xc.name, yc.name)) return;
    own = rule;
    actions.setRule(source, rule);
  }
  function release() {
    down = false;
    if (liveSource() !== source) return;
    cancelAnimationFrame(frame); frame = 0;
    endLive();
    commit();
  }
  // No autoscroll on a middle press, which pans
  host.addEventListener('mousedown', e => { if (e.button === 1) e.preventDefault(); });
  host.addEventListener('pointerdown', e => {
    if (e.button !== 0) return;
    down = true;
    window.addEventListener('pointerup', release, { once: true });
    window.addEventListener('pointercancel', release, { once: true });
  }, true);
  host.addEventListener('pointerenter', () => { if (xc && yc) prepareLive([xc, yc]); });

  // `keepZoom`: rebuild at the current zoom (a tool switch)
  async function draw(keepZoom = false) {
    const zoom: Domains | null = keepZoom && view
      ? { x: view.scale('x').domain(), y: view.scale('y').domain() } : null;
    const my = ++gen;
    view?.finalize(); view = null;
    const x = state.meta.get(ctrls.x.value), y = state.meta.get(ctrls.y.value);
    if (!x || !y) return;
    xc = x; yc = y;
    ctx.setTitle(`${x.name} × ${y.name}`);
    const embed = await loadEmbed();
    if (my !== gen) return;
    own = ruleOf();
    const res = await embed(host, spec(boxFrom(own, x.name, y.name), zoom), { actions: false, renderer: 'svg' });
    if (my !== gen) { res.view.finalize(); return; }
    view = res.view;
    place();
    fit();
    // Zoomed or panned: rebin over the new domains once Vega has drawn the
    // axes (their labels can move the plot area)
    let moved = 0;
    view.addSignalListener('nav', () => {
      moved ||= requestAnimationFrame(() => { moved = 0; if (my === gen) place(); });
    });
    // The latest brush once per frame: moved live while the button is down,
    // otherwise (drawn from a rule) set at once
    cancelAnimationFrame(frame); frame = 0;
    view.addSignalListener('brush', (_: string, v: any) => {
      latest = v;
      frame ||= requestAnimationFrame(() => {
        frame = 0;
        if (my !== gen) return;
        if (!down) { commit(); return; }
        if (liveSource() !== source) beginLive(source, [xc, yc]);
        moveLive(boxOf(latest));
      });
    });
  }

  // A selection change repaints the bins only; Vega is not involved
  const refresh = () => { if (view) paint(); };

  // The pane may be laid out while the chart is still being built
  function fit() {
    const { width, height } = paneSize();
    if (view && (width !== view.width() || height !== view.height()))
      view.width(width).height(height).runAsync().then(place);
  }
  const resize = new ResizeObserver(fit);
  resize.observe(area);
  unsub.push(() => resize.disconnect());

  const onAxis = () => {
    own = null;
    actions.setRule(source, null);
    draw();
  };
  ctrls.x.addEventListener('change', onAxis);
  ctrls.y.addEventListener('change', onAxis);
  // A rule set or dropped elsewhere: draw the rectangle to match
  unsub.push(store.subscribe(s => s.rules, () => {
    const r = ruleOf();
    if (r === own || (xc && sameBox(r, own, xc.name, yc.name))) return;
    own = r;
    draw(true);
  }));
  // Bins that follow another panel's drag
  unsub.push(addLiveConsumer({
    source: () => source,
    bins: () => {
      if (!view || !xc || !yc || !ctx.visible()) return null;
      const [dx, dy] = domains();
      return { bins: BINS * BINS, bin: binner(xc, yc, BINS, dx, dy) };
    },
    show: sel => paint(sel),
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
      if (liveSource() === source) endLive();
      unsub.forEach(u => u());
      actions.setRule(source, null);
      view?.finalize(); view = null;
    },
  };
}
