// The cells panel: color the cells by a field (store `colorBy`, also set
// from R by color_by()): a metadata column, or an item of the object chosen
// with the picker (panels/picker.ts) and kept in the menu's "recent" group,
// so genes never crowd the metadata list. "Treat as" for numeric columns
// (and text whose values are all numbers, to continuous), and the legend. A
// continuous column's legend edits its color scale with Giotto's options:
// style (divergent or sequential), a preset menu (or custom colors, 2 to 9,
// each editable), reverse, and low, mid and high handles on the bar (limits
// and divergent midpoint; double-click: back to automatic), and reset. A categorical
// column's legend edits each category's color, visibility and fill opacity.
// Cell outline color, width and opacity below. A note until metadata arrives.
import { state } from '../core/state.js';
import { store, actions, initialConfig } from '../core/store.ts';
// @ts-ignore: plain JS module
import { sendToR } from '../core/comms.js';
// @ts-ignore: plain JS module
import { escapeHtml } from '../ui/dom.js';
import {
  MAX_SCALE_COLORS, continuousColor, DIVERGENT_PRESETS, SEQUENTIAL_PRESETS, scalePreset, scaleStyle,
  SLIDER_STEPS, sliderToValue, valueToSlider, dragHandle, autoHandle, barColors,
} from '../render/colors.ts';
import type { ColorScale, ScaleHandle } from '../render/colors.ts';
import type { Legend } from '../render/colors.ts';
import type { PanelHandle } from './dock.ts';
import { isItemKey, fieldLabel } from '../data/items.ts';
import { openPicker } from './picker.ts';

const LEGEND_MAX = 30;
const TYPE_TIMEOUT_MS = 5000;
const FOCUS_OTHERS = 0.2;
type RGB = [number, number, number];
type ContinuousLegend = Extract<Legend, { type: 'continuous' }>;

const hex = (c: number[]) => '#' + c.slice(0, 3).map(v => v.toString(16).padStart(2, '0')).join('');
const rgb = (h: string): RGB => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16)) as RGB;
const css = (c: number[]) => `rgb(${c[0]},${c[1]},${c[2]})`;
const gradient = (stops: number[][]) => `linear-gradient(to right, ${stops.map(css).join(', ')})`;

type CategoricalLegend = Extract<Legend, { type: 'categorical' }>;

// One row per category: a checkbox (color on/off), a color swatch (click to
// edit), the label (double-click: this category at full opacity, the others
// at 20%) and a fill opacity slider; "all on", "all off" and "reset" above
function buildRows(el: HTMLElement, lg: CategoricalLegend, current: () => CategoricalLegend) {
  const items = lg.items.slice(0, LEGEND_MAX);
  el.innerHTML =
    `<div class="legend-actions">` +
    `<button class="scale-btn" data-act="all-on" title="color every category">all on</button>` +
    `<button class="scale-btn" data-act="all-off" title="uncolor every category">all off</button>` +
    `<button class="scale-btn" data-act="reset" title="default colors and opacity">reset</button></div>` +
    items.map(({ label }, k) =>
      `<div class="legend-item" data-k="${k}">` +
      `<input type="checkbox" class="legend-show" title="color on/off">` +
      `<input type="color" class="legend-color" title="edit color">` +
      `<span class="legend-label" title="double-click: show only this category at full opacity">${escapeHtml(label)}</span>` +
      `<input type="range" class="legend-alpha" min="0" max="100" title="fill opacity">` +
      `<span class="legend-alpha-val"></span></div>`
    ).join('') +
    (lg.items.length > LEGEND_MAX
      ? `<div class="legend-overflow">+${lg.items.length - LEGEND_MAX} more</div>` : '');

  const column = lg.column;
  const labelOf = (row: HTMLElement) => current().items[Number(row.dataset.k)].label;
  const rowOf = (e: Event) => (e.target as HTMLElement).closest('.legend-item') as HTMLElement | null;
  el.oninput = (e: Event) => {
    const row = rowOf(e), t = e.target as HTMLInputElement;
    if (!row) return;
    if (t.classList.contains('legend-color'))
      actions.setCategoryStyles(column, { [labelOf(row)]: { color: rgb(t.value) } });
    else if (t.classList.contains('legend-alpha'))
      actions.setCategoryStyles(column, { [labelOf(row)]: { alpha: Number(t.value) / 100 } });
  };
  el.onchange = (e: Event) => {
    const row = rowOf(e), t = e.target as HTMLInputElement;
    if (row && t.classList.contains('legend-show'))
      actions.setCategoryStyles(column, { [labelOf(row)]: { show: t.checked } });
  };
  el.ondblclick = (e: Event) => {
    const row = rowOf(e);
    if (!row || !(e.target as HTMLElement).classList.contains('legend-label')) return;
    const pick = labelOf(row);
    const patch: Record<string, { show?: boolean; alpha: number }> = {};
    for (const { label } of current().items)
      patch[label] = label === pick ? { show: true, alpha: 1 } : { alpha: FOCUS_OTHERS };
    actions.setCategoryStyles(column, patch);
  };
  el.onclick = (e: Event) => {
    const act = ((e.target as HTMLElement).closest('button') as HTMLElement | null)?.dataset.act;
    if (!act) return;
    if (act === 'reset') { actions.resetCategoryStyles(column); return; }
    const patch: Record<string, { show: boolean }> = {};
    for (const { label } of current().items) patch[label] = { show: act === 'all-on' };
    actions.setCategoryStyles(column, patch);
  };
}

function syncRows(el: HTMLElement, lg: CategoricalLegend) {
  el.querySelectorAll<HTMLElement>('.legend-item').forEach(row => {
    const it = lg.items[Number(row.dataset.k)];
    const show  = row.querySelector('.legend-show') as HTMLInputElement;
    const color = row.querySelector('.legend-color') as HTMLInputElement;
    const alpha = row.querySelector('.legend-alpha') as HTMLInputElement;
    const val   = row.querySelector('.legend-alpha-val') as HTMLElement;
    show.checked = it.show;
    if (document.activeElement !== color) color.value = hex(it.color);
    alpha.value = String(Math.round(it.alpha * 100));
    alpha.disabled = !it.show;
    val.textContent = alpha.value;
    row.classList.toggle('legend-off', !it.show);
  });
}

// The scale editor's DOM, for one column and one number of custom colors
function buildScale(el: HTMLElement, lg: ContinuousLegend, current: () => ContinuousLegend) {
  const custom = lg.scale.preset === 'custom';
  const n = custom ? lg.scale.colors?.length ?? 0 : 0;
  const opts = (ps: string[]) => ps.map(p => `<option value="${p}">${p}</option>`).join('');
  el.innerHTML =
    `<div class="scale-row">` +
    `<select class="ctl-select scale-style" title="gradient style, as Giotto's gradient_style">` +
    `<option value="divergent">divergent</option><option value="sequential">sequential</option></select>` +
    `<select class="ctl-select scale-preset" title="colors">` +
    `<optgroup label="divergent">${opts(DIVERGENT_PRESETS)}</optgroup>` +
    `<optgroup label="sequential">${opts(SEQUENTIAL_PRESETS)}</optgroup>` +
    `<option value="custom">custom</option></select></div>` +
    `<div class="scale-row">` +
    `<label class="scale-rev" title="reverse the scale"><input type="checkbox" class="scale-reverse">reverse</label>` +
    `<button class="scale-btn scale-reset" title="Giotto's default scale">reset</button></div>` +
    `<div class="scale-bar"><div class="legend-gradient"></div>` +
    [['lo', 'low: values below take the low color; double-click: the minimum'],
     ['mid', 'mid: the middle color; double-click: the median'],
     ['hi', 'high: values above take the high color; double-click: the maximum']].map(([k, tip]) =>
      `<span class="scale-handle scale-h-${k}" data-handle="${k}" title="${tip}"></span>`).join('') +
    `</div>` +
    `<div class="scale-bar-labels">` + ['lo', 'mid', 'hi'].map(k => `<span data-for="${k}"></span>`).join('') +
    `</div>` +
    (custom
      ? `<div class="scale-colors">` +
        Array.from({ length: n }, (_, k) =>
          `<span class="scale-stop" data-k="${k}">` +
          `<input type="color" class="scale-color" title="color ${k + 1} (low to high)">` +
          (n > 2 ? `<button class="scale-btn scale-del" title="remove this color">×</button>` : '') +
          `</span>`).join('') +
        (n < MAX_SCALE_COLORS ? `<button class="scale-btn scale-add" title="add a color at the high end">+</button>` : '') +
        `</div>`
      : '');

  const column = lg.column;
  el.onchange = (e: Event) => {
    const t = e.target as HTMLInputElement;
    if (t.classList.contains('scale-style')) { actions.setColorScale(column, { style: t.value as ColorScale['style'] }); return; }
    if (t.classList.contains('scale-preset')) {
      if (t.value === 'custom') {
        // start from the colors on screen, at most 5
        const st = current().stops;
        const k = Math.min(st.length, 5);
        const colors = Array.from({ length: k }, (_, i) => continuousColor(i / (k - 1), st).slice(0, 3) as RGB);
        actions.setColorScale(column, { preset: 'custom', colors, reverse: false });
      } else actions.setColorScale(column, { preset: t.value });
    } else if (t.classList.contains('scale-reverse'))
      actions.setColorScale(column, { reverse: t.checked });
  };
  // Handle drags recolor at most once a frame
  let pending: Partial<ColorScale> | null = null;
  let drag: HTMLElement | null = null;
  const flush = () => {
    const p = pending;
    pending = null;
    if (p) actions.setColorScale(column, p);
  };
  const barValue = (e: PointerEvent) => {
    const c = current();
    const rect = (el.querySelector('.scale-bar') as HTMLElement).getBoundingClientRect();
    const f = Math.max(0, Math.min(1, (e.clientX - rect.left) / (rect.width || 1)));
    return sliderToValue(f * SLIDER_STEPS, c.min, c.max);
  };
  const moveTo = (which: ScaleHandle, v: number) => {
    const c = current();
    const first = !pending;
    const r = { lo: pending?.limits?.[0] ?? c.lo, hi: pending?.limits?.[1] ?? c.hi, min: c.min, max: c.max };
    pending = { ...pending, ...dragHandle(which, v, r) };
    if (first) requestAnimationFrame(flush);
  };
  el.onpointerdown = (e: PointerEvent) => {
    const tgt = e.target as HTMLElement;
    const bar = tgt.closest('.scale-bar');
    if (!bar || e.button !== 0) return;
    const c = current();
    if (!(c.max > c.min)) return;
    let h = tgt.closest('.scale-handle') as HTMLElement | null;
    if (!h) {
      // A press on the bar takes the nearest handle there
      const v = barValue(e);
      const at = { lo: c.lo, mid: c.mid, hi: c.hi };
      const near = [...bar.querySelectorAll<HTMLElement>('.scale-handle')].filter(x => x.style.display !== 'none')
        .map(x => [x, Math.abs(at[x.dataset.handle as ScaleHandle] - v)] as const)
        .sort((p, q) => p[1] - q[1]);
      h = near[0]?.[0] ?? null;
      if (!h) return;
      moveTo(h.dataset.handle as ScaleHandle, v);
    }
    e.preventDefault();
    try { h.setPointerCapture(e.pointerId); } catch (_) { /* a synthetic pointer */ }
    h.classList.add('scale-h-drag');
    drag = h;
  };
  el.onpointermove = (e: PointerEvent) => { if (drag) moveTo(drag.dataset.handle as ScaleHandle, barValue(e)); };
  el.onpointerup = el.onpointercancel = () => {
    drag?.classList.remove('scale-h-drag');
    drag = null;
  };
  el.oninput = (e: Event) => {
    const t = e.target as HTMLInputElement;
    if (!t.classList.contains('scale-color')) return;
    const k = Number((t.closest('.scale-stop') as HTMLElement).dataset.k);
    const colors = (current().scale.colors ?? []).map(c => [...c] as RGB);
    colors[k] = rgb(t.value);
    actions.setColorScale(column, { colors });
  };
  el.onclick = (e: Event) => {
    const b = (e.target as HTMLElement).closest('button');
    if (!b) return;
    if (b.classList.contains('scale-reset')) { actions.resetColorScale(column); return; }
    const colors = (current().scale.colors ?? []).map(c => [...c] as RGB);
    if (b.classList.contains('scale-add')) colors.push([...colors[colors.length - 1]] as RGB);
    else if (b.classList.contains('scale-del'))
      colors.splice(Number((b.closest('.scale-stop') as HTMLElement).dataset.k), 1);
    else return;
    actions.setColorScale(column, { colors });
  };
  el.ondblclick = (e: Event) => {
    const h = (e.target as HTMLElement).closest('.scale-handle') as HTMLElement | null;
    if (!h) return;
    const c = current();
    actions.setColorScale(column, autoHandle(h.dataset.handle as ScaleHandle,
      { lo: c.lo, hi: c.hi, min: c.min, max: c.max }));
  };
}

const fmt = (x: number) => (Number.isInteger(x) ? String(x) : Math.abs(x) >= 100 ? x.toFixed(0) : x.toPrecision(3));

function syncScale(el: HTMLElement, lg: ContinuousLegend) {
  (el.querySelector('.scale-style') as HTMLSelectElement).value = scaleStyle(lg.scale);
  (el.querySelector('.scale-preset') as HTMLSelectElement).value = scalePreset(lg.scale);
  (el.querySelector('.scale-reverse') as HTMLInputElement).checked = !!lg.scale.reverse;
  // The bar spans the data range, in the color each value is drawn in
  (el.querySelector('.legend-gradient') as HTMLElement).style.background = gradient(barColors(lg));
  const divergent = lg.style === 'divergent';
  const vals = { lo: lg.lo, mid: lg.mid, hi: lg.hi };
  const auto = { lo: lg.scale.limits == null, mid: lg.scale.midpoint == null, hi: lg.scale.limits == null };
  for (const k of ['lo', 'mid', 'hi'] as ScaleHandle[]) {
    const show = k !== 'mid' || divergent;
    const left = `${(valueToSlider(vals[k], lg.min, lg.max) / SLIDER_STEPS) * 100}%`;
    const h = el.querySelector(`.scale-handle[data-handle=${k}]`) as HTMLElement;
    h.style.display = show ? '' : 'none';
    h.style.left = left;
    h.classList.toggle('scale-h-auto', auto[k]);
    const lab = el.querySelector(`.scale-bar-labels [data-for=${k}]`) as HTMLElement;
    lab.style.display = show ? '' : 'none';
    lab.style.left = left;
    lab.textContent = fmt(vals[k]);
  }
  el.querySelectorAll<HTMLElement>('.scale-stop').forEach(sp => {
    const inp = sp.querySelector('.scale-color') as HTMLInputElement;
    if (document.activeElement !== inp) inp.value = hex(lg.scale.colors![Number(sp.dataset.k)]);
  });
}

// Cell outline color (picker, presets), width (log-scale slider
// from 0.01 to 20 px and a number box), opacity and reset (store `outline`,
// also set from R by set_outline())
// Outline color, width and opacity: the cells' (store `outline`), or the
// annotations' (`annotOutline`, panels/layers.ts)
// The first preset is each one's default colour
const OUTLINE_ACTIONS = {
  outline:      { set: actions.setOutline, reset: actions.resetOutline,
                  presets: [['#000000', 'black'], ['#ffffff', 'white'], ['#9ca3af', 'gray'], ['#d62728', 'red']] },
  annotOutline: { set: actions.setAnnotOutline, reset: actions.resetAnnotOutline,
                  presets: [['#64c8ff', 'blue'], ['#ffffff', 'white'], ['#9ca3af', 'gray'], ['#d62728', 'red']] },
};
export function createOutlineSection(key: keyof typeof OUTLINE_ACTIONS = 'outline'): { el: HTMLElement; destroy(): void } {
  const { set, reset, presets } = OUTLINE_ACTIONS[key];
  const d = initialConfig()[key];
  const el = Object.assign(document.createElement('div'), { className: 'ctl-body cells-outline' });
  el.innerHTML =
    `<div class="ctl-subhead">outlines</div>` +
    `<div class="alpha-row"><label>color</label>` +
    `<input type="color" class="outline-color" title="outline color">` +
    `<span class="outline-presets">` +
    presets.map(([c, name]) =>
      `<button class="outline-preset" data-color="${c}" style="background:${c}" title="${name}"></button>`).join('') +
    `</span></div>` +
    `<div class="alpha-row"><label>width px</label>` +
    `<input type="range" class="outline-width" min="-2" max="1.30103" step="0.01" title="width, log scale: 0.01 to 20 px">` +
    `<input type="number" class="outline-width-num" min="0.01" max="20" step="any" title="width in pixels (0.01 to 20)"></div>` +
    `<div class="alpha-row"><label>opacity</label>` +
    `<input type="range" class="outline-alpha" min="0" max="100">` +
    `<span class="alpha-val outline-alpha-val"></span></div>` +
    `<div class="alpha-row"><button class="scale-btn outline-reset" title="${hex(d.color)}, ${d.width} px, ${Math.round(d.alpha * 100)}%">reset</button></div>`;
  const q = <T extends HTMLElement>(c: string) => el.querySelector(`.${c}`) as T;
  const color = q<HTMLInputElement>('outline-color');
  const slider = q<HTMLInputElement>('outline-width'), num = q<HTMLInputElement>('outline-width-num');
  const alpha = q<HTMLInputElement>('outline-alpha'), alphaV = q<HTMLElement>('outline-alpha-val');
  const sync = ({ color: c, width, alpha: a }: { color: number[]; width: number; alpha: number }) => {
    color.value = hex(c);
    slider.value = String(Math.log10(width));
    if (document.activeElement !== num) num.value = String(width);
    alpha.value = String(Math.round(a * 100));
    alphaV.textContent = alpha.value;
  };
  sync(store.getState()[key]);
  const unsub = store.subscribe(s => s[key], sync);
  color.addEventListener('input', () => set({ color: rgb(color.value) }));
  el.querySelectorAll<HTMLElement>('.outline-preset').forEach(b =>
    b.addEventListener('click', () => set({ color: rgb(b.dataset.color!) })));
  // 4 significant digits, kept within [0.01, 20]
  slider.addEventListener('input', () => {
    const w = Math.min(20, Math.max(0.01, Number((10 ** Number(slider.value)).toPrecision(4))));
    set({ width: w });
  });
  num.addEventListener('change', () => {
    const w = Number(num.value);
    if (Number.isFinite(w) && w >= 0.01 && w <= 20) set({ width: w });
    else num.value = String(store.getState()[key].width);
  });
  alpha.addEventListener('input', () => set({ alpha: Number(alpha.value) / 100 }));
  q<HTMLButtonElement>('outline-reset').addEventListener('click', () => reset());
  return { el, destroy: unsub };
}

export function createCellsPanel(body: HTMLElement): PanelHandle {
  const root = Object.assign(document.createElement('div'), { className: 'ctl-body' });
  const note = Object.assign(document.createElement('div'), {
    className: 'panel-note', textContent: 'Push metadata from R to color the cells: viewer$push_metadata(g)' });
  const row = Object.assign(document.createElement('div'), { className: 'alpha-row' });
  const select = Object.assign(document.createElement('select'), { className: 'ctl-select color-by' });
  const browse = Object.assign(document.createElement('button'), { className: 'scale-btn color-by-browse',
    textContent: '…', title: 'pick a column or an item of the object (a gene, an enrichment, …)' });
  const typeRow = Object.assign(document.createElement('div'), { className: 'alpha-row cells-type' });
  const typeSel = Object.assign(document.createElement('select'), {
    className: 'ctl-select type-select', title: 'show this numeric column as a continuous scale or as categories' });
  typeSel.append(...['continuous', 'categorical'].map(t =>
    Object.assign(document.createElement('option'), { value: t, textContent: t })));
  const legend = Object.assign(document.createElement('div'), { className: 'cells-legend' });
  row.append(Object.assign(document.createElement('label'), { textContent: 'color by' }), select, browse);
  typeRow.append(Object.assign(document.createElement('label'), { textContent: 'treat as' }), typeSel);
  root.append(row, typeRow, legend);
  const outline = createOutlineSection();
  outline.el.style.display = state.manifest?.layers?.cells?.geometry ? '' : 'none';
  body.append(note, root, outline.el);
  select.addEventListener('change', () => actions.setColorBy(select.value || null));
  browse.addEventListener('click', () => openPicker({ anchor: browse, current: store.getState().colorBy,
    onPick: field => actions.setColorBy(field) }));

  // "treat as": numeric columns, and text whose values are all numbers; R
  // sends the metadata again with the new type
  let typeTimer: ReturnType<typeof setTimeout> | undefined;
  const syncType = () => {
    const col = store.getState().colorBy;
    const m = col ? state.metaInfo?.get(col) : null;
    const can = !!(m?.numeric || m?.numberText);
    typeRow.style.display = can ? '' : 'none';
    if (can) { typeSel.value = m!.kind; typeSel.disabled = false; }
  };
  typeSel.addEventListener('change', () => {
    const column = store.getState().colorBy;
    if (!column) return;
    for (const [src, r] of Object.entries(store.getState().rules))
      if (r && 'space' in r && r.space === column) actions.setRule(src, null);
    typeSel.disabled = true;
    sendToR('set_column_type', { column, type: typeSel.value });
    clearTimeout(typeTimer);
    typeTimer = setTimeout(syncType, TYPE_TIMEOUT_MS);
  });

  let legendKey: string | null = null;
  const current = () => state.colorLegend as ContinuousLegend;
  const renderLegend = () => {
    const lg = state.colorLegend as Legend | null;
    if (!lg) { legend.innerHTML = ''; legendKey = null; return; }
    if (lg.type === 'continuous') {
      const custom = lg.scale.preset === 'custom';
      const key = JSON.stringify(['scale', lg.column, custom, custom ? lg.scale.colors?.length : 0]);
      if (key !== legendKey) { buildScale(legend, lg, current); legendKey = key; }
      syncScale(legend, lg);
      return;
    }
    const key = JSON.stringify(['cat', lg.column, lg.items.map(i => i.label)]);
    if (key !== legendKey) { buildRows(legend, lg, () => state.colorLegend as CategoricalLegend); legendKey = key; }
    syncRows(legend, lg);
  };

  // Options follow the metadata columns and the recent items (with the item
  // shown, set from R, if it is not among them), the legend the coloring;
  // metadata and coloring bump metaVersion
  let optsFor = '';
  const option = (value: string, text: string) =>
    Object.assign(document.createElement('option'), { value, textContent: text });
  const update = () => {
    const { recentItems, colorBy } = store.getState();
    const items = isItemKey(colorBy) && !recentItems.includes(colorBy) ? [colorBy, ...recentItems] : recentItems;
    const cols = [...(state.metaInfo?.keys() ?? [])] as string[];
    const key = JSON.stringify([cols, items]);
    if (key !== optsFor) {
      optsFor = key;
      const recent = document.createElement('optgroup');
      recent.label = 'recent';
      recent.append(...items.map(k => option(k, fieldLabel(k))));
      select.replaceChildren(option('', 'none'), ...cols.map(c => option(c, c)), ...(items.length ? [recent] : []));
      const any = cols.length > 0 || !!state.manifest?.catalog;
      note.style.display = any ? 'none' : '';
      root.style.display = any ? '' : 'none';
    }
    select.value = colorBy ?? '';
    syncType();
    renderLegend();
  };
  update();
  const unsub = [
    store.subscribe(s => s.metaVersion, update),
    store.subscribe(s => s.colorBy, update),
    store.subscribe(s => s.recentItems, update),
  ];

  return { destroy() { clearTimeout(typeTimer); outline.destroy(); unsub.forEach(u => u()); } };
}
