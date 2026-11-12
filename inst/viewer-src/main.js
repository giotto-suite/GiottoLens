import { state } from './core/state.js';
import { store, actions } from './core/store.ts';
import { initComms, onMessage, reportError, setHello } from './core/comms.js';
import { initRemote } from './core/remote.js';
import { invalidateTx } from './data/tiles.js';
import { loadCells } from './data/cells.ts';
import { setTransfer } from './data/parquet.ts';
import { setMetaInfo, needColumns, prefetchColumns } from './data/meta.ts';
import { openImage } from './data/images.ts';
import { ImagePool } from './data/img-pool.ts';
import { updateTiles, scheduleTiles, setViewState, onSetView } from './data/schedule.js';
import { initSelection, recompute } from './selection/selection.ts';
import { onLive } from './selection/live.ts';
import { cellColorBuffer } from './render/colors.ts';
import { initRenderScheduler, requestRender } from './render/schedule.js';
import { initAnnotations, generateAnnotId } from './ui/annotations.js';
import { updateRulerLabel, updateTxConnector, initInput } from './ui/input.js';
import { initReleaseGuard } from './ui/release.js';
import { initRuleStrip } from './ui/rules.js';
import { initRegistration, onMainView } from './ui/registration.ts';
import { updateScalebar, fitZoom, dragPan } from './ui/dom.js';
import { initDock, placeControls, refreshBuiltins, pushPanel, removePanel, panelHandle, CONTROL_WIDTH } from './panels/dock.ts';
import { initPersist } from './core/persist.ts';
import { Deck, OrthographicView } from 'deck.gl';
import Split from 'split.js';
import { createIcons, icons } from 'lucide';

// Initialise lucide icons for static toolbar elements in the HTML.
// ES modules are deferred, so this runs after DOM is parsed.
createIcons({ icons });

const $status = msg => { document.getElementById('status').textContent = msg; };

// The camera is saved with the config, a moment after it stops moving
let viewTimer;
function saveView(viewState) {
  clearTimeout(viewTimer);
  viewTimer = setTimeout(() => actions.setView({
    target: [viewState.target[0], viewState.target[1]], zoom: viewState.zoom,
  }), 250);
}

function onViewStateChange({ viewState }) {
  saveView(viewState);
  state.currentViewState = viewState;
  state.deckgl.setProps({ viewState });
  updateScalebar(viewState);
  updateRulerLabel();
  updateTxConnector();
  onMainView(viewState);
  requestRender();
  scheduleTiles(viewState);
}

// ── Cell colours ──────────────────────────────────────────────────────────────
function recolorCells() {
  if (!state.cells) return;
  const s = store.getState();
  const col = s.colorBy;
  // Keep the current colours while the column loads
  if (col && !state.meta?.has(col) && state.metaInfo?.has(col)) {
    needColumns([col]).then(() => { if (store.getState().colorBy === col && state.meta?.has(col)) recolorCells(); });
    return;
  }
  const { colors, fill, legend } = cellColorBuffer(state.cells.n, col ? state.meta?.get(col) ?? null : null,
    col ? s.categoryStyles[col] : undefined, col ? s.colorScales[col] : undefined);
  state.cellColors  = colors;
  state.cellFill    = fill;
  state.colorLegend = legend;
  actions.bumpMeta();
}

// ── Images ────────────────────────────────────────────────────────────────────
// Opened in manifest order; the first is shown. One that fails to open is
// reported to R and left out.
const IMAGE_COLORS = [[64, 128, 255], [0, 255, 128], [255, 64, 64], [255, 200, 0], [255, 0, 255], [0, 255, 255]];
async function loadImages(entries) {
  if (!entries.length) return;
  const pool = new ImagePool();
  const opened = await Promise.allSettled(entries.map(e => openImage(e, pool, state.manifest.extent)));
  state.images = new Map();
  opened.forEach((r, i) => {
    if (r.status === 'rejected') { reportError(r.reason, `image '${entries[i].name}' is not shown`); return; }
    const img = r.value, k = state.images.size;
    state.images.set(img.entry.name, img);
    const channels = [...state.images.values()].filter(i => !i.rgb).length;
    actions.setImage(img.entry.name, img.rgb ? { show: k === 0, rgb: true } : {
      show: k === 0, color: IMAGE_COLORS[(channels - 1) % IMAGE_COLORS.length], contrast: img.contrast,
    });
  });
}

// ── Bootstrap ─────────────────────────────────────────────────────────────────
async function main() {
  $status('loading manifest…');
  // Never from the cache: the file changes when R loads another object
  state.manifest = await fetch('session/manifest.json', { cache: 'no-store' }).then(r => {
    if (!r.ok) throw new Error(`manifest.json not found (${r.status})`);
    return r.json();
  });
  // R loaded another object (set_object()): start over with its manifest
  onMessage('reload', () => location.reload());
  setHello({ load: state.manifest.load });
  if (state.manifest.empty) {
    showEmpty();
    return;
  }
  // Tile URLs are relative to this page so the viewer works behind a
  // path-prefixing proxy; fetch resolves them, but keep them absolute anyway
  for (const layer of Object.values(state.manifest.layers))
    for (const t of layer.tiles ?? []) {
      if (!t.url) continue;   // a cell chunk without polygons has no file
      t.url = new URL(t.url, document.baseURI).href;
      if (t.file) t.file = new URL(t.file, document.baseURI).href;
    }
  setTransfer(state.manifest.transfer ?? 'auto');
  const imagesLoaded = loadImages(state.manifest.images ?? []);

  const txLayer   = state.manifest.layers.transcripts;
  const cellLayer = state.manifest.layers.cells;
  state.geneIndex = new Map((txLayer?.genes ?? []).map((g, i) => [g, i]));
  // Polygons-only launch: no transcript tools (nor a transcripts panel)
  if (!txLayer) document.querySelector('[data-mode="txlasso"]')?.remove();
  // Points-only launch: transcripts are all there is to show
  if (txLayer && !cellLayer) actions.setLayer('tx', { show: true });

  if (cellLayer) {
    $status('loading cells…');
    state.cells = await loadCells(cellLayer);
    const { n, x, y } = state.cells;
    state.cellPositions = new Float32Array(n * 2);
    for (let i = 0; i < n; i++) { state.cellPositions[i * 2] = x[i]; state.cellPositions[i * 2 + 1] = y[i]; }
    recolorCells();
  }

  // Split first so the canvas has its final size when the zoom is fitted. The
  // charts get 35% of what the controls' column leaves
  const width = document.getElementById('main-layout').clientWidth || window.innerWidth;
  const dockPct = Math.min(60, (0.35 * (width - CONTROL_WIDTH) + CONTROL_WIDTH) / width * 100);
  const mainSplit = Split(['#spatial-pane', '#dock'], {
    sizes: [100 - dockPct, dockPct], minSize: [150, 0], gutterSize: 5, snapOffset: 40,
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
  dragPan(document.getElementById('deck-canvas'), () => state.currentViewState,
    viewState => onViewStateChange({ viewState }));
  state.currentViewState = initialViewState;
  updateScalebar(initialViewState);

  document.getElementById('btn-fit-spatial')?.addEventListener('click', () =>
    setViewState(initialViewState));

  // ── Store subscriptions ───────────────────────────────────────────────────
  initRenderScheduler();
  onLive(requestRender);
  initSelection();
  store.subscribe(s => s.colorBy, recolorCells);
  store.subscribe(s => s.categoryStyles, recolorCells);
  store.subscribe(s => s.colorScales, recolorCells);
  store.subscribe(s => s.layers, () => { invalidateTx(); updateTiles(state.currentViewState); });
  store.subscribe(s => [s.genes, s.txPalette, s.colorAll], invalidateTx,
    { equalityFn: (a, b) => a.every((v, i) => v === b[i]) });

  initAnnotations();
  initInput();
  initReleaseGuard();
  initRuleStrip();
  initDock(document.getElementById('dock'));

  let statsOpen      = true;
  let lastStatsSizes = mainSplit.getSizes();
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

  // ── R → viewer messages ───────────────────────────────────────────────────
  onMessage('load_metadata', ({ columns }) => {
    // A reconnect re-sends the current metadata; keep the panels as they are
    if (!state.cells || !setMetaInfo(columns ?? [])) return;
    const colorBy = store.getState().colorBy;
    if (colorBy && !state.metaInfo.has(colorBy)) actions.setColorBy(null);
    else recolorCells();
    // Rules on metadata columns re-evaluate against the new columns
    recompute({ reset: true });
    refreshBuiltins();
    // Whatever the view and panels asked for loads first
    prefetchColumns();
  });

  onMessage('push_panel', pushPanel);
  onMessage('remove_panel', ({ id }) => { removePanel(id); });

  onMessage('push_polygons', ({ polygons }) =>
    actions.addAnnotations((polygons ?? []).map(p => ({
      id: generateAnnotId(), type: 'polygon', name: p.name ?? '', coords: p.coords,
    }))));

  // Before R can ask about images
  await imagesLoaded;
  placeControls();   // the images and register panels, now that images are open
  initRegistration();

  initRemote();
  // The saved config comes from R on connect ('restore'), over the defaults
  // set above, images included
  initPersist();
  // A saved camera replaces the fitted one
  store.persist.onFinishHydration(s => {
    if (s.view) setViewState({ ...initialViewState, target: [s.view.target[0], s.view.target[1], 0],
      zoom: s.view.zoom });
  });
  onSetView(saveView);
  store.persist.rehydrate();
  initComms();   // after every handler is registered

  $status('ready');
  updateTiles(initialViewState);
}

// No object loaded: say how to load one, and wait for R to
function showEmpty() {
  document.body.classList.add('empty');
  const note = document.createElement('div');
  note.id = 'empty-note';
  note.innerHTML = 'No object loaded.<br>In R: <code>viewer$set_object(g)</code>';
  document.getElementById('spatial-pane').append(note);
  initComms();
  $status('no object');
}

// Handles for tests and debugging from the browser console
window.__giottolens = { state, store, actions, panel: panelHandle };

main().catch(err => {
  $status('error: ' + err.message);
  initComms();   // so the error still reaches R
  reportError(err, 'boot');
});
