// Spatial-view tools: modes, drawing, measuring, selecting, keyboard
import { state } from '../core/state.js';
import { store, actions } from '../core/store.ts';
import { requestRender } from '../render/schedule.js';
import { fetchTranscriptTile, GENE_UNKNOWN } from '../data/tiles.js';
import { lassoSpatial, brushStart, brushMove, brushEnd, invertSelection, filterMeta } from '../selection/selection.ts';
import { generateAnnotId } from './annotations.js';
import { clientToWorld, worldToClient, pointInPolygon, escapeHtml } from './dom.js';
import { hideCellTooltip } from './tooltip.js';

let _canvas = null; // set in initInput, used by exported functions above initInput scope
let _lastClickAddedVertex = false; // so a double-click only removes its own vertex

const DRAG_MODES = ['lasso', 'txlasso', 'rect', 'freehand', 'brush'];

function rulerDist(a, b) {
  const d = Math.hypot(b[0] - a[0], b[1] - a[1]);
  return d >= 1000 ? `${(d / 1000).toFixed(3)} mm` : `${d.toFixed(1)} μm`;
}

export function updateRulerLabel() {
  const label = document.getElementById('ruler-label');
  if (!label || !state.rulerStart || !state.rulerEnd) return;
  const mid = [(state.rulerStart[0] + state.rulerEnd[0]) / 2,
               (state.rulerStart[1] + state.rulerEnd[1]) / 2];
  const [sx, sy] = worldToClient(mid[0], mid[1], _canvas, state.currentViewState);
  label.style.left = `${sx + 8}px`;
  label.style.top  = `${sy - 10}px`;
  label.textContent = rulerDist(state.rulerStart, state.rulerEnd);
  label.classList.add('visible');
}

export function updateTxConnector() {
  const line  = document.getElementById('tx-connector-line');
  const panel = document.getElementById('tx-lasso-panel');
  if (!line || !panel || !state.txLassoRing?.length || !panel.classList.contains('visible')) {
    line?.setAttribute('display', 'none');
    return;
  }
  const ring = state.txLassoRing;
  const cx = ring.reduce((s, p) => s + p[0], 0) / ring.length;
  const cy = ring.reduce((s, p) => s + p[1], 0) / ring.length;
  const [sx, sy] = worldToClient(cx, cy, _canvas, state.currentViewState);
  const rect     = panel.getBoundingClientRect();
  const paneRect = document.getElementById('spatial-pane').getBoundingClientRect();
  line.setAttribute('x1', sx - paneRect.left);
  line.setAttribute('y1', sy - paneRect.top);
  line.setAttribute('x2', rect.left - paneRect.left);
  line.setAttribute('y2', rect.top  - paneRect.top);
  line.setAttribute('display', '');
}

function resetDrawing() {
  state.drawRing    = [];
  state.lassoRing   = [];
  state.lassoActive = false;
  state.rectStart   = null;
  state.rectPreview = null;
  state.brushDown   = false;
  state.brushPos    = null;
}

export function setMode(m) {
  resetDrawing();
  actions.setMode(m);
}

function applyMode(m) {
  state.deckgl.setProps({ controller: DRAG_MODES.includes(m)
    ? { dragPan: false, doubleClickZoom: false }
    : { doubleClickZoom: false } });
  document.querySelectorAll('.tool-btn[data-mode]').forEach(b =>
    b.classList.toggle('active', b.dataset.mode === m)
  );
  document.getElementById('btn-group-draw')?.classList.toggle('active',    ['poly','rect','freehand'].includes(m));
  document.getElementById('btn-group-select')?.classList.toggle('active',  ['lasso','brush'].includes(m));
  document.getElementById('btn-group-measure')?.classList.toggle('active', ['ruler','txlasso'].includes(m));
}

function clearMeasurements() {
  state.rulerStart = null; state.rulerEnd = null; state.rulerLocked = false;
  document.getElementById('ruler-label')?.classList.remove('visible');
  state.txLassoRing = null;
  document.getElementById('tx-lasso-panel')?.classList.remove('visible');
  updateTxConnector();
  requestRender();
}

// ── Transcript lasso ──────────────────────────────────────────────────────────
// Counts genes inside the ring from the same column-only tile reads used for
// drawing, reusing tiles already in the cache. Large regions belong to the
// server-side query path (state_selection.md step 7); until then, cap them.
const TX_LASSO_MAX_TILES = 100;
let _txLassoRun = 0;

async function _runTxLasso(ring) {
  const panel = document.getElementById('tx-lasso-panel');
  const title = document.getElementById('tx-lasso-title');
  const list  = document.getElementById('tx-lasso-results');
  if (!panel) return;
  const run = ++_txLassoRun;

  state.txLassoRing = ring;
  requestRender();
  title.textContent = 'querying…';
  list.replaceChildren();
  panel.classList.add('visible');
  updateTxConnector();

  try {
    const txLayer = state.manifest?.layers?.transcripts;
    if (!txLayer?.tiles?.length) { title.textContent = 'no transcript data'; return; }

    let xmin = Infinity, xmax = -Infinity, ymin = Infinity, ymax = -Infinity;
    for (const [x, y] of ring) {
      if (x < xmin) xmin = x; if (x > xmax) xmax = x;
      if (y < ymin) ymin = y; if (y > ymax) ymax = y;
    }

    const overlapping = txLayer.tiles.filter(t =>
      t.xmax > xmin && t.xmin < xmax && t.ymax > ymin && t.ymin < ymax
    );
    if (!overlapping.length) { title.textContent = '0 transcripts'; return; }
    if (overlapping.length > TX_LASSO_MAX_TILES) {
      title.textContent = `region spans ${overlapping.length} tiles; draw a smaller one`;
      return;
    }

    const counts = new Map();   // gene index → count
    const closed = [...ring, ring[0]];
    await Promise.all(overlapping.map(async t => {
      // Counts need every point: reuse a cached tile only if it was not sampled
      const cached = state.cache.get(`transcripts:${t.index}`);
      const { pos, geneIdxs } = cached?.stride === 1 ? cached : await fetchTranscriptTile(t, 1);
      if (run !== _txLassoRun) return;
      for (let i = 0; i < geneIdxs.length; i++) {
        const x = pos[i * 2], y = pos[i * 2 + 1];
        if (x < xmin || x > xmax || y < ymin || y > ymax) continue;
        if (pointInPolygon(closed, x, y)) counts.set(geneIdxs[i], (counts.get(geneIdxs[i]) ?? 0) + 1);
      }
    }));
    if (run !== _txLassoRun) return;   // a newer lasso replaced this one

    const genes  = txLayer.genes;
    const sorted = [...counts.entries()].sort((a, b) => b[1] - a[1]);
    const total  = sorted.reduce((s, [, n]) => s + n, 0);
    const top    = sorted.slice(0, 50);
    const maxN   = top[0]?.[1] ?? 1;

    title.textContent = `${total.toLocaleString()} transcripts · ${sorted.length} genes`;
    list.innerHTML = top.map(([gi, n]) => {
      const gene = escapeHtml(gi === GENE_UNKNOWN ? '(unknown)' : genes[gi]);
      return `<div class="tx-gene-row">
        <span class="tx-gene-name" title="${gene}">${gene}</span>
        <div class="tx-gene-bar-wrap"><div class="tx-gene-bar" style="width:${(n/maxN*100).toFixed(1)}%"></div></div>
        <span class="tx-gene-count">${n.toLocaleString()}</span>
      </div>`;
    }).join('');
    requestAnimationFrame(updateTxConnector);
  } catch(e) {
    if (run !== _txLassoRun) return;
    title.textContent = 'query failed';
    requestAnimationFrame(updateTxConnector);
    console.warn('[txlasso]', e);
  }
}

function addAnnotation(type, coords) {
  actions.addAnnotation({ id: generateAnnotId(), type, name: '', coords });
}

// ── Input initialization ──────────────────────────────────────────────────────
export function initInput() {
  _canvas = document.getElementById('deck-canvas');
  const canvas = _canvas;
  const world  = e => clientToWorld(e.clientX, e.clientY, canvas, state.currentViewState);
  let lassoDragged = false;
  let lassoLastPx  = null;

  store.subscribe(s => s.mode, applyMode, { fireImmediately: true });
  store.subscribe(s => s.combine, c =>
    document.getElementById('btn-crossfilter')?.classList.toggle('active', c === 'and'));

  // ── Toolbar groups ────────────────────────────────────────────────────────
  function toggleGroup(groupId, ...otherIds) {
    const grp     = document.getElementById(groupId);
    const opening = !grp.classList.contains('open');
    otherIds.forEach(id => document.getElementById(id)?.classList.remove('open'));
    grp.classList.toggle('open', opening);
  }

  document.getElementById('btn-group-draw')?.addEventListener('click', () =>
    toggleGroup('group-draw', 'group-select', 'group-measure'));
  document.getElementById('btn-group-select')?.addEventListener('click', () =>
    toggleGroup('group-select', 'group-draw', 'group-measure'));
  document.getElementById('btn-group-measure')?.addEventListener('click', () =>
    toggleGroup('group-measure', 'group-draw', 'group-select'));

  document.querySelectorAll('.tool-btn[data-mode]').forEach(btn =>
    btn.addEventListener('click', () => setMode(btn.dataset.mode))
  );

  // ── Tool action buttons ───────────────────────────────────────────────────
  document.getElementById('tool-clear-sel')?.addEventListener('click', () => actions.clearSelection());
  document.getElementById('tool-clear-measure')?.addEventListener('click', clearMeasurements);
  document.getElementById('tool-invert-sel')?.addEventListener('click', invertSelection);
  document.getElementById('btn-crossfilter')?.addEventListener('click', () =>
    actions.setCombine(store.getState().combine === 'and' ? 'or' : 'and'));

  document.getElementById('btn-screenshot')?.addEventListener('click', () => {
    if (!state.deckgl) return;
    state.deckgl.redraw('screenshot');
    const a = document.createElement('a');
    a.href = canvas.toDataURL('image/png');
    a.download = `giottolens-${new Date().toISOString().slice(0, 19).replace(/[T:]/g, '-')}.png`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
  });

  // ── Meta-select panel ─────────────────────────────────────────────────────
  const $metaSelPanel = document.getElementById('meta-sel-panel');
  document.getElementById('tool-meta-sel')?.addEventListener('click', () => {
    if (!$metaSelPanel) return;
    const open = $metaSelPanel.classList.toggle('visible');
    if (open) {
      const colSel = document.getElementById('meta-sel-col');
      const names  = state.meta ? [...state.meta.keys()] : [];
      if (colSel) colSel.innerHTML = names.length
        ? names.map(c => `<option value="${escapeHtml(c)}">${escapeHtml(c)}</option>`).join('')
        : '<option value="">no metadata loaded</option>';
    }
  });

  document.getElementById('meta-sel-apply')?.addEventListener('click', () => {
    const col = document.getElementById('meta-sel-col')?.value;
    const op  = document.getElementById('meta-sel-op')?.value ?? '=';
    const val = document.getElementById('meta-sel-val')?.value ?? '';
    if (!col || !state.meta?.has(col)) return;
    filterMeta(col, op === 'LIKE' ? 'contains' : op, val);
  });

  document.getElementById('tx-lasso-close')?.addEventListener('click', () => {
    state.txLassoRing = null;
    document.getElementById('tx-lasso-panel')?.classList.remove('visible');
    updateTxConnector();
    requestRender();
  });

  // ── Canvas events ─────────────────────────────────────────────────────────
  canvas.addEventListener('click', e => {
    const mode = store.getState().mode;
    if (mode === 'ruler') {
      const pt = world(e);
      if (!state.rulerStart || state.rulerLocked) {
        state.rulerStart  = pt;
        state.rulerEnd    = pt;
        state.rulerLocked = false;
        document.getElementById('ruler-label')?.classList.remove('visible');
      } else {
        state.rulerEnd    = pt;
        state.rulerLocked = true;
        updateRulerLabel();
      }
      requestRender();
      return;
    }
    if (mode !== 'poly') return;
    // The second click of a double-click finishes the ring; it adds no vertex
    if (e.detail > 1) return;
    _lastClickAddedVertex = false;
    const r      = canvas.getBoundingClientRect();
    const picked = state.deckgl.pickObject({ x: e.clientX - r.left, y: e.clientY - r.top, radius: 4 });
    if (picked?.layer?.id === 'annotations') return;
    state.drawRing.push(world(e));
    _lastClickAddedVertex = true;
    requestRender();
  });

  canvas.addEventListener('dblclick', () => {
    if (store.getState().mode !== 'poly') return;
    if (_lastClickAddedVertex) state.drawRing.pop();
    _lastClickAddedVertex = false;
    if (state.drawRing.length >= 3) addAnnotation('polygon', [...state.drawRing, state.drawRing[0]]);
    state.drawRing = [];
    requestRender();
  });

  canvas.addEventListener('mousedown', e => {
    hideCellTooltip();
    const mode = store.getState().mode;
    if (mode === 'brush') {
      state.brushDown = true;
      state.brushPos  = world(e);
      brushStart(state.brushPos, store.getState().brushRadius / Math.pow(2, state.currentViewState.zoom));
    } else if (mode === 'lasso' || mode === 'freehand' || mode === 'txlasso') {
      if (mode === 'txlasso') {
        state.txLassoRing = null;
        document.getElementById('tx-lasso-panel')?.classList.remove('visible');
        updateTxConnector();
      }
      lassoDragged = false;
      lassoLastPx  = [e.clientX, e.clientY];
      state.lassoActive = true;
      state.lassoRing   = [world(e)];
    } else if (mode === 'rect') {
      state.rectStart   = world(e);
      state.rectPreview = state.rectStart;
    }
  });

  canvas.addEventListener('mousemove', e => {
    const coords  = world(e);
    const coordEl = document.getElementById('cursor-coords');
    if (coordEl) coordEl.textContent = `${coords[0].toFixed(1)}, ${coords[1].toFixed(1)}`;
    const mode = store.getState().mode;

    if (mode === 'brush') {
      state.brushPos = coords;
      if (state.brushDown) brushMove(coords);
      requestRender();
    }

    if (mode === 'ruler' && state.rulerStart && !state.rulerLocked) {
      state.rulerEnd = coords;
      updateRulerLabel();
      requestRender();
    }

    if ((mode === 'lasso' || mode === 'freehand' || mode === 'txlasso') && state.lassoActive) {
      const dx = e.clientX - lassoLastPx[0], dy = e.clientY - lassoLastPx[1];
      if (Math.hypot(dx, dy) < (mode === 'freehand' ? 20 : 5)) return;
      lassoLastPx = [e.clientX, e.clientY];
      lassoDragged = true;
      state.lassoRing.push(coords);
      requestRender();
    } else if (mode === 'rect' && state.rectStart) {
      state.rectPreview = coords;
      requestRender();
    }
  });

  window.addEventListener('mouseup', () => {
    const mode = store.getState().mode;
    if (mode === 'brush' && state.brushDown) {
      state.brushDown = false;
      brushEnd();
      requestRender();
    }
    if ((mode === 'lasso' || mode === 'freehand' || mode === 'txlasso') && state.lassoActive) {
      state.lassoActive = false;
      const ring = state.lassoRing;
      state.lassoRing = [];
      if (lassoDragged && ring.length >= 3) {
        if (mode === 'txlasso') _runTxLasso(ring);
        else if (mode === 'lasso') lassoSpatial(ring);
        else addAnnotation('freehand', [...ring, ring[0]]);
      }
      requestRender();
    } else if (mode === 'rect' && state.rectStart) {
      const [x0, y0] = state.rectStart;
      const [x1, y1] = state.rectPreview ?? state.rectStart;
      if (Math.abs(x1 - x0) > 0 && Math.abs(y1 - y0) > 0)
        addAnnotation('rectangle', [[x0,y0],[x1,y0],[x1,y1],[x0,y1],[x0,y0]]);
      state.rectStart   = null;
      state.rectPreview = null;
      requestRender();
    }
  });

  canvas.addEventListener('mouseleave', () => {
    hideCellTooltip();
    const coordEl = document.getElementById('cursor-coords');
    if (coordEl) coordEl.textContent = '';
  });

  // Space and Escape also return the stats panels to pan
  const panelsToPan = () => document.dispatchEvent(new CustomEvent('lens:pan'));

  document.addEventListener('keydown', e => {
    const inInput = ['INPUT', 'TEXTAREA', 'SELECT'].includes(document.activeElement?.tagName);
    const mode = store.getState().mode;

    if (e.code === 'Space' && !e.repeat && !inInput) {
      e.preventDefault();
      if (mode !== 'pan') setMode('pan');
      panelsToPan();
      return;
    }

    if (e.key === 'Escape') {
      resetDrawing();
      actions.selectAnnotation(null);
      panelsToPan();
      if (mode !== 'pan') setMode('pan'); else requestRender();
    }
    if (inInput) return;
    if (e.key === 'c') actions.clearSelection();
    if (e.key === 'x') clearMeasurements();
    if (mode === 'brush') {
      if (e.key === '[') actions.setBrushRadius(store.getState().brushRadius - 5);
      if (e.key === ']') actions.setBrushRadius(store.getState().brushRadius + 5);
    }
    const annot = store.getState().selectedAnnotId;
    if ((e.key === 'Delete' || e.key === 'Backspace') && annot) {
      actions.removeAnnotation(annot);
      e.preventDefault();
    }
  });
}
