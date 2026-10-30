import { state } from '../core/state.js';
import { escapeHtml } from './dom.js';

export function renderLegend() {
  const el = document.getElementById('meta-legend');
  if (!el) return;
  const lg = state.colorLegend;
  if (!lg) { el.innerHTML = ''; return; }
  if (lg.type === 'continuous') {
    el.innerHTML =
      `<div class="legend-gradient"></div>` +
      `<div class="legend-labels"><span>${lg.min.toFixed(2)}</span><span>${lg.max.toFixed(2)}</span></div>`;
    return;
  }
  const items = lg.items.slice(0, 30);
  el.innerHTML = items.map(({ label, color }) =>
    `<div class="legend-item">` +
    `<span class="legend-dot" style="background:rgb(${color[0]},${color[1]},${color[2]})"></span>` +
    `<span class="legend-label">${escapeHtml(label)}</span></div>`
  ).join('') + (lg.items.length > 30
    ? `<div class="legend-overflow">+${lg.items.length - 30} more</div>` : '');
}
