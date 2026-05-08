import { state } from './state.js';
import { TRANSCRIPT_ZOOM_THRESHOLD, MAX_TRANSCRIPT_TILES } from './constants.js';
import { initDB, visibleTiles, loadTile, invalidateTx, invalidatePoly, getCachedPolyData, buildMetaColors } from './data.js';
import { geneSelectionKey, getManifestOverviewBins, updateGeneOverview } from './overview.js';
import { renderLayers } from './render.js';
import { renderGeneList, setToggleCallback } from './panel.js';
import { initComms, onMessage, sendToR } from './comms.js';

// ── Annotation helpers ────────────────────────────────────────────────────────
function dataToScreen(dx, dy) {
  const rect  = document.getElementById('deck-canvas').getBoundingClientRect();
  const vs    = state.currentViewState;
  const scale = Math.pow(2, vs.zoom);
  const [cx, cy] = vs.target;
  return [
    rect.left + rect.width  / 2 + (dx - cx) * scale,
    rect.top  + rect.height / 2 - (dy - cy) * scale,
  ];
}

function rulerDist(a, b) {
  const d = Math.hypot(b[0] - a[0], b[1] - a[1]);
  return d >= 1000 ? `${(d / 1000).toFixed(3)} mm` : `${d.toFixed(1)} μm`;
}

function updateRulerLabel() {
  const label = document.getElementById('ruler-label');
  if (!label || !state.rulerStart || !state.rulerEnd) return;
  const mid = [(state.rulerStart[0] + state.rulerEnd[0]) / 2,
               (state.rulerStart[1] + state.rulerEnd[1]) / 2];
  const [sx, sy] = dataToScreen(mid[0], mid[1]);
  label.style.left = `${sx + 8}px`;
  label.style.top  = `${sy - 10}px`;
  label.textContent = rulerDist(state.rulerStart, state.rulerEnd);
  label.classList.add('visible');
}

function canvasToData(clientX, clientY) {
  const rect  = document.getElementById('deck-canvas').getBoundingClientRect();
  const vs    = state.currentViewState;
  const scale = Math.pow(2, vs.zoom);
  const [cx, cy] = vs.target;
  const x = cx + (clientX - rect.left - rect.width  / 2) / scale;
  const y = cy - (clientY - rect.top  - rect.height / 2) / scale;
  return [x, y];
}

function pointInPolygon(ring, x, y) {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [xi, yi] = ring[i], [xj, yj] = ring[j];
    if ((yi > y) !== (yj > y) && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi)
      inside = !inside;
  }
  return inside;
}

function generateAnnotId() {
  return `ann_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`;
}

function syncAnnotationsToR() {
  sendToR('annotations_update', {
    annotations: state.annotations.map(a => ({
      id: a.id, type: a.type, name: a.name ?? '',
      geojson: JSON.stringify({
        type: 'Feature',
        geometry: { type: 'Polygon', coordinates: [a.coords] }
      })
    }))
  });
}

function setMode(m) {
  state.mode = m;
  state.drawRing   = [];
  state.lassoRing  = [];
  state.lassoActive = false;
  state.rectStart  = null;
  state.rectPreview = null;
  state.rulerStart  = null;
  state.rulerEnd    = null;
  state.rulerLocked = false;
  document.getElementById('ruler-label')?.classList.remove('visible');
  state.deckgl.setProps({ controller: (m === 'lasso' || m === 'rect' || m === 'freehand')
    ? { dragPan: false, doubleClickZoom: false }
    : { doubleClickZoom: false } });
  document.querySelectorAll('.tool-btn[data-mode]').forEach(b =>
    b.classList.toggle('active', b.dataset.mode === m)
  );
  document.getElementById('btn-group-draw')?.classList.toggle('active', ['poly','rect','freehand'].includes(m));
  document.getElementById('btn-group-select')?.classList.toggle('active', ['lasso'].includes(m));
  renderLayers(state.currentViewState);
}

// ── Tile eviction + load scheduling ──────────────────────────────────────────
function updateTiles(viewState) {
  state.currentViewState = viewState;
  const newTier = Math.min(3, Math.max(0, Math.floor(viewState.zoom - TRANSCRIPT_ZOOM_THRESHOLD)));
  if (newTier !== state.txZoomTier) { state.txZoomTier = newTier; invalidateTx(); }
  const txLayer        = state.manifest.layers.transcripts;
  const txAboveThresh  = state.showTx   && txLayer && viewState.zoom >= TRANSCRIPT_ZOOM_THRESHOLD;
  // Polygon tiles always stay in scope — only 12 tiles, centroids needed at all zooms
  const hasPoly        = state.showPoly && state.manifest.layers.polygons;
  const inScope        = new Set();

  if (hasPoly)
    for (const t of visibleTiles(viewState, state.manifest.layers.polygons.tiles))
      inScope.add(`polygons:${t.index}`);

  if (txAboveThresh)
    for (const t of visibleTiles(viewState, txLayer.tiles))
      inScope.add(`transcripts:${t.index}`);

  for (const key of state.cache.keys()) {
    if (!inScope.has(key)) {
      if      (key.startsWith('transcripts:')) { state.cache.delete(key); invalidateTx(); }
      else if (key.startsWith('polygons:'))    { state.cache.delete(key); invalidatePoly(); }
    }
  }

  for (const key of state.pending)
    if (!inScope.has(key)) state.cancelled.add(key);

  renderLayers(viewState);

  if (hasPoly)
    for (const t of visibleTiles(viewState, state.manifest.layers.polygons.tiles))
      loadTile('polygons', t, vs => renderLayers(vs));

  if (txAboveThresh) {
    const [cx, cy] = viewState.target;
    const txPending = [...state.pending].filter(k => k.startsWith('transcripts:')).length;
    visibleTiles(viewState, txLayer.tiles)
      .filter(t => !state.cache.has(`transcripts:${t.index}`) && !state.pending.has(`transcripts:${t.index}`))
      .sort((a, b) =>
        Math.hypot((a.xmin+a.xmax)/2 - cx, (a.ymin+a.ymax)/2 - cy) -
        Math.hypot((b.xmin+b.xmax)/2 - cx, (b.ymin+b.ymax)/2 - cy)
      )
      .slice(0, MAX_TRANSCRIPT_TILES - txPending)
      .forEach(t => loadTile('transcripts', t, vs => renderLayers(vs)));
  }

  if (!txAboveThresh && state.showOverview) {
    const geneKey = geneSelectionKey();
    if (state.overviewGeneKey !== geneKey) {
      state.overviewGeneKey = geneKey;
      if (state.selectedGenes.size === 0) {
        state.overviewBins = getManifestOverviewBins();
        renderLayers(viewState);
      } else {
        updateGeneOverview(() => renderLayers(state.currentViewState));
      }
    }
  }
}

function updateScalebar(viewState) {
  const pxPerMicron = Math.pow(2, viewState.zoom);
  const exp = Math.pow(10, Math.floor(Math.log10(100 / pxPerMicron)));
  const niceMicrons = [1, 2, 5, 10].map(x => x * exp).find(x => x * pxPerMicron >= 80) ?? exp * 10;
  const label = niceMicrons >= 1000 ? `${niceMicrons / 1000} mm` : `${niceMicrons} μm`;
  document.getElementById('scalebar-bar').style.width = (niceMicrons * pxPerMicron) + 'px';
  document.getElementById('scalebar-label').textContent = label;
}

function onViewStateChange({ viewState }) {
  state.deckgl.setProps({ viewState });
  updateScalebar(viewState);
  clearTimeout(state.tileTimer);
  state.tileTimer = setTimeout(() => updateTiles(viewState), 150);
}

// ── Layer control helpers ─────────────────────────────────────────────────────
function makeLayerControl(checkId, sliderId, valId, visSetter, alphaSetter) {
  const check  = document.getElementById(checkId);
  const slider = document.getElementById(sliderId);
  const label  = document.getElementById(valId);
  if (!check || !slider) return;
  slider.disabled = !check.checked;
  check.addEventListener('change', () => {
    visSetter(check.checked);
    slider.disabled = !check.checked;
    invalidateTx();
    updateTiles(state.currentViewState);
  });
  slider.addEventListener('input', () => {
    label.textContent = slider.value;
    alphaSetter(slider.value / 100);
    renderLayers(state.currentViewState);
  });
}

// ── Bootstrap ─────────────────────────────────────────────────────────────────
async function main() {
  document.getElementById('status').textContent = 'initializing duckdb…';
  await initDB();

  initComms();

  document.getElementById('status').textContent = 'loading manifest…';
  state.manifest = await fetch('./manifest.json').then(r => {
    if (!r.ok) throw new Error(`manifest.json not found (${r.status})`);
    return r.json();
  });

  state.geneIndex = new Map(state.manifest.layers.transcripts.genes.map((g, i) => [g, i]));

  const ext  = state.manifest.extent;
  const cx   = (ext.xmin + ext.xmax) / 2;
  const cy   = (ext.ymin + ext.ymax) / 2;
  const zoom = Math.log2(
    Math.min((window.innerWidth - 260) / (ext.xmax - ext.xmin),
              window.innerHeight       / (ext.ymax - ext.ymin))
  ) - 0.3;

  const initialViewState = { target: [cx, cy, 0], zoom, minZoom: zoom - 2, maxZoom: zoom + 12 };

  state.deckgl = new deck.Deck({
    canvas: 'deck-canvas', width: '100%', height: '100%',
    views: new deck.OrthographicView({ id: 'ortho', controller: true, flipY: false }),
    initialViewState, controller: { doubleClickZoom: false }, onViewStateChange, layers: [],
  });
  updateScalebar(initialViewState);

  // ── Annotation popup ─────────────────────────────────────────────────────
  const $annotPopup = document.getElementById('annot-popup');
  const $annotName  = document.getElementById('annot-name');
  const $annotType  = document.getElementById('annot-type');

  state.onAnnotSelect = (id) => {
    if (id) {
      const annot = state.annotations.find(a => a.id === id);
      if ($annotName)  $annotName.value       = annot?.name ?? '';
      if ($annotType)  $annotType.textContent  = annot?.type ?? '';
      $annotPopup?.classList.add('visible');
    } else {
      $annotPopup?.classList.remove('visible');
    }
  };

  $annotName?.addEventListener('input', () => {
    if (!state.selectedAnnotId) return;
    state.annotations = state.annotations.map(a =>
      a.id === state.selectedAnnotId ? { ...a, name: $annotName.value } : a
    );
    syncAnnotationsToR();
  });

  // ── Toolbar mode buttons ──────────────────────────────────────────────────
  function toggleGroup(groupId, otherGroupId) {
    const grp   = document.getElementById(groupId);
    const other = document.getElementById(otherGroupId);
    const opening = !grp.classList.contains('open');
    other?.classList.remove('open');
    grp.classList.toggle('open', opening);
  }

  document.getElementById('btn-group-draw')?.addEventListener('click', () =>
    toggleGroup('group-draw', 'group-select'));
  document.getElementById('btn-group-select')?.addEventListener('click', () =>
    toggleGroup('group-select', 'group-draw'));

  document.querySelectorAll('.tool-btn[data-mode]').forEach(btn =>
    btn.addEventListener('click', () => setMode(btn.dataset.mode))
  );
  document.getElementById('tool-clear-sel')?.addEventListener('click', () => {
    state.selectedCells.clear();
    state.selVersion++;
    sendToR('cell_selection', { ids: [] });
    renderLayers(state.currentViewState);
  });

  // ── Canvas annotation / lasso events ─────────────────────────────────────
  const canvas = document.getElementById('deck-canvas');
  let lassoDragged  = false;
  let lassoLastPx   = null;

  canvas.addEventListener('click', e => {
    if (state.mode === 'ruler') {
      const pt = canvasToData(e.clientX, e.clientY);
      if (!state.rulerStart || state.rulerLocked) {
        // start fresh measurement
        state.rulerStart  = pt;
        state.rulerEnd    = pt;
        state.rulerLocked = false;
        document.getElementById('ruler-label')?.classList.remove('visible');
      } else {
        // lock end point
        state.rulerEnd    = pt;
        state.rulerLocked = true;
        updateRulerLabel();
      }
      renderLayers(state.currentViewState);
      return;
    }
    if (state.mode !== 'poly') return;
    const r = document.getElementById('deck-canvas').getBoundingClientRect();
    const picked = state.deckgl.pickObject({ x: e.clientX - r.left, y: e.clientY - r.top, radius: 4 });
    if (picked?.layer?.id === 'annotations') return;
    state.drawRing.push(canvasToData(e.clientX, e.clientY));
    renderLayers(state.currentViewState);
  });

  canvas.addEventListener('dblclick', () => {
    if (state.mode !== 'poly') return;
    state.drawRing.pop(); // remove 2nd click vertex
    state.drawRing.pop(); // remove 1st click vertex — both from the dblclick are unwanted
    if (state.drawRing.length >= 3) {
      const coords = [...state.drawRing, state.drawRing[0]];
      state.annotations = [...state.annotations, { id: generateAnnotId(), type: 'polygon', name: '', coords }];
      syncAnnotationsToR();
    }
    state.drawRing = [];
    renderLayers(state.currentViewState);
  });

  canvas.addEventListener('mousedown', e => {
    if (state.mode === 'lasso' || state.mode === 'freehand') {
      lassoDragged = false;
      lassoLastPx  = [e.clientX, e.clientY];
      state.lassoActive = true;
      state.lassoRing   = [canvasToData(e.clientX, e.clientY)];
    } else if (state.mode === 'rect') {
      state.rectStart   = canvasToData(e.clientX, e.clientY);
      state.rectPreview = state.rectStart;
    }
  });

  canvas.addEventListener('mousemove', e => {
    const coords = canvasToData(e.clientX, e.clientY);
    const coordEl = document.getElementById('cursor-coords');
    if (coordEl) coordEl.textContent = `${coords[0].toFixed(1)}, ${coords[1].toFixed(1)}`;

    if (state.mode === 'ruler' && state.rulerStart && !state.rulerLocked) {
      state.rulerEnd = coords;
      updateRulerLabel();
      renderLayers(state.currentViewState);
    }

    if ((state.mode === 'lasso' || state.mode === 'freehand') && state.lassoActive) {
      const dx = e.clientX - lassoLastPx[0], dy = e.clientY - lassoLastPx[1];
      if (Math.hypot(dx, dy) < (state.mode === 'freehand' ? 20 : 5)) return;
      lassoLastPx  = [e.clientX, e.clientY];
      lassoDragged = true;
      state.lassoRing.push(canvasToData(e.clientX, e.clientY));
      renderLayers(state.currentViewState);
    } else if (state.mode === 'rect' && state.rectStart) {
      state.rectPreview = canvasToData(e.clientX, e.clientY);
      renderLayers(state.currentViewState);
    }
  });

  window.addEventListener('mouseup', () => {
    if ((state.mode === 'lasso' || state.mode === 'freehand') && state.lassoActive) {
      state.lassoActive = false;
      if (lassoDragged && state.lassoRing.length >= 3) {
        if (state.mode === 'lasso') {
          const polyData = getCachedPolyData();
          if (polyData?.ids) {
            const ring  = state.lassoRing;
            const cents = polyData.centroids;
            const newSel = new Set(state.selectedCells);
            for (let i = 0; i < polyData.ids.length; i++)
              if (polyData.ids[i] != null && pointInPolygon(ring, cents[i * 2], cents[i * 2 + 1]))
                newSel.add(polyData.ids[i]);
            state.selectedCells = newSel;
            state.selVersion++;
            sendToR('cell_selection', { ids: [...newSel] });
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
      state.rectStart  = null;
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
      state.drawRing   = [];
      state.lassoRing  = [];
      state.lassoActive = false;
      state.rectStart  = null;
      state.rectPreview = null;
      state.selectedAnnotId = null;
      state.onAnnotSelect?.(null);
      if (state.mode !== 'pan') setMode('pan');
      else renderLayers(state.currentViewState);
    }
    if ((e.key === 'Delete' || e.key === 'Backspace') && state.selectedAnnotId
        && document.activeElement?.id !== 'annot-name') {
      state.annotations = state.annotations.filter(a => a.id !== state.selectedAnnotId);
      state.selectedAnnotId = null;
      state.onAnnotSelect?.(null);
      syncAnnotationsToR();
      renderLayers(state.currentViewState);
      e.preventDefault();
    }
  });

  // Gene panel
  const $search = document.getElementById('gene-search');
  $search?.addEventListener('input', () => {
    state.searchTerm = $search.value;
    renderGeneList();
  });

  const $btnColorAll = document.getElementById('btn-color-all');
  $btnColorAll?.addEventListener('click', () => {
    state.colorAll = !state.colorAll;
    $btnColorAll.classList.toggle('active', state.colorAll);
    invalidateTx();
    renderLayers(state.currentViewState);
  });

  const $btnPalette = document.getElementById('btn-palette');
  const paletteLabels = ['muted', 'vivid'];
  $btnPalette?.addEventListener('click', () => {
    state.txPaletteIdx = (state.txPaletteIdx + 1) % paletteLabels.length;
    $btnPalette.textContent = paletteLabels[state.txPaletteIdx];
    invalidateTx();
    renderLayers(state.currentViewState);
  });

  document.getElementById('btn-clear')?.addEventListener('click', () => {
    state.selectedGenes.clear();
    invalidateTx();
    renderGeneList();
    state.overviewGeneKey = null;
    updateTiles(state.currentViewState);
  });

  // Wire toggle callback (avoids circular import panel→main)
  setToggleCallback(() => {
    if (state.currentViewState?.zoom < TRANSCRIPT_ZOOM_THRESHOLD) {
      state.overviewGeneKey = null;
      updateTiles(state.currentViewState);
    } else {
      renderLayers(state.currentViewState);
    }
  });

  // Opacity + visibility controls
  makeLayerControl('show-overview','alpha-overview','val-overview',
    v => state.showOverview = v, v => state.alphaOverview = v);
  makeLayerControl('show-poly',   'alpha-poly',    'val-poly',
    v => state.showPoly = v,     v => state.alphaPoly     = v);
  makeLayerControl('show-tx',          'alpha-tx',          'val-tx',
    v => { state.showTx = v; invalidateTx(); }, v => state.alphaTx = v);
  makeLayerControl('show-annotations', 'alpha-annotations', 'val-annotations',
    v => state.showAnnotations = v, v => state.alphaAnnotations = v);

  // Metadata column selector
  document.getElementById('meta-col-select')?.addEventListener('change', async e => {
    state.metaCol = e.target.value || null;
    await buildMetaColors();
    renderLayers(state.currentViewState);
  });

  // R → viewer message handlers
  onMessage('load_metadata', async ({ url, types }) => {
    const fullUrl = `${location.origin}${url}`;
    await state.polyConn.query(
      `CREATE OR REPLACE TABLE cell_meta AS SELECT * FROM read_parquet('${fullUrl}')`
    );
    // types is a named object from R: { col_name: "categorical"|"continuous" }
    state.metaCols = Object.entries(types ?? {}).map(([name, kind]) => ({
      name,
      numeric: kind === 'continuous',
    }));
    const sel = document.getElementById('meta-col-select');
    if (sel) {
      sel.innerHTML = '<option value="">none</option>' +
        state.metaCols.map(c => `<option value="${c.name}">${c.name}</option>`).join('');
      document.getElementById('meta-panel').style.display = '';
    }
    if (state.metaCol) { await buildMetaColors(); renderLayers(state.currentViewState); }
  });

  onMessage('color_cells',    data => { /* TODO: annotation phase */ console.log('color_cells', data); });
  onMessage('highlight_genes', genes => {
    genes.forEach(g => {
      const idx = state.geneIndex.get(g);
      if (idx !== undefined) state.selectedGenes.add(idx);
    });
    invalidateTx();
    renderGeneList();
    renderLayers(state.currentViewState);
  });

  renderGeneList();
  updateTiles(initialViewState);
}

main().catch(err => {
  document.getElementById('status').textContent = 'error: ' + err.message;
  console.error(err);
});
