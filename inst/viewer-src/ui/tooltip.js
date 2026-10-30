import { state } from './state.js';

function fmtVal(v) {
  if (v == null) return 'NA';
  if (typeof v === 'number') {
    if (!isFinite(v)) return String(v);
    if (Number.isInteger(v)) return String(v);
    const a = Math.abs(v);
    if (a !== 0 && (a < 1e-3 || a >= 1e6)) return v.toExponential(2);
    return v.toFixed(a < 1 ? 4 : 3);
  }
  if (typeof v === 'bigint') return v.toString();
  return String(v);
}

const MAX_ROWS = 12;

function buildHTML(id) {
  const row = state.cellMetaCache?.get(id);
  let html = `<div class="ctt-id">${id}</div>`;
  if (!row) return html;

  const keys = Object.keys(row);
  if (keys.length === 0) return html;

  const ordered = [];
  if (state.metaCol && keys.includes(state.metaCol)) ordered.push(state.metaCol);
  for (const k of keys) if (k !== state.metaCol) ordered.push(k);
  const shown = ordered.slice(0, MAX_ROWS);

  html += `<div class="ctt-sep"></div>`;
  html += shown.map(k =>
    `<div class="ctt-row"><span class="ctt-key">${k}</span>` +
    `<span class="ctt-val">${fmtVal(row[k])}</span></div>`
  ).join('');
  if (ordered.length > MAX_ROWS)
    html += `<div class="ctt-overflow">+${ordered.length - MAX_ROWS} more</div>`;
  return html;
}

function isSuppressed() {
  return state.lassoActive || state.brushDown
      || state.drawRing.length > 0 || state.rectStart != null;
}

export function showCellTooltip(id, x, y) {
  const el = document.getElementById('cell-tooltip');
  if (!el || id == null || isSuppressed()) { hideCellTooltip(); return; }
  el.innerHTML = buildHTML(id);

  const pane = document.getElementById('spatial-pane');
  const paneRect = pane.getBoundingClientRect();
  el.style.left = '0px';
  el.style.top  = '0px';
  el.classList.add('visible');
  const tipRect = el.getBoundingClientRect();
  const margin  = 12;
  let lx = x + 14;
  let ly = y + 14;
  if (lx + tipRect.width + margin > paneRect.width)
    lx = x - tipRect.width - 14;
  if (ly + tipRect.height + margin > paneRect.height)
    ly = y - tipRect.height - 14;
  el.style.left = `${Math.max(margin, lx)}px`;
  el.style.top  = `${Math.max(margin, ly)}px`;
}

export function hideCellTooltip() {
  document.getElementById('cell-tooltip')?.classList.remove('visible');
}
