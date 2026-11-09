// The cells panel: color the cells by a metadata column (store `colorBy`,
// also set from R by color_by()), "treat as" for numeric columns, and its
// legend. A continuous column's legend edits its color scale: a preset menu
// (or custom colors, 2 to 9, each editable), reverse and reset. A categorical
// column's legend edits each category's color, visibility and fill opacity.
// A note until metadata arrives.
import { state } from '../core/state.js';
import { store, actions } from '../core/store.ts';
// @ts-ignore: plain JS module
import { sendToR } from '../core/comms.js';
// @ts-ignore: plain JS module
import { escapeHtml } from '../ui/dom.js';
import { SCALE_PRESETS, DEFAULT_SCALE, MAX_SCALE_COLORS, continuousColor } from '../render/colors.ts';
import type { Legend } from '../render/colors.ts';
import type { PanelHandle } from './dock.ts';

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
  el.innerHTML =
    `<div class="scale-row">` +
    `<select class="ctl-select scale-preset" title="color scale">` +
    Object.keys(SCALE_PRESETS).map(p => `<option value="${p}">${p}</option>`).join('') +
    `<option value="custom">custom</option></select>` +
    `<label class="scale-rev" title="reverse the scale"><input type="checkbox" class="scale-reverse">reverse</label>` +
    `<button class="scale-btn scale-reset" title="default scale">reset</button></div>` +
    `<div class="legend-gradient"></div>` +
    `<div class="legend-labels"><span></span><span></span></div>` +
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
  el.ondblclick = null;
  el.onchange = (e: Event) => {
    const t = e.target as HTMLInputElement;
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
}

function syncScale(el: HTMLElement, lg: ContinuousLegend) {
  (el.querySelector('.scale-preset') as HTMLSelectElement).value = lg.scale.preset ?? DEFAULT_SCALE;
  (el.querySelector('.scale-reverse') as HTMLInputElement).checked = !!lg.scale.reverse;
  (el.querySelector('.legend-gradient') as HTMLElement).style.background = gradient(lg.stops);
  const [lo, hi] = el.querySelectorAll('.legend-labels span');
  lo.textContent = lg.min.toFixed(2);
  hi.textContent = lg.max.toFixed(2);
  el.querySelectorAll<HTMLElement>('.scale-stop').forEach(sp => {
    const inp = sp.querySelector('.scale-color') as HTMLInputElement;
    if (document.activeElement !== inp) inp.value = hex(lg.scale.colors![Number(sp.dataset.k)]);
  });
}

export function createCellsPanel(body: HTMLElement): PanelHandle {
  const root = Object.assign(document.createElement('div'), { className: 'ctl-body' });
  const note = Object.assign(document.createElement('div'), {
    className: 'panel-note', textContent: 'Push metadata from R to color the cells: viewer$push_metadata(g)' });
  const row = Object.assign(document.createElement('div'), { className: 'alpha-row' });
  const select = Object.assign(document.createElement('select'), { className: 'ctl-select color-by' });
  const typeRow = Object.assign(document.createElement('div'), { className: 'alpha-row cells-type' });
  const typeSel = Object.assign(document.createElement('select'), {
    className: 'ctl-select type-select', title: 'show this numeric column as a continuous scale or as categories' });
  typeSel.append(...['continuous', 'categorical'].map(t =>
    Object.assign(document.createElement('option'), { value: t, textContent: t })));
  const legend = Object.assign(document.createElement('div'), { className: 'cells-legend' });
  row.append(Object.assign(document.createElement('label'), { textContent: 'color by' }), select);
  typeRow.append(Object.assign(document.createElement('label'), { textContent: 'treat as' }), typeSel);
  root.append(row, typeRow, legend);
  body.append(note, root);
  select.addEventListener('change', () => actions.setColorBy(select.value || null));

  // "treat as": numeric columns only; R sends the metadata again with the new type
  let typeTimer: ReturnType<typeof setTimeout> | undefined;
  const syncType = () => {
    const col = store.getState().colorBy;
    const m = col ? state.meta?.get(col) : null;
    typeRow.style.display = m?.numeric ? '' : 'none';
    if (m?.numeric) { typeSel.value = m.kind; typeSel.disabled = false; }
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

  // Options follow the metadata table, the legend the coloring; both bump
  // metaVersion
  let metaFor: unknown;
  const update = () => {
    if (state.meta !== metaFor) {
      metaFor = state.meta;
      const cols = [...(state.meta?.keys() ?? [])] as string[];
      select.replaceChildren(...['', ...cols].map(c =>
        Object.assign(document.createElement('option'), { value: c, textContent: c || 'none' })));
      note.style.display = cols.length ? 'none' : '';
      root.style.display = cols.length ? '' : 'none';
    }
    select.value = store.getState().colorBy ?? '';
    syncType();
    renderLegend();
  };
  update();
  const unsub = [
    store.subscribe(s => s.metaVersion, update),
    store.subscribe(s => s.colorBy, c => { select.value = c ?? ''; syncType(); }),
  ];

  return { destroy() { clearTimeout(typeTimer); unsub.forEach(u => u()); } };
}
