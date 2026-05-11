import { state } from './state.js';
import { TRANSCRIPT_ZOOM_THRESHOLD, MAX_TRANSCRIPT_TILES } from './constants.js';
import { initDB, visibleTiles, loadTile, invalidateTx, invalidatePoly, getCachedPolyData, buildMetaColors } from './data.js';
import { geneSelectionKey, getManifestOverviewBins, updateGeneOverview } from './overview.js';
import { renderLayers } from './render.js';
import { renderGeneList, setToggleCallback } from './panel.js';
import { initComms, onMessage, sendToR } from './comms.js';
import { loadMetaIntoMosaic, initMosaicPanels, sel } from './mosaic.js';
import { onCoord, notify, recomputeCrossFilter, clearFilters, sqlIds } from './coordination.js';

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

function updateTxConnector() {
  const line  = document.getElementById('tx-connector-line');
  const panel = document.getElementById('tx-lasso-panel');
  if (!line || !panel || !state.txLassoRing?.length || !panel.classList.contains('visible')) {
    line?.setAttribute('display', 'none');
    return;
  }
  const ring = state.txLassoRing;
  const cx = ring.reduce((s, p) => s + p[0], 0) / ring.length;
  const cy = ring.reduce((s, p) => s + p[1], 0) / ring.length;
  const [sx, sy] = dataToScreen(cx, cy);
  const rect = panel.getBoundingClientRect();
  const paneRect = document.getElementById('spatial-pane').getBoundingClientRect();
  line.setAttribute('x1', sx - paneRect.left);
  line.setAttribute('y1', sy - paneRect.top);
  line.setAttribute('x2', rect.left - paneRect.left);
  line.setAttribute('y2', rect.top  - paneRect.top);
  line.setAttribute('display', '');
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

function fitToAnnotation(annot) {
  const xs = annot.coords.map(p => p[0]);
  const ys = annot.coords.map(p => p[1]);
  const xmin = Math.min(...xs), xmax = Math.max(...xs);
  const ymin = Math.min(...ys), ymax = Math.max(...ys);
  const w = Math.max(xmax - xmin, 1), h = Math.max(ymax - ymin, 1);
  const zoom = Math.min(
    Math.log2(Math.min((window.innerWidth - 260) / w, window.innerHeight / h)) - 0.4,
    state.currentViewState.maxZoom
  );
  const newVS = { ...state.currentViewState, target: [(xmin+xmax)/2, (ymin+ymax)/2, 0], zoom };
  state.deckgl.setProps({ viewState: newVS });
  state.currentViewState = newVS;
  updateScalebar(newVS);
  renderLayers(newVS);
}

function syncAnnotationsToR() { notify('annotations'); }

function setMode(m) {
  state.mode = m;
  state.drawRing   = [];
  state.lassoRing  = [];
  state.lassoActive = false;
  state.rectStart  = null;
  state.rectPreview = null;
  state.brushDown = false;
  state.brushPos  = null;
  state.deckgl.setProps({ controller: (m === 'lasso' || m === 'txlasso' || m === 'rect' || m === 'freehand' || m === 'brush')
    ? { dragPan: false, doubleClickZoom: false }
    : { doubleClickZoom: false } });
  document.querySelectorAll('.tool-btn[data-mode]').forEach(b =>
    b.classList.toggle('active', b.dataset.mode === m)
  );
  document.getElementById('btn-group-draw')?.classList.toggle('active', ['poly','rect','freehand'].includes(m));
  document.getElementById('btn-group-select')?.classList.toggle('active', ['lasso','brush'].includes(m));
  document.getElementById('btn-group-measure')?.classList.toggle('active', ['ruler','txlasso'].includes(m));
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
  state.currentViewState = viewState;
  state.deckgl.setProps({ viewState });
  updateScalebar(viewState);
  updateRulerLabel();
  updateTxConnector();
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

  document.getElementById('btn-fit-spatial')?.addEventListener('click', () => {
    state.deckgl.setProps({ viewState: initialViewState });
    state.currentViewState = initialViewState;
    updateScalebar(initialViewState);
    updateTiles(initialViewState);
  });

  // ── Coordination handlers ─────────────────────────────────────────────────
  onCoord('cellSelection', () => {
    sendToR('cell_selection', { ids: [...state.selectedCells] });
    renderLayers(state.currentViewState);
  });
  onCoord('metaColors', () => {
    renderMetaLegend();
    renderLayers(state.currentViewState);
  });

  document.getElementById('btn-crossfilter')?.addEventListener('click', () => {
    state.crossFilter = !state.crossFilter;
    document.getElementById('btn-crossfilter')?.classList.toggle('active', state.crossFilter);
    if (!state.crossFilter) {
      // Drop filter state but keep the current selectedCells as-is
      state.spatialFilter = null;
      state.scatterFilter = null;
      try { sel.update({ source: 'spatial', predicate: null }); } catch(_) {}
    }
  });

  // ── Split.js layout ──────────────────────────────────────────────────────
  const mainSplit = Split(['#spatial-pane', '#stats-column'], {
    sizes: [65, 35], minSize: [150, 0], gutterSize: 5, snapOffset: 40,
    onDragEnd: () => {
      window.dispatchEvent(new Event('resize'));
      if (state.currentViewState) updateScalebar(state.currentViewState);
    },
  });

  let statsOpen = true;
  let lastStatsSizes = [65, 35];
  document.getElementById('btn-stats-toggle')?.addEventListener('click', () => {
    statsOpen = !statsOpen;
    if (statsOpen) {
      mainSplit.setSizes(lastStatsSizes);
    } else {
      lastStatsSizes = mainSplit.getSizes();
      mainSplit.setSizes([100, 0]);
    }
    window.dispatchEvent(new Event('resize'));
    document.getElementById('btn-stats-toggle')?.classList.toggle('active', statsOpen);
  });
  document.getElementById('btn-stats-toggle')?.classList.add('active');

  document.querySelectorAll('.stats-collapse-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      btn.closest('.stats-pane').classList.toggle('stats-collapsed');
    });
  });

  // ── Collapsible panel sections ────────────────────────────────────────────
  document.querySelectorAll('.section-hd').forEach(hd =>
    hd.addEventListener('click', () => hd.closest('[id]').classList.toggle('section-collapsed'))
  );

  // ── Annotation popup ─────────────────────────────────────────────────────
  const $annotPopup = document.getElementById('annot-popup');
  const $annotName  = document.getElementById('annot-name');
  const $annotType  = document.getElementById('annot-type');

  onCoord('annotSelect', () => {
    const id = state.selectedAnnotId;
    if (id) {
      const annot = state.annotations.find(a => a.id === id);
      if ($annotName) $annotName.value      = annot?.name ?? '';
      if ($annotType) $annotType.textContent = annot?.type ?? '';
      $annotPopup?.classList.add('visible');
    } else {
      $annotPopup?.classList.remove('visible');
    }
  });

  $annotName?.addEventListener('input', () => {
    if (!state.selectedAnnotId) return;
    state.annotations = state.annotations.map(a =>
      a.id === state.selectedAnnotId ? { ...a, name: $annotName.value } : a
    );
    syncAnnotationsToR();
  });

  // ── Annotation list panel ────────────────────────────────────────────────
  const TYPE_ABBR = { polygon: 'poly', rectangle: 'rect', freehand: 'free' };

  function renderAnnotList() {
    const list  = document.getElementById('annot-list');
    const panel = document.getElementById('annot-panel');
    if (!list || !panel) return;
    panel.style.display = state.annotations.length ? '' : 'none';
    list.innerHTML = '';
    state.annotations.forEach(a => {
      const row  = document.createElement('div');
      row.className = 'annot-row' + (a.id === state.selectedAnnotId ? ' selected' : '');
      row.dataset.id = a.id;
      const tag  = TYPE_ABBR[a.type] ?? a.type;
      const name = a.name ? a.name : '<span class="annot-unnamed">unnamed</span>';
      row.innerHTML =
        `<span class="annot-type-tag ${a.type}">${tag}</span>` +
        `<span class="annot-name-text">${name}</span>` +
        `<button class="annot-row-btn annot-row-nav" title="zoom to">` +
          `<i data-lucide="locate"></i></button>` +
        `<button class="annot-row-btn annot-row-del" title="delete">` +
          `<i data-lucide="x"></i></button>`;
      row.querySelector('.annot-row-nav').addEventListener('click', e => {
        e.stopPropagation();
        fitToAnnotation(a);
      });
      row.querySelector('.annot-row-del').addEventListener('click', e => {
        e.stopPropagation();
        state.annotations = state.annotations.filter(x => x.id !== a.id);
        if (state.selectedAnnotId === a.id) { state.selectedAnnotId = null; notify('annotSelect'); }
        syncAnnotationsToR();
        renderLayers(state.currentViewState);
      });
      row.addEventListener('click', () => {
        const newId = a.id === state.selectedAnnotId ? null : a.id;
        state.selectedAnnotId = newId;
        notify('annotSelect');
        renderLayers(state.currentViewState);
      });
      list.appendChild(row);
    });
    lucide.createIcons({ nodes: list.querySelectorAll('[data-lucide]') });
  }

  onCoord('annotations', () => {
    sendToR('annotations_update', {
      annotations: state.annotations.map(a => ({
        id: a.id, type: a.type, name: a.name ?? '',
        geojson: JSON.stringify({ type: 'Feature', geometry: { type: 'Polygon', coordinates: [a.coords] } })
      }))
    });
    renderAnnotList();
  });

  // ── Toolbar mode buttons ──────────────────────────────────────────────────
  function toggleGroup(groupId, ...otherIds) {
    const grp = document.getElementById(groupId);
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

  const $metaSelPanel = document.getElementById('meta-sel-panel');
  document.getElementById('tool-meta-sel')?.addEventListener('click', () => {
    if (!$metaSelPanel) return;
    const open = $metaSelPanel.classList.toggle('visible');
    if (open) {
      const sel = document.getElementById('meta-sel-col');
      if (sel) {
        sel.innerHTML = state.metaCols.length
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

  // ── Transcript lasso ──────────────────────────────────────────────────────
  async function _runTxLasso(ring) {
    const panel  = document.getElementById('tx-lasso-panel');
    const title  = document.getElementById('tx-lasso-title');
    const list   = document.getElementById('tx-lasso-results');
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

  document.getElementById('tx-lasso-close')?.addEventListener('click', () => {
    state.txLassoRing = null;
    document.getElementById('tx-lasso-panel')?.classList.remove('visible');
    updateTxConnector();
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
    if (state.mode === 'brush') {
      state.brushDown = true;
      state.brushPos  = canvasToData(e.clientX, e.clientY);
    } else if (state.mode === 'lasso' || state.mode === 'freehand' || state.mode === 'txlasso') {
      if (state.mode === 'txlasso') {
        state.txLassoRing = null;
        document.getElementById('tx-lasso-panel')?.classList.remove('visible');
        updateTxConnector();
      }
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

    if (state.mode === 'brush') {
      state.brushPos = coords;
      if (state.brushDown) {
        const r = state.brushRadius / Math.pow(2, state.currentViewState.zoom);
        const polyData = getCachedPolyData();
        if (polyData?.ids) {
          const cents = polyData.centroids;
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
            const ring  = state.lassoRing;
            const cents = polyData.centroids;
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
            } else { state.selectedCells = new Set([...state.selectedCells, ...lassoSet]); state.selVersion++; notify('cellSelection'); }
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

  // ── Metadata color legend ────────────────────────────────────────────────
  function renderMetaLegend() {
    const el = document.getElementById('meta-legend');
    if (!el) return;
    if (!state.metaLegend) { el.innerHTML = ''; return; }
    if (state.metaLegend.type === 'continuous') {
      const { min, max } = state.metaLegend;
      el.innerHTML =
        `<div class="legend-gradient"></div>` +
        `<div class="legend-labels"><span>${min.toFixed(2)}</span><span>${max.toFixed(2)}</span></div>`;
    } else {
      const items = state.metaLegend.items.slice(0, 30);
      el.innerHTML = items.map(({ label, color }) =>
        `<div class="legend-item">` +
        `<span class="legend-dot" style="background:rgb(${color[0]},${color[1]},${color[2]})"></span>` +
        `<span class="legend-label">${label}</span></div>`
      ).join('') + (state.metaLegend.items.length > 30
        ? `<div class="legend-overflow">+${state.metaLegend.items.length - 30} more</div>` : '');
    }
  }

  // Metadata column selector
  document.getElementById('meta-col-select')?.addEventListener('change', async e => {
    state.metaCol = e.target.value || null;
    await buildMetaColors();
    notify('metaColors');
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
    if (state.metaCol) { await buildMetaColors(); notify('metaColors'); }

    await loadMetaIntoMosaic(fullUrl);
    initMosaicPanels(state.metaCols);
  });

  onMessage('set_selection', ({ ids }) => {
    if (state.crossFilter) {
      state.crossFilter = false;
      state.spatialFilter = null;
      state.scatterFilter = null;
      document.getElementById('btn-crossfilter')?.classList.remove('active');
    }
    state.selectedCells = new Set(ids ?? []);
    state.selVersion++;
    renderLayers(state.currentViewState);
  });

  onMessage('push_polygons', ({ polygons }) => {
    const incoming = (polygons ?? []).map(p => ({
      id: generateAnnotId(), type: 'polygon',
      name: p.name ?? '', coords: p.coords,
    }));
    state.annotations = [...state.annotations, ...incoming];
    notify('annotations');
    renderLayers(state.currentViewState);
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
