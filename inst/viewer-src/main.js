import { state } from './core/state.js';
import { store, actions } from './core/store.ts';
import { initComms, onMessage, reportError } from './core/comms.js';
import { initRemote } from './core/remote.js';
import { invalidateTx } from './data/tiles.js';
import { loadCells } from './data/cells.ts';
import { setTransfer } from './data/parquet.ts';
import { loadMeta } from './data/meta.ts';
import { updateTiles, scheduleTiles, setViewState } from './data/schedule.js';
import { initSelection, recompute } from './selection/selection.ts';
import { cellColorBuffer } from './render/colors.ts';
import { initRenderScheduler, requestRender } from './render/schedule.js';
import { renderGeneList, setGeneSearch } from './ui/panel.js';
import { renderLegend } from './ui/legend.js';
import { initAnnotations, generateAnnotId } from './ui/annotations.js';
import { updateRulerLabel, updateTxConnector, initInput } from './ui/input.js';
import { initReleaseGuard } from './ui/release.js';
import { initRuleStrip } from './ui/rules.js';
import { updateScalebar, fitZoom, escapeHtml } from './ui/dom.js';
import { createScatterPanel } from './panels/scatter.js';
import { createHistogramPanel } from './panels/histogram.js';
import { createSpecPanel } from './panels/spec.js';
import { Deck, OrthographicView } from 'deck.gl';
import Split from 'split.js';
import { createIcons, icons } from 'lucide';

// Initialise lucide icons for static toolbar elements in the HTML.
// ES modules are deferred, so this runs after DOM is parsed.
createIcons({ icons });

const $status = msg => { document.getElementById('status').textContent = msg; };

function onViewStateChange({ viewState }) {
  state.currentViewState = viewState;
  state.deckgl.setProps({ viewState });
  updateScalebar(viewState);
  updateRulerLabel();
  updateTxConnector();
  requestRender();
  scheduleTiles(viewState);
}

// ── Layer controls ────────────────────────────────────────────────────────────
function bindLayerControl(name, checkId, sliderId, valId) {
  const check  = document.getElementById(checkId);
  const slider = document.getElementById(sliderId);
  const label  = document.getElementById(valId);
  if (!check || !slider) return;
  const sync = ({ show, alpha }) => {
    check.checked = show;
    slider.disabled = !show;
    slider.value = Math.round(alpha * 100);
    if (label) label.textContent = slider.value;
  };
  sync(store.getState().layers[name]);
  store.subscribe(s => s.layers[name], sync);
  check.addEventListener('change', () => actions.setLayer(name, { show: check.checked }));
  slider.addEventListener('input', () => actions.setLayer(name, { alpha: slider.value / 100 }));
}

// ── Cell colours ──────────────────────────────────────────────────────────────
function recolorCells() {
  if (!state.cells) return;
  const col = store.getState().colorBy;
  const { colors, legend } = cellColorBuffer(state.cells.n, col ? state.meta?.get(col) ?? null : null);
  state.cellColors  = colors;
  state.colorLegend = legend;
  renderLegend();
  actions.bumpMeta();
}

// ── Stats panels ──────────────────────────────────────────────────────────────
// Pane i shows either a built-in panel or a spec pushed from R; a pushed spec
// stays until replaced, and metadata reloads leave it alone.
const _panels = [null, null];
const _pushed = [false, false];
const _paneBody = i => document.getElementById(`stats-body-${i + 1}`);
function setPanel(i, panel) {
  _panels[i]?.destroy();
  _panels[i] = panel;
}
function initPanels() {
  if (!state.meta?.size) return;
  if (!_pushed[0]) setPanel(0, createScatterPanel(_paneBody(0)));
  if (!_pushed[1]) setPanel(1, createHistogramPanel(_paneBody(1)));
}

// ── Bootstrap ─────────────────────────────────────────────────────────────────
async function main() {
  $status('loading manifest…');
  state.manifest = await fetch('session/manifest.json').then(r => {
    if (!r.ok) throw new Error(`manifest.json not found (${r.status})`);
    return r.json();
  });
  // Tile URLs are relative to this page so the viewer works behind a
  // path-prefixing proxy; fetch resolves them, but keep them absolute anyway
  for (const layer of Object.values(state.manifest.layers))
    for (const t of layer.tiles ?? []) {
      t.url = new URL(t.url, document.baseURI).href;
      if (t.file) t.file = new URL(t.file, document.baseURI).href;
    }
  setTransfer(state.manifest.transfer ?? 'auto');

  const txLayer   = state.manifest.layers.transcripts;
  const polyLayer = state.manifest.layers.polygons;
  state.geneIndex = new Map((txLayer?.genes ?? []).map((g, i) => [g, i]));
  if (!txLayer) {
    // Polygons-only launch: no gene list or transcript controls
    document.getElementById('panel-header').style.display = 'none';
    document.getElementById('gene-list').style.display = 'none';
    document.getElementById('show-tx')?.closest('.alpha-row')?.remove();
    document.querySelector('[data-mode="txlasso"]')?.remove();
  }
  // Points-only launch: transcripts are all there is to show
  if (txLayer && !polyLayer) actions.setLayer('tx', { show: true });

  if (polyLayer) {
    $status('loading cells…');
    state.cells = await loadCells(polyLayer);
    const { n, x, y } = state.cells;
    state.cellPositions = new Float32Array(n * 2);
    for (let i = 0; i < n; i++) { state.cellPositions[i * 2] = x[i]; state.cellPositions[i * 2 + 1] = y[i]; }
    recolorCells();
  }

  // Split first so the canvas has its final size when the zoom is fitted
  const mainSplit = Split(['#spatial-pane', '#stats-column'], {
    sizes: [65, 35], minSize: [150, 0], gutterSize: 5, snapOffset: 40,
    onDragEnd: () => {
      window.dispatchEvent(new Event('resize'));
      if (state.currentViewState) updateTiles(state.currentViewState);
    },
  });

  const ext  = state.manifest.extent;
  const zoom = fitZoom(ext.xmax - ext.xmin, ext.ymax - ext.ymin) - 0.3;
  const initialViewState = {
    target: [(ext.xmin + ext.xmax) / 2, (ext.ymin + ext.ymax) / 2, 0],
    zoom, minZoom: zoom - 2, maxZoom: zoom + 12,
  };

  state.deckgl = new Deck({
    canvas: 'deck-canvas', width: '100%', height: '100%',
    views: new OrthographicView({ id: 'ortho', controller: true, flipY: false }),
    initialViewState, controller: { doubleClickZoom: false }, onViewStateChange, layers: [],
  });
  state.currentViewState = initialViewState;
  updateScalebar(initialViewState);

  document.getElementById('btn-fit-spatial')?.addEventListener('click', () =>
    setViewState(initialViewState));

  // ── Store subscriptions ───────────────────────────────────────────────────
  initRenderScheduler();
  initSelection();
  store.subscribe(s => s.colorBy, recolorCells);
  store.subscribe(s => s.layers, () => { invalidateTx(); updateTiles(state.currentViewState); });
  store.subscribe(s => [s.genes, s.txPalette, s.colorAll], () => { invalidateTx(); renderGeneList(); },
    { equalityFn: (a, b) => a.every((v, i) => v === b[i]) });

  initAnnotations();
  initInput();
  initReleaseGuard();
  initRuleStrip();

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
    if (state.currentViewState) updateTiles(state.currentViewState);
    document.getElementById('btn-stats-toggle')?.classList.toggle('active', statsOpen);
  });
  document.getElementById('btn-stats-toggle')?.classList.add('active');

  document.querySelectorAll('.stats-collapse-btn').forEach(btn =>
    btn.addEventListener('click', () => btn.closest('.stats-pane').classList.toggle('stats-collapsed'))
  );
  document.querySelectorAll('.section-hd').forEach(hd =>
    hd.addEventListener('click', () => hd.closest('[id]').classList.toggle('section-collapsed'))
  );

  // ── Gene panel ────────────────────────────────────────────────────────────
  const $search = document.getElementById('gene-search');
  $search?.addEventListener('input', () => setGeneSearch($search.value));

  const $btnColorAll = document.getElementById('btn-color-all');
  $btnColorAll?.addEventListener('click', () => actions.setColorAll(!store.getState().colorAll));
  store.subscribe(s => s.colorAll, on => $btnColorAll?.classList.toggle('active', on));

  const $btnPalette   = document.getElementById('btn-palette');
  const paletteLabels = ['muted', 'vivid'];
  $btnPalette?.addEventListener('click', () =>
    actions.setTxPalette((store.getState().txPalette + 1) % paletteLabels.length));
  store.subscribe(s => s.txPalette, i => { if ($btnPalette) $btnPalette.textContent = paletteLabels[i]; });

  document.getElementById('btn-clear')?.addEventListener('click', () => actions.clearGenes());

  // ── Layers ────────────────────────────────────────────────────────────────
  bindLayerControl('poly',        'show-poly',        'alpha-poly',        'val-poly');
  bindLayerControl('tx',          'show-tx',          'alpha-tx',          'val-tx');
  bindLayerControl('annotations', 'show-annotations', 'alpha-annotations', 'val-annotations');

  const $colSel = document.getElementById('meta-col-select');
  $colSel?.addEventListener('change', e => actions.setColorBy(e.target.value || null));
  store.subscribe(s => s.colorBy, c => { if ($colSel) $colSel.value = c ?? ''; });

  // ── R → viewer messages ───────────────────────────────────────────────────
  let metaUrl = null;
  onMessage('load_metadata', async ({ url, columns }) => {
    // A reconnect re-sends the current metadata; keep the panels as they are
    if (!state.cells || url === metaUrl) return;
    metaUrl = url;
    state.meta = await loadMeta(url, columns ?? []);
    if ($colSel) {
      $colSel.innerHTML = '<option value="">none</option>' +
        [...state.meta.keys()].map(c => `<option value="${escapeHtml(c)}">${escapeHtml(c)}</option>`).join('');
      document.getElementById('meta-panel').style.display = '';
    }
    const colorBy = store.getState().colorBy;
    if (colorBy && !state.meta.has(colorBy)) actions.setColorBy(null);
    else recolorCells();
    // Rules on metadata columns re-evaluate against the new table
    recompute({ reset: true });
    initPanels();
  });

  onMessage('push_panel', async ({ pane, ...panel }) => {
    const i = Math.min(2, Math.max(1, pane ?? 2)) - 1;
    _pushed[i] = true;
    _panels[i]?.destroy();
    _panels[i] = null;
    setPanel(i, await createSpecPanel(_paneBody(i), panel));
  });

  onMessage('push_polygons', ({ polygons }) =>
    actions.addAnnotations((polygons ?? []).map(p => ({
      id: generateAnnotId(), type: 'polygon', name: p.name ?? '', coords: p.coords,
    }))));

  initRemote();
  initComms();   // after every handler is registered

  renderGeneList();
  $status('ready');
  updateTiles(initialViewState);
}

// Handles for tests and debugging from the browser console
window.__giottolens = { state, store, actions, panels: _panels };

main().catch(err => {
  $status('error: ' + err.message);
  initComms();   // so the error still reaches R
  reportError(err, 'boot');
});
