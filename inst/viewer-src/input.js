import { state }              from './state.js';
import { renderLayers }       from './render.js';
import { getCachedPolyData }  from './data.js';
import { notify, recomputeCrossFilter, sqlIds, clearFilters } from './coordination.js';
import { sel }                from './mosaic.js';
import { generateAnnotId, syncAnnotationsToR } from './annotations.js';
import { clientToWorld, worldToClient, pointInPolygon } from './ui.js';

let _canvas = null; // set in initInput, used by exported functions above initInput scope

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

export function setMode(m) {
  state.mode = m;
  state.drawRing    = [];
  state.lassoRing   = [];
  state.lassoActive = false;
  state.rectStart   = null;
  state.rectPreview = null;
  state.brushDown   = false;
  state.brushPos    = null;
  state.deckgl.setProps({ controller: (m === 'lasso' || m === 'txlasso' || m === 'rect' || m === 'freehand' || m === 'brush')
    ? { dragPan: false, doubleClickZoom: false }
    : { doubleClickZoom: false } });
  document.querySelectorAll('.tool-btn[data-mode]').forEach(b =>
    b.classList.toggle('active', b.dataset.mode === m)
  );
  document.getElementById('btn-group-draw')?.classList.toggle('active',    ['poly','rect','freehand'].includes(m));
  document.getElementById('btn-group-select')?.classList.toggle('active',  ['lasso','brush'].includes(m));
  document.getElementById('btn-group-measure')?.classList.toggle('active', ['ruler','txlasso'].includes(m));
  renderLayers(state.currentViewState);
}

// ── Transcript lasso ──────────────────────────────────────────────────────────
async function _runTxLasso(ring) {
  const panel = document.getElementById('tx-lasso-panel');
  const title = document.getElementById('tx-lasso-title');
  const list  = document.getElementById('tx-lasso-results');
  if (!panel) return;

  state.txLassoRing = ring;
  renderLayers(state.currentViewState);
  title.textContent = 'querying…';
  list.innerHTML = '';
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

    const urls   = overlapping.map(t => `'${t.url}'`).join(', ');
    const result = await state.conn.query(
      `SELECT feat_ID, x_index, y_index FROM read_parquet([${urls}])
       WHERE x_index BETWEEN ${xmin} AND ${xmax}
         AND y_index BETWEEN ${ymin} AND ${ymax}`
    );

    const counts = new Map();
    const closed = [...ring, ring[0]];
    for (const batch of result.batches) {
      const fs = batch.getChildAt(0), xs = batch.getChildAt(1), ys = batch.getChildAt(2);
      for (let i = 0; i < batch.numRows; i++) {
        if (pointInPolygon(closed, xs.get(i), ys.get(i))) {
          const g = fs.get(i);
          counts.set(g, (counts.get(g) ?? 0) + 1);
        }
      }
    }

    const sorted = [...counts.entries()].sort((a, b) => b[1] - a[1]);
    const total  = sorted.reduce((s, [, n]) => s + n, 0);
    const top    = sorted.slice(0, 50);
    const maxN   = top[0]?.[1] ?? 1;

    title.textContent = `${total.toLocaleString()} transcripts · ${sorted.length} genes`;
    list.innerHTML = top.map(([gene, n]) =>
      `<div class="tx-gene-row">
        <span class="tx-gene-name" title="${gene}">${gene}</span>
        <div class="tx-gene-bar-wrap"><div class="tx-gene-bar" style="width:${(n/maxN*100).toFixed(1)}%"></div></div>
        <span class="tx-gene-count">${n.toLocaleString()}</span>
      </div>`
    ).join('');
    requestAnimationFrame(updateTxConnector);
  } catch(e) {
    title.textContent = 'query failed';
    requestAnimationFrame(updateTxConnector);
    console.warn('[txlasso]', e);
  }
}

// ── Input initialization ──────────────────────────────────────────────────────
export function initInput() {
  _canvas = document.getElementById('deck-canvas');
  const canvas = _canvas;
  let lassoDragged = false;
  let lassoLastPx  = null;

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
  document.getElementById('tool-clear-sel')?.addEventListener('click', () => clearFilters());

  document.getElementById('tool-clear-measure')?.addEventListener('click', () => {
    state.rulerStart = null; state.rulerEnd = null; state.rulerLocked = false;
    document.getElementById('ruler-label')?.classList.remove('visible');
    state.txLassoRing = null;
    document.getElementById('tx-lasso-panel')?.classList.remove('visible');
    updateTxConnector();
    renderLayers(state.currentViewState);
  });

  document.getElementById('tool-invert-sel')?.addEventListener('click', () => {
    if (!state.allPolyIds.size) return;
    state.selectedCells = new Set([...state.allPolyIds].filter(id => !state.selectedCells.has(id)));
    state.selVersion++;
    notify('cellSelection');
  });

  document.getElementById('btn-crossfilter')?.addEventListener('click', () => {
    state.crossFilter = !state.crossFilter;
    document.getElementById('btn-crossfilter')?.classList.toggle('active', state.crossFilter);
    if (!state.crossFilter) {
      state.spatialFilter = null;
      state.scatterFilter = null;
      try { sel.update({ source: 'spatial', predicate: null }); } catch(_) {}
    }
  });

  // ── Meta-select panel ─────────────────────────────────────────────────────
  const $metaSelPanel = document.getElementById('meta-sel-panel');
  document.getElementById('tool-meta-sel')?.addEventListener('click', () => {
    if (!$metaSelPanel) return;
    const open = $metaSelPanel.classList.toggle('visible');
    if (open) {
      const colSel = document.getElementById('meta-sel-col');
      if (colSel) {
        colSel.innerHTML = state.metaCols.length
          ? state.metaCols.map(c => `<option value="${c.name}">${c.name}</option>`).join('')
          : '<option value="">no metadata loaded</option>';
      }
    }
  });

  document.getElementById('meta-sel-apply')?.addEventListener('click', async () => {
    const col = document.getElementById('meta-sel-col')?.value;
    const op  = document.getElementById('meta-sel-op')?.value ?? '=';
    const val = document.getElementById('meta-sel-val')?.value ?? '';
    if (!col || !state.metaCols.length) return;
    const colInfo = state.metaCols.find(c => c.name === col);
    const valExpr = (colInfo?.numeric && op !== 'LIKE')
      ? val
      : `'${val.replace(/'/g, "''")}'`;
    const opExpr  = op === 'LIKE' ? `LIKE '%${val.replace(/'/g, "''")}%'` : `${op} ${valExpr}`;
    const result  = await state.polyConn.query(
      `SELECT cell_ID FROM cell_meta WHERE "${col}" ${opExpr}`
    );
    const ids = result.toArray().map(r => String(r.cell_ID));
    state.selectedCells = new Set(ids);
    state.selVersion++;
    notify('cellSelection');
  });

  document.getElementById('tx-lasso-close')?.addEventListener('click', () => {
    state.txLassoRing = null;
    document.getElementById('tx-lasso-panel')?.classList.remove('visible');
    updateTxConnector();
    renderLayers(state.currentViewState);
  });

  // ── Canvas events ─────────────────────────────────────────────────────────
  canvas.addEventListener('click', e => {
    if (state.mode === 'ruler') {
      const pt = clientToWorld(e.clientX, e.clientY, canvas, state.currentViewState);
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
      renderLayers(state.currentViewState);
      return;
    }
    if (state.mode !== 'poly') return;
    const r      = canvas.getBoundingClientRect();
    const picked = state.deckgl.pickObject({ x: e.clientX - r.left, y: e.clientY - r.top, radius: 4 });
    if (picked?.layer?.id === 'annotations') return;
    state.drawRing.push(clientToWorld(e.clientX, e.clientY, canvas, state.currentViewState));
    renderLayers(state.currentViewState);
  });

  canvas.addEventListener('dblclick', () => {
    if (state.mode !== 'poly') return;
    state.drawRing.pop();
    state.drawRing.pop();
    if (state.drawRing.length >= 3) {
      const coords = [...state.drawRing, state.drawRing[0]];
      state.annotations = [...state.annotations, { id: generateAnnotId(), type: 'polygon', name: '', coords }];
      syncAnnotationsToR();
    }
    state.drawRing = [];
    renderLayers(state.currentViewState);
  });

  canvas.addEventListener('mousedown', e => {
    if (state.mode === 'brush') {
      state.brushDown = true;
      state.brushPos  = clientToWorld(e.clientX, e.clientY, canvas, state.currentViewState);
    } else if (state.mode === 'lasso' || state.mode === 'freehand' || state.mode === 'txlasso') {
      if (state.mode === 'txlasso') {
        state.txLassoRing = null;
        document.getElementById('tx-lasso-panel')?.classList.remove('visible');
        updateTxConnector();
      }
      lassoDragged = false;
      lassoLastPx  = [e.clientX, e.clientY];
      state.lassoActive = true;
      state.lassoRing   = [clientToWorld(e.clientX, e.clientY, canvas, state.currentViewState)];
    } else if (state.mode === 'rect') {
      state.rectStart   = clientToWorld(e.clientX, e.clientY, canvas, state.currentViewState);
      state.rectPreview = state.rectStart;
    }
  });

  canvas.addEventListener('mousemove', e => {
    const coords  = clientToWorld(e.clientX, e.clientY, canvas, state.currentViewState);
    const coordEl = document.getElementById('cursor-coords');
    if (coordEl) coordEl.textContent = `${coords[0].toFixed(1)}, ${coords[1].toFixed(1)}`;

    if (state.mode === 'brush') {
      state.brushPos = coords;
      if (state.brushDown) {
        const r        = state.brushRadius / Math.pow(2, state.currentViewState.zoom);
        const polyData = getCachedPolyData();
        if (polyData?.ids) {
          const cents    = polyData.centroids;
          const brushSet = new Set(state.crossFilter ? (state.spatialFilter ?? []) : state.selectedCells);
          for (let i = 0; i < polyData.ids.length; i++)
            if (polyData.ids[i] != null && Math.hypot(cents[i*2] - coords[0], cents[i*2+1] - coords[1]) <= r)
              brushSet.add(polyData.ids[i]);
          if (state.crossFilter) { state.spatialFilter = brushSet; recomputeCrossFilter(); }
          else { state.selectedCells = brushSet; state.selVersion++; notify('cellSelection'); }
        }
      }
      renderLayers(state.currentViewState);
    }

    if (state.mode === 'ruler' && state.rulerStart && !state.rulerLocked) {
      state.rulerEnd = coords;
      updateRulerLabel();
      renderLayers(state.currentViewState);
    }

    if ((state.mode === 'lasso' || state.mode === 'freehand' || state.mode === 'txlasso') && state.lassoActive) {
      const dx = e.clientX - lassoLastPx[0], dy = e.clientY - lassoLastPx[1];
      if (Math.hypot(dx, dy) < (state.mode === 'freehand' ? 20 : 5)) return;
      lassoLastPx = [e.clientX, e.clientY];
      lassoDragged = true;
      state.lassoRing.push(clientToWorld(e.clientX, e.clientY, canvas, state.currentViewState));
      renderLayers(state.currentViewState);
    } else if (state.mode === 'rect' && state.rectStart) {
      state.rectPreview = clientToWorld(e.clientX, e.clientY, canvas, state.currentViewState);
      renderLayers(state.currentViewState);
    }
  });

  window.addEventListener('mouseup', () => {
    if (state.mode === 'brush' && state.brushDown) {
      state.brushDown = false;
      if (state.crossFilter) {
        recomputeCrossFilter();
        try {
          const active = state.spatialFilter ? sqlIds(state.spatialFilter) : '';
          sel.update({ source: 'spatial', predicate: active ? `cell_ID IN (${active})` : null });
        } catch(_) {}
      } else notify('cellSelection');
    }
    if ((state.mode === 'lasso' || state.mode === 'freehand' || state.mode === 'txlasso') && state.lassoActive) {
      state.lassoActive = false;
      if (lassoDragged && state.lassoRing.length >= 3) {
        if (state.mode === 'txlasso') {
          const ring = state.lassoRing;
          state.lassoRing = [];
          renderLayers(state.currentViewState);
          _runTxLasso(ring);
        } else if (state.mode === 'lasso') {
          const polyData = getCachedPolyData();
          if (polyData?.ids) {
            const ring     = state.lassoRing;
            const cents    = polyData.centroids;
            const lassoSet = new Set();
            for (let i = 0; i < polyData.ids.length; i++)
              if (polyData.ids[i] != null && pointInPolygon(ring, cents[i * 2], cents[i * 2 + 1]))
                lassoSet.add(polyData.ids[i]);
            if (state.crossFilter) {
              state.spatialFilter = lassoSet;
              recomputeCrossFilter();
              try {
                const active = sqlIds(lassoSet);
                sel.update({ source: 'spatial', predicate: active ? `cell_ID IN (${active})` : null });
              } catch(_) {}
            } else {
              state.selectedCells = new Set([...state.selectedCells, ...lassoSet]);
              state.selVersion++;
              notify('cellSelection');
            }
          }
        } else {
          const coords = [...state.lassoRing, state.lassoRing[0]];
          state.annotations = [...state.annotations, { id: generateAnnotId(), type: 'freehand', name: '', coords }];
          syncAnnotationsToR();
        }
      }
      state.lassoRing = [];
      renderLayers(state.currentViewState);
    } else if (state.mode === 'rect' && state.rectStart) {
      const [x0, y0] = state.rectStart;
      const [x1, y1] = state.rectPreview ?? state.rectStart;
      if (Math.abs(x1 - x0) > 0 && Math.abs(y1 - y0) > 0) {
        const coords = [[x0,y0],[x1,y0],[x1,y1],[x0,y1],[x0,y0]];
        state.annotations = [...state.annotations, { id: generateAnnotId(), type: 'rectangle', name: '', coords }];
        syncAnnotationsToR();
      }
      state.rectStart   = null;
      state.rectPreview = null;
      renderLayers(state.currentViewState);
    }
  });

  canvas.addEventListener('mouseleave', () => {
    const coordEl = document.getElementById('cursor-coords');
    if (coordEl) coordEl.textContent = '';
  });

  document.addEventListener('keydown', e => {
    if (e.key === 'Escape') {
      state.drawRing    = [];
      state.lassoRing   = [];
      state.lassoActive = false;
      state.rectStart   = null;
      state.rectPreview = null;
      state.selectedAnnotId = null;
      notify('annotSelect');
      if (state.mode !== 'pan') setMode('pan');
      else renderLayers(state.currentViewState);
    }
    if (state.mode === 'brush' && document.activeElement?.id !== 'annot-name') {
      if (e.key === '[') { state.brushRadius = Math.max(8,   state.brushRadius - 5); renderLayers(state.currentViewState); }
      if (e.key === ']') { state.brushRadius = Math.min(300, state.brushRadius + 5); renderLayers(state.currentViewState); }
    }
    if ((e.key === 'Delete' || e.key === 'Backspace') && state.selectedAnnotId
        && document.activeElement?.id !== 'annot-name') {
      state.annotations = state.annotations.filter(a => a.id !== state.selectedAnnotId);
      state.selectedAnnotId = null;
      notify('annotSelect');
      syncAnnotationsToR();
      renderLayers(state.currentViewState);
      e.preventDefault();
    }
  });
}
