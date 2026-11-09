// The cells panel: colour the cells by a metadata column (store `colorBy`,
// also set from R by color_by()) and its legend. A note until metadata arrives.
import { state } from '../core/state.js';
import { store, actions } from '../core/store.ts';
// @ts-ignore: plain JS module
import { escapeHtml } from '../ui/dom.js';
import type { Legend } from '../render/colors.ts';
import type { PanelHandle } from './dock.ts';

const LEGEND_MAX = 30;

function renderLegend(el: HTMLElement, lg: Legend | null) {
  if (!lg) { el.innerHTML = ''; return; }
  if (lg.type === 'continuous') {
    el.innerHTML =
      `<div class="legend-gradient"></div>` +
      `<div class="legend-labels"><span>${lg.min.toFixed(2)}</span><span>${lg.max.toFixed(2)}</span></div>`;
    return;
  }
  el.innerHTML = lg.items.slice(0, LEGEND_MAX).map(({ label, color }) =>
    `<div class="legend-item">` +
    `<span class="legend-dot" style="background:rgb(${color[0]},${color[1]},${color[2]})"></span>` +
    `<span class="legend-label">${escapeHtml(label)}</span></div>`
  ).join('') + (lg.items.length > LEGEND_MAX
    ? `<div class="legend-overflow">+${lg.items.length - LEGEND_MAX} more</div>` : '');
}

export function createCellsPanel(body: HTMLElement): PanelHandle {
  const root = Object.assign(document.createElement('div'), { className: 'ctl-body' });
  const note = Object.assign(document.createElement('div'), {
    className: 'panel-note', textContent: 'Push metadata from R to colour the cells: viewer$push_metadata(g)' });
  const row = Object.assign(document.createElement('div'), { className: 'alpha-row' });
  const select = Object.assign(document.createElement('select'), { className: 'ctl-select color-by' });
  const legend = Object.assign(document.createElement('div'), { className: 'cells-legend' });
  row.append(Object.assign(document.createElement('label'), { textContent: 'color by' }), select);
  root.append(row, legend);
  body.append(note, root);
  select.addEventListener('change', () => actions.setColorBy(select.value || null));

  // Options follow the metadata table, the legend the colouring; both bump
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
    renderLegend(legend, state.colorLegend as Legend | null);
  };
  update();
  const unsub = [
    store.subscribe(s => s.metaVersion, update),
    store.subscribe(s => s.colorBy, c => { select.value = c ?? ''; }),
  ];

  return { destroy() { unsub.forEach(u => u()); } };
}
