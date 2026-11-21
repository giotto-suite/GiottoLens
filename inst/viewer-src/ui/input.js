// Spatial-view tools: modes, drawing, measuring, selecting, keyboard. Bound
// to one view (attachInput) and removed with it; the page-wide selection
// actions are the selection bar's (ui/selbar.js).
import { state } from '../core/state.js';
import { spatialView } from '../spatial/current.ts';
import { store, actions } from '../core/store.ts';
import { requestRender } from '../render/schedule.js';
import { fetchTranscriptTile, GENE_UNKNOWN } from '../data/tiles.js';
import { lassoSpatial, brushStart, brushMove, brushEnd, strokeOp } from '../selection/selection.ts';
import { generateAnnotId, nextAnnotName } from './annotations.js';
import { annotDragStart, annotDragMove, annotDragEnd, cancelAnnotDrag, annotVertexRemove } from './annot-edit.ts';
import { applyController, overHandle, releaseHandle } from './controller.ts';
import { clientToWorld, worldToClient, pointInPolygon, escapeHtml, spaceHeld, setSpaceHeld } from './dom.js';
import { hideCellTooltip } from './tooltip.js';
import { landmarkClick, landmarkDragStart, landmarkDragMove, landmarkDragEnd, consumeDrop,
  removeLastLandmark, cancelPendingLandmark, refreshPaneCursor } from './registration.ts';

let _lastClickAddedVertex = false; // so a double-click only removes its own vertex
let _downPx = null;                // where the button went down: a click after a pan is no click
// Space held: a drag pans whatever the tool (dragPan in ui/dom.js), and the
// tool is back on release. The store's mode is left alone, so it is not saved
// as 'pan' and a polygon being clicked out keeps its vertices.
const toolMode = () => spaceHeld() ? 'pan' : store.getState().mode;


function rulerDist(a, b) {
  const d = Math.hypot(b[0] - a[0], b[1] - a[1]);
  return d >= 1000 ? `${(d / 1000).toFixed(3)} mm` : `${d.toFixed(1)} μm`;
}

export function updateRulerLabel() {
  const view = spatialView();
  const label = view?.el.ruler;
  if (!label || !view.viewState || !state.rulerStart || !state.rulerEnd) return;
  const mid = [(state.rulerStart[0] + state.rulerEnd[0]) / 2,
               (state.rulerStart[1] + state.rulerEnd[1]) / 2];
  const [sx, sy] = worldToClient(mid[0], mid[1], view.canvas, view.viewState);
  const pane = view.root.getBoundingClientRect();
  label.style.left = `${sx - pane.left + 8}px`;
  label.style.top  = `${sy - pane.top - 10}px`;
  label.textContent = rulerDist(state.rulerStart, state.rulerEnd);
  label.classList.add('visible');
}

export function updateTxConnector() {
  const view  = spatialView();
  const line  = view?.el.txLine;
  const panel = view?.el.txPanel;
  if (!line || !panel || !view.viewState || !state.txLassoRing?.length || !panel.classList.contains('visible')) {
    line?.setAttribute('display', 'none');
    return;
  }
  const ring = state.txLassoRing;
  const cx = ring.reduce((s, p) => s + p[0], 0) / ring.length;
  const cy = ring.reduce((s, p) => s + p[1], 0) / ring.length;
  const [sx, sy] = worldToClient(cx, cy, view.canvas, view.viewState);
  const rect     = panel.getBoundingClientRect();
  const paneRect = view.root.getBoundingClientRect();
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
  setSpaceHeld(false);
  resetDrawing();
  actions.setMode(m);
}

const GROUP_MODES = { draw: ['poly', 'rect', 'freehand'], select: ['lasso', 'brush'], measure: ['ruler', 'txlasso'] };

function applyMode(mode) {
  const view = spatialView();
  if (!view) return;
  const m = spaceHeld() ? 'pan' : mode;   // what the toolbar shows
  releaseHandle();
  applyController();
  view.deck.setProps({
    // A handle of the annotation being edited moves; otherwise the hand is
    // for panning and every other tool points with a crosshair
    getCursor: ({ isDragging }) => mode === 'pan' && !spaceHeld() && overHandle() ? 'move'
      : isDragging ? 'grabbing' : m === 'pan' ? 'grab' : 'crosshair',
  });
  refreshPaneCursor();
  view.root.querySelectorAll('.tool-btn[data-mode]').forEach(b =>
    b.classList.toggle('active', b.dataset.mode === m)
  );
  view.root.querySelectorAll('.tool-group').forEach(g =>
    g.querySelector('.tool-group-btn')?.classList.toggle('active', GROUP_MODES[g.dataset.group]?.includes(m)));
}

function clearMeasurements() {
  const el = spatialView()?.el;
  state.rulerStart = null; state.rulerEnd = null; state.rulerLocked = false;
  el?.ruler.classList.remove('visible');
  state.txLassoRing = null;
  el?.txPanel.classList.remove('visible');
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
  const el = spatialView()?.el;
  if (!el) return;
  const { txPanel: panel, txTitle: title, txResults: list } = el;
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

function addAnnotation(coords) {
  const name = nextAnnotName(store.getState().annotations.map(a => a.name));
  actions.addAnnotation({ id: generateAnnotId(), name, coords });
}

// ── Input ─────────────────────────────────────────────────────────────────────
// The view's toolbar, canvas and keyboard; every listener goes with the view
export function attachInput(view) {
  const { canvas, el, signal } = view;
  const on = { signal };
  const world  = e => clientToWorld(e.clientX, e.clientY, canvas, view.viewState);
  let lassoDragged = false;
  let lassoLastPx  = null;
  let lassoOp      = 'replace';

  const unsub = store.subscribe(s => s.mode, applyMode, { fireImmediately: true });
  signal.addEventListener('abort', unsub);
  const unsubAnnot = store.subscribe(s => s.selectedAnnotId, releaseHandle);
  signal.addEventListener('abort', unsubAnnot);

  // ── Toolbar groups: one open at a time ────────────────────────────────────
  const groups = [...view.root.querySelectorAll('.tool-group')];
  for (const g of groups)
    g.querySelector('.tool-group-btn').addEventListener('click', () => {
      const opening = !g.classList.contains('open');
      groups.forEach(x => x.classList.remove('open'));
      g.classList.toggle('open', opening);
    });

  view.root.querySelectorAll('.tool-btn[data-mode]').forEach(btn =>
    btn.addEventListener('click', () => setMode(btn.dataset.mode))
  );

  el.clearMeasure.addEventListener('click', clearMeasurements);
  el.txClose.addEventListener('click', () => {
    state.txLassoRing = null;
    el.txPanel.classList.remove('visible');
    updateTxConnector();
    requestRender();
  });

  // ── Canvas events ─────────────────────────────────────────────────────────
  canvas.addEventListener('click', e => {
    if (!view.viewState) return;
    const mode = toolMode();
    if (mode === 'landmark') {
      const moved = _downPx && Math.hypot(e.clientX - _downPx[0], e.clientY - _downPx[1]) > 4;
      if (!consumeDrop() && !moved) landmarkClick('fixed', world(e));
      requestRender();
      return;
    }
    if (mode === 'ruler') {
      const pt = world(e);
      if (!state.rulerStart || state.rulerLocked) {
        state.rulerStart  = pt;
        state.rulerEnd    = pt;
        state.rulerLocked = false;
        el.ruler.classList.remove('visible');
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
    const picked = view.deck.pickObject({ x: e.clientX - r.left, y: e.clientY - r.top, radius: 4 });
    if (picked?.layer?.id === 'annotations') return;
    state.drawRing.push(world(e));
    _lastClickAddedVertex = true;
    requestRender();
  });

  canvas.addEventListener('dblclick', e => {
    if (toolMode() === 'pan' && annotVertexRemove(e, canvas)) { requestRender(); return; }
    if (toolMode() !== 'poly') return;
    if (_lastClickAddedVertex) state.drawRing.pop();
    _lastClickAddedVertex = false;
    if (state.drawRing.length >= 3) addAnnotation([...state.drawRing, state.drawRing[0]]);
    state.drawRing = [];
    requestRender();
  });

  // Ctrl-click opens the context menu on macOS; Ctrl subtracts while drawing
  canvas.addEventListener('contextmenu', e => {
    if (e.ctrlKey && ['lasso', 'brush'].includes(toolMode())) e.preventDefault();
  });

  // Tools act on the left button; the middle one pans (dragPan in ui/dom.js)
  canvas.addEventListener('mousedown', e => {
    hideCellTooltip();
    if (e.button !== 0 || !view.viewState) return;
    _downPx = [e.clientX, e.clientY];
    const mode = toolMode();
    if (mode === 'pan') {
      if (annotDragStart(e, canvas)) requestRender();
    } else if (mode === 'landmark') {
      if (landmarkDragStart('fixed', e, canvas)) requestRender();
    } else if (mode === 'brush') {
      state.brushDown = true;
      state.brushPos  = world(e);
      brushStart(state.brushPos, store.getState().brushRadius / Math.pow(2, view.viewState.zoom), strokeOp(e));
    } else if (mode === 'lasso' || mode === 'freehand' || mode === 'txlasso') {
      if (mode === 'txlasso') {
        state.txLassoRing = null;
        el.txPanel.classList.remove('visible');
        updateTxConnector();
      }
      lassoDragged = false;
      lassoLastPx  = [e.clientX, e.clientY];
      lassoOp      = strokeOp(e);   // the modifier held when the stroke starts
      state.lassoActive = true;
      state.lassoRing   = [world(e)];
    } else if (mode === 'rect') {
      state.rectStart   = world(e);
      state.rectPreview = state.rectStart;
    }
  });

  canvas.addEventListener('mousemove', e => {
    if (!view.viewState) return;
    const coords  = world(e);
    el.coords.textContent = `${coords[0].toFixed(1)}, ${coords[1].toFixed(1)}`;
    const mode = toolMode();

    if (mode === 'pan' && annotDragMove(coords, e)) requestRender();
    if (mode === 'landmark' && landmarkDragMove('fixed', coords, e)) requestRender();

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

  window.addEventListener('mouseup', e => {
    if (e.button !== 0) return;
    const mode = store.getState().mode;
    if (landmarkDragEnd()) requestRender();
    if (annotDragEnd()) requestRender();
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
        else if (mode === 'lasso') lassoSpatial(ring, lassoOp);
        else addAnnotation([...ring, ring[0]]);
      }
      requestRender();
    } else if (mode === 'rect' && state.rectStart) {
      const [x0, y0] = state.rectStart;
      const [x1, y1] = state.rectPreview ?? state.rectStart;
      if (Math.abs(x1 - x0) > 0 && Math.abs(y1 - y0) > 0)
        addAnnotation([[x0,y0],[x1,y0],[x1,y1],[x0,y1],[x0,y0]]);
      state.rectStart   = null;
      state.rectPreview = null;
      requestRender();
    }
  }, on);

  canvas.addEventListener('mouseleave', () => {
    hideCellTooltip();
    el.coords.textContent = '';
  });

  const holdPan = down => {
    if (down === spaceHeld()) return;
    setSpaceHeld(down);
    if (down) state.brushPos = null;   // no brush outline while panning
    applyMode(store.getState().mode);
    requestRender();
  };

  document.addEventListener('keydown', e => {
    const inInput = ['INPUT', 'TEXTAREA', 'SELECT'].includes(document.activeElement?.tagName);
    const mode = store.getState().mode;

    if (e.code === 'Space' && !inInput) {
      e.preventDefault();
      // Not in the middle of a drag: the stroke finishes with its own tool
      const stroking = state.lassoActive || state.brushDown || state.rectStart || state.landmarkDrag || state.annotDrag;
      if (!e.repeat && !stroking) holdPan(true);
      return;
    }

    if (e.key === 'Escape' && mode === 'landmark' && cancelPendingLandmark()) return;
    if (e.key === 'Escape' && cancelAnnotDrag()) { requestRender(); return; }
    if (e.key === 'Escape') {
      resetDrawing();
      actions.selectAnnotation(null);
      if (mode !== 'pan') setMode('pan'); else requestRender();
    }
    if (inInput) return;
    if (e.key === 'x') clearMeasurements();
    if (mode === 'brush') {
      if (e.key === '[') actions.setBrushRadius(store.getState().brushRadius - 5);
      if (e.key === ']') actions.setBrushRadius(store.getState().brushRadius + 5);
    }
    if (mode === 'landmark' && (e.key === 'Delete' || e.key === 'Backspace')) {
      removeLastLandmark();
      e.preventDefault();
      return;
    }
    const annot = store.getState().selectedAnnotId;
    if ((e.key === 'Delete' || e.key === 'Backspace') && annot) {
      actions.removeAnnotation(annot);
      e.preventDefault();
    }
  }, on);
  document.addEventListener('keyup', e => { if (e.code === 'Space') holdPan(false); }, on);
  // A release while the page is not focused never arrives
  window.addEventListener('blur', () => holdPan(false), on);
  signal.addEventListener('abort', () => { setSpaceHeld(false); resetDrawing(); cancelAnnotDrag(); });
}
