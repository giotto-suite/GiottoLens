// The colour-by legend. Continuous columns get a colour scale editor: a preset
// menu (or custom colours, 2 to 9, each editable), reverse and reset.
// Categorical columns get one row per category: a
// checkbox (colour on/off), a colour swatch (click to edit), the label
// (double-click: this category at full opacity, the others at 20%), and a fill
// opacity slider. Rows are rebuilt only when the column or its categories
// change, so an input keeps focus while it is dragged.
import { state } from '../core/state.js';
import { actions } from '../core/store.ts';
import { escapeHtml } from './dom.js';
import { SCALE_PRESETS, MAX_SCALE_COLORS, continuousColor } from '../render/colors.ts';

const MAX_ITEMS = 30;
const FOCUS_OTHERS = 0.2;
let _key = null;   // column and labels the rows were built for

const hex = c => '#' + c.slice(0, 3).map(v => v.toString(16).padStart(2, '0')).join('');
const rgb = h => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16));

function buildRows(el, lg) {
  const items = lg.items.slice(0, MAX_ITEMS);
  el.innerHTML =
    `<div class="legend-actions">` +
    `<button data-act="all-on" title="colour every category">all on</button>` +
    `<button data-act="all-off" title="uncolour every category">all off</button>` +
    `<button data-act="reset" title="default colours and opacity">reset</button></div>` +
    items.map(({ label }, k) =>
      `<div class="legend-item" data-k="${k}">` +
      `<input type="checkbox" class="legend-show" title="colour on/off">` +
      `<input type="color" class="legend-color" title="edit colour">` +
      `<span class="legend-label" title="double-click: show only this category at full opacity">${escapeHtml(label)}</span>` +
      `<input type="range" class="legend-alpha" min="0" max="100" title="fill opacity">` +
      `<span class="legend-alpha-val"></span></div>`
    ).join('') +
    (lg.items.length > MAX_ITEMS
      ? `<div class="legend-overflow">+${lg.items.length - MAX_ITEMS} more</div>` : '');

  const column = lg.column;
  const labelOf = row => state.colorLegend.items[Number(row.dataset.k)].label;
  el.oninput = e => {
    const row = e.target.closest('.legend-item');
    if (!row) return;
    const label = labelOf(row);
    if (e.target.classList.contains('legend-color'))
      actions.setCategoryStyles(column, { [label]: { color: rgb(e.target.value) } });
    else if (e.target.classList.contains('legend-alpha'))
      actions.setCategoryStyles(column, { [label]: { alpha: e.target.value / 100 } });
  };
  el.onchange = e => {
    const row = e.target.closest('.legend-item');
    if (row && e.target.classList.contains('legend-show'))
      actions.setCategoryStyles(column, { [labelOf(row)]: { show: e.target.checked } });
  };
  el.ondblclick = e => {
    const row = e.target.closest('.legend-item');
    if (!row || !e.target.classList.contains('legend-label')) return;
    const pick = labelOf(row);
    const patch = {};
    for (const { label } of state.colorLegend.items)
      patch[label] = label === pick ? { show: true, alpha: 1 } : { alpha: FOCUS_OTHERS };
    actions.setCategoryStyles(column, patch);
  };
  el.onclick = e => {
    const act = e.target.closest('button')?.dataset.act;
    if (!act) return;
    if (act === 'reset') { actions.resetCategoryStyles(column); return; }
    const patch = {};
    for (const { label } of state.colorLegend.items) patch[label] = { show: act === 'all-on' };
    actions.setCategoryStyles(column, patch);
  };
}

function syncRows(el, lg) {
  el.querySelectorAll('.legend-item').forEach(row => {
    const it = lg.items[Number(row.dataset.k)];
    const show  = row.querySelector('.legend-show');
    const color = row.querySelector('.legend-color');
    const alpha = row.querySelector('.legend-alpha');
    const val   = row.querySelector('.legend-alpha-val');
    show.checked = it.show;
    if (document.activeElement !== color) color.value = hex(it.color);
    alpha.value = String(Math.round(it.alpha * 100));
    alpha.disabled = !it.show;
    val.textContent = alpha.value;
    row.classList.toggle('legend-off', !it.show);
  });
}

const css = c => `rgb(${c[0]},${c[1]},${c[2]})`;
const gradient = stops => `linear-gradient(to right, ${stops.map(css).join(', ')})`;

function buildScale(el, lg) {
  const custom = lg.scale.preset === 'custom';
  const n = custom ? lg.scale.colors.length : 0;
  el.innerHTML =
    `<div class="scale-row">` +
    `<select class="scale-preset" title="colour scale">` +
    Object.keys(SCALE_PRESETS).map(p => `<option value="${p}">${p}</option>`).join('') +
    `<option value="custom">custom</option></select>` +
    `<label class="scale-rev" title="reverse the scale"><input type="checkbox" class="scale-reverse">reverse</label>` +
    `<button class="scale-reset" title="default scale">reset</button></div>` +
    `<div class="legend-gradient"></div>` +
    `<div class="legend-labels"><span></span><span></span></div>` +
    (custom
      ? `<div class="scale-colors">` +
        Array.from({ length: n }, (_, k) =>
          `<span class="scale-stop" data-k="${k}">` +
          `<input type="color" class="scale-color" title="colour ${k + 1} (low to high)">` +
          (n > 2 ? `<button class="scale-del" title="remove this colour">×</button>` : '') +
          `</span>`).join('') +
        (n < MAX_SCALE_COLORS ? `<button class="scale-add" title="add a colour at the high end">+</button>` : '') +
        `</div>`
      : '');

  const column = lg.column;
  const cur = () => state.colorLegend;
  el.onchange = e => {
    if (e.target.classList.contains('scale-preset')) {
      const p = e.target.value;
      if (p === 'custom') {
        // start from the colours on screen, at most MAX_SCALE_COLORS
        const st = cur().stops;
        const k = Math.min(st.length, 5);
        const colors = Array.from({ length: k }, (_, i) => continuousColor(i / (k - 1), st).slice(0, 3));
        actions.setColorScale(column, { preset: 'custom', colors, reverse: false });
      } else actions.setColorScale(column, { preset: p });
    } else if (e.target.classList.contains('scale-reverse'))
      actions.setColorScale(column, { reverse: e.target.checked });
  };
  el.oninput = e => {
    if (!e.target.classList.contains('scale-color')) return;
    const k = Number(e.target.closest('.scale-stop').dataset.k);
    const colors = cur().scale.colors.map(c => [...c]);
    colors[k] = rgb(e.target.value);
    actions.setColorScale(column, { colors });
  };
  el.onclick = e => {
    const b = e.target.closest('button');
    if (!b) return;
    if (b.classList.contains('scale-reset')) { actions.resetColorScale(column); return; }
    const colors = cur().scale.colors.map(c => [...c]);
    if (b.classList.contains('scale-add')) colors.push([...colors[colors.length - 1]]);
    else if (b.classList.contains('scale-del')) colors.splice(Number(b.closest('.scale-stop').dataset.k), 1);
    else return;
    actions.setColorScale(column, { colors });
  };
  el.ondblclick = null;
}

function syncScale(el, lg) {
  el.querySelector('.scale-preset').value = lg.scale.preset ?? 'blue-red';
  el.querySelector('.scale-reverse').checked = !!lg.scale.reverse;
  el.querySelector('.legend-gradient').style.background = gradient(lg.stops);
  const [lo, hi] = el.querySelectorAll('.legend-labels span');
  lo.textContent = lg.min.toFixed(2);
  hi.textContent = lg.max.toFixed(2);
  el.querySelectorAll('.scale-stop').forEach(sp => {
    const inp = sp.querySelector('.scale-color');
    if (document.activeElement !== inp) inp.value = hex(lg.scale.colors[Number(sp.dataset.k)]);
  });
}

export function renderLegend() {
  const el = document.getElementById('meta-legend');
  if (!el) return;
  const lg = state.colorLegend;
  if (!lg) { el.innerHTML = ''; _key = null; return; }
  if (lg.type === 'continuous') {
    const custom = lg.scale.preset === 'custom';
    const key = JSON.stringify(['c', lg.column, custom, custom ? lg.scale.colors?.length : 0]);
    if (key !== _key) { buildScale(el, lg); _key = key; }
    syncScale(el, lg);
    return;
  }
  const key = JSON.stringify([lg.column, lg.items.map(i => i.label)]);
  if (key !== _key) { buildRows(el, lg); _key = key; }
  syncRows(el, lg);
}
