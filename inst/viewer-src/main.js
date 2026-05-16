import { state } from './state.js';
import { TRANSCRIPT_ZOOM_THRESHOLD, MAX_TRANSCRIPT_TILES } from './constants.js';
import { initDB, visibleTiles, loadTile, invalidateTx, invalidatePoly, buildMetaColors, buildCellMetaCache } from './data.js';
import { geneSelectionKey, getManifestOverviewBins, updateGeneOverview } from './overview.js';
import { renderLayers } from './render.js';
import { renderGeneList, setToggleCallback } from './panel.js';
import { initComms, onMessage, sendToR } from './comms.js';
import { loadMetaIntoMosaic, initMosaicPanels } from './mosaic.js';
import { onCoord, notify } from './coordination.js';
import { updateScalebar } from './ui.js';
import { initAnnotations, generateAnnotId } from './annotations.js';
import { updateRulerLabel, updateTxConnector, initInput } from './input.js';
import { Deck, OrthographicView } from 'deck.gl';
import Split from 'split.js';
import { createIcons, icons } from 'lucide';

// Initialise lucide icons for static toolbar elements in the HTML.
// ES modules are deferred, so this runs after DOM is parsed.
createIcons({ icons });

// ── Tile eviction + load scheduling ──────────────────────────────────────────
function updateTiles(viewState) {
  state.currentViewState = viewState;
  const newTier = Math.min(3, Math.max(0, Math.floor(viewState.zoom - TRANSCRIPT_ZOOM_THRESHOLD)));
  if (newTier !== state.txZoomTier) { state.txZoomTier = newTier; invalidateTx(); }
  const txLayer       = state.manifest.layers.transcripts;
  const txAboveThresh = state.showTx && txLayer && viewState.zoom >= TRANSCRIPT_ZOOM_THRESHOLD;
  // Polygon tiles always stay in scope — only 12 tiles, centroids needed at all zooms
  const hasPoly       = state.showPoly && state.manifest.layers.polygons;
  const inScope       = new Set();

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
      .forEach(t => loadTile('transcripts', t, vs => { renderLayers(vs); updateTiles(vs); }));
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

  state.deckgl = new Deck({
    canvas: 'deck-canvas', width: '100%', height: '100%',
    views: new OrthographicView({ id: 'ortho', controller: true, flipY: false }),
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

  initAnnotations();
  initInput();

  // ── Split.js layout ───────────────────────────────────────────────────────
  const mainSplit = Split(['#spatial-pane', '#stats-column'], {
    sizes: [65, 35], minSize: [150, 0], gutterSize: 5, snapOffset: 40,
    onDragEnd: () => {
      window.dispatchEvent(new Event('resize'));
      if (state.currentViewState) updateScalebar(state.currentViewState);
    },
  });

  let statsOpen      = true;
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

  document.querySelectorAll('.stats-collapse-btn').forEach(btn =>
    btn.addEventListener('click', () => btn.closest('.stats-pane').classList.toggle('stats-collapsed'))
  );

  // ── Collapsible panel sections ────────────────────────────────────────────
  document.querySelectorAll('.section-hd').forEach(hd =>
    hd.addEventListener('click', () => hd.closest('[id]').classList.toggle('section-collapsed'))
  );

  // ── Gene panel ────────────────────────────────────────────────────────────
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

  const $btnPalette   = document.getElementById('btn-palette');
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

  setToggleCallback(() => {
    if (state.currentViewState?.zoom < TRANSCRIPT_ZOOM_THRESHOLD) {
      state.overviewGeneKey = null;
      updateTiles(state.currentViewState);
    } else {
      renderLayers(state.currentViewState);
    }
  });

  // ── Opacity + visibility controls ─────────────────────────────────────────
  makeLayerControl('show-overview', 'alpha-overview', 'val-overview',
    v => state.showOverview = v, v => state.alphaOverview = v);
  makeLayerControl('show-poly',     'alpha-poly',     'val-poly',
    v => state.showPoly = v,     v => state.alphaPoly     = v);
  makeLayerControl('show-tx',       'alpha-tx',       'val-tx',
    v => { state.showTx = v; invalidateTx(); }, v => state.alphaTx = v);
  makeLayerControl('show-annotations', 'alpha-annotations', 'val-annotations',
    v => state.showAnnotations = v, v => state.alphaAnnotations = v);

  // ── Metadata color legend ─────────────────────────────────────────────────
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

  document.getElementById('meta-col-select')?.addEventListener('change', async e => {
    state.metaCol = e.target.value || null;
    await buildMetaColors();
    notify('metaColors');
  });

  // ── R → viewer message handlers ───────────────────────────────────────────
  onMessage('load_metadata', async ({ url, types }) => {
    const fullUrl = `${location.origin}${url}`;
    await state.polyConn.query(
      `CREATE OR REPLACE TABLE cell_meta AS SELECT * FROM read_parquet('${fullUrl}')`
    );
    state.metaCols = Object.entries(types ?? {}).map(([name, kind]) => ({
      name,
      numeric: kind === 'continuous',
    }));
    const colSel = document.getElementById('meta-col-select');
    if (colSel) {
      colSel.innerHTML = '<option value="">none</option>' +
        state.metaCols.map(c => `<option value="${c.name}">${c.name}</option>`).join('');
      document.getElementById('meta-panel').style.display = '';
    }
    if (state.metaCol) { await buildMetaColors(); notify('metaColors'); }
    await buildCellMetaCache();
    await loadMetaIntoMosaic(fullUrl);
    initMosaicPanels(state.metaCols);
  });

  onMessage('set_selection', ({ ids }) => {
    if (state.crossFilter) {
      state.crossFilter   = false;
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

  onMessage('color_cells',     data  => { console.log('color_cells', data); });
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
