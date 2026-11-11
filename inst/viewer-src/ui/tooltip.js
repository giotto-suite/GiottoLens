import { state } from '../core/state.js';
import { store } from '../core/store.ts';
import { cellId } from '../data/cells.ts';
import { metaValue, onColumnsLoaded, prefetchState } from '../data/meta.ts';
import { escapeHtml } from './dom.js';

function fmtVal(v) {
  if (v == null) return 'NA';
  if (typeof v === 'number') {
    if (!isFinite(v)) return String(v);
    if (Number.isInteger(v)) return String(v);
    const a = Math.abs(v);
    if (a !== 0 && (a < 1e-3 || a >= 1e6)) return v.toExponential(2);
    return v.toFixed(a < 1 ? 4 : 3);
  }
  return String(v);
}

const MAX_ROWS = 12;
let _shown = null;   // { idx, x, y } of the visible tooltip

function buildHTML(idx) {
  const id = cellId(state.cells, idx, () => { if (_shown?.idx === idx) showCellTooltip(idx, _shown.x, _shown.y); });
  let html = `<div class="ctt-id">${escapeHtml(id ?? `cell ${idx}`)}</div>`;
  if (!state.metaInfo?.size) return html;

  // Loaded columns, in payload order with the colour-by column first; the
  // others are on their way (the background load) or not loaded (over budget)
  const colorBy = store.getState().colorBy;
  const names = [...state.metaInfo.keys()].filter(k => state.meta?.has(k));
  const ordered = colorBy && names.includes(colorBy) ? [colorBy, ...names.filter(k => k !== colorBy)] : names;
  const unloaded = state.metaInfo.size - names.length;
  html += `<div class="ctt-sep"></div>`;
  html += ordered.slice(0, MAX_ROWS).map(k =>
    `<div class="ctt-row"><span class="ctt-key">${escapeHtml(k)}</span>` +
    `<span class="ctt-val">${escapeHtml(fmtVal(metaValue(state.meta.get(k), idx)))}</span></div>`
  ).join('');
  if (ordered.length > MAX_ROWS)
    html += `<div class="ctt-overflow">+${ordered.length - MAX_ROWS} more</div>`;
  if (unloaded)
    html += `<div class="ctt-overflow">+${unloaded} ${['idle', 'loading'].includes(prefetchState()) ? 'loading…' : 'not loaded'}</div>`;
  return html;
}

// Columns that arrive while the tooltip is up show at once
onColumnsLoaded(() => { if (_shown) showCellTooltip(_shown.idx, _shown.x, _shown.y); });

function isSuppressed() {
  return state.lassoActive || state.brushDown
      || state.drawRing.length > 0 || state.rectStart != null;
}

export function showCellTooltip(idx, x, y) {
  const el = document.getElementById('cell-tooltip');
  if (!el || idx == null || !state.cells || isSuppressed()) { hideCellTooltip(); return; }
  _shown = { idx, x, y };
  el.innerHTML = buildHTML(idx);

  const paneRect = document.getElementById('spatial-pane').getBoundingClientRect();
  el.style.left = '0px';
  el.style.top  = '0px';
  el.classList.add('visible');
  const tipRect = el.getBoundingClientRect();
  const margin  = 12;
  let lx = x + 14;
  let ly = y + 14;
  if (lx + tipRect.width + margin > paneRect.width) lx = x - tipRect.width - 14;
  if (ly + tipRect.height + margin > paneRect.height) ly = y - tipRect.height - 14;
  el.style.left = `${Math.max(margin, lx)}px`;
  el.style.top  = `${Math.max(margin, ly)}px`;
}

export function hideCellTooltip() {
  _shown = null;
  document.getElementById('cell-tooltip')?.classList.remove('visible');
}
