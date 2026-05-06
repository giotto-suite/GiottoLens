import { state } from './state.js';
import { TRANSCRIPT_ZOOM_THRESHOLD, POLYGON_ZOOM_THRESHOLD, MAX_TRANSCRIPT_TILES } from './constants.js';
import { initDB, visibleTiles, loadTile, invalidateTx, invalidatePoly } from './data.js';
import { geneSelectionKey, getManifestOverviewBins, buildCompositeOverview, updateGeneOverview } from './overview.js';
import { renderLayers } from './render.js';
import { renderGeneList, setToggleCallback } from './panel.js';
import { initComms, onMessage, sendToR } from './comms.js';

// ── Tile eviction + load scheduling ──────────────────────────────────────────
function updateTiles(viewState) {
  state.currentViewState = viewState;
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
    Math.min(window.innerWidth  / (ext.xmax - ext.xmin),
             window.innerHeight / (ext.ymax - ext.ymin))
  ) - 0.3;

  const initialViewState = { target: [cx, cy, 0], zoom, minZoom: zoom - 2, maxZoom: zoom + 12 };

  state.deckgl = new deck.Deck({
    canvas: 'deck-canvas', width: '100%', height: '100%',
    views: new deck.OrthographicView({ id: 'ortho', controller: true }),
    initialViewState, controller: true, onViewStateChange, layers: [],
  });
  updateScalebar(initialViewState);

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
  makeLayerControl('show-tx',     'alpha-tx',      'val-tx',
    v => { state.showTx = v; invalidateTx(); }, v => state.alphaTx = v);

  // R → viewer message handlers
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
