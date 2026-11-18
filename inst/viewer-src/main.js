import { state } from './core/state.js';
import { store, actions } from './core/store.ts';
import { initComms, onMessage, reportError, setHello } from './core/comms.js';
import { initRemote } from './core/remote.js';
import { invalidateTx } from './data/tiles.js';
import { loadCells } from './data/cells.ts';
import { setTransfer } from './data/parquet.ts';
import { setMetaInfo, prefetchColumns } from './data/meta.ts';
import { fieldColumn, fieldExists, needFields, isItemKey, scaleKey, setItemPins } from './data/items.ts';
import { openImage } from './data/images.ts';
import { ImagePool } from './data/img-pool.ts';
import { updateTiles, setViewState, onSetView } from './data/schedule.js';
import { initSelection, recompute } from './selection/selection.ts';
import { onLive } from './selection/live.ts';
import { cellColorBuffer, columnScale } from './render/colors.ts';
import { initRenderScheduler, requestRender } from './render/schedule.js';
import { initAnnotations, generateAnnotId } from './ui/annotations.js';
import { initReleaseGuard } from './ui/release.js';
import { initRuleStrip } from './ui/rules.js';
import { initSelectionBar, initRStatus } from './ui/selbar.js';
import { initJobs } from './ui/jobs.ts';
import { initRegistration } from './ui/registration.ts';
import { showStartPage } from './ui/start.ts';
import { initDock, placeControls, refreshBuiltins, refreshCharts, pushPanel, removePanel, panelHandle,
  showBuiltin } from './panels/dock.ts';
import { initRegions, regionList } from './panels/regions.ts';
import { initAnalysis, analysisModel } from './panels/analysis.js';
import { spatialView } from './spatial/current.ts';
import { saveView } from './spatial/view.ts';
import { applyTheme } from './ui/theme.ts';
import { initPersist, restoredConfig } from './core/persist.ts';
import { prefs, prefIsSet, applyPrefs, onPrefs } from './core/prefs.ts';
import { prefOutline, prefTxPalette, prefSelection } from './core/store.ts';
import { createIcons, icons } from 'lucide';

// Initialise lucide icons for the selection bar's buttons in the HTML.
// ES modules are deferred, so this runs after DOM is parsed.
createIcons({ icons });

const $status = msg => { document.getElementById('status').textContent = msg; };

// ── Cell colours ──────────────────────────────────────────────────────────────
// The colour-by field is a metadata column or an item (data/items.ts);
// expression items share one scale (scaleKey()), which their legend edits
function recolorCells() {
  if (!state.cells) return;
  const s = store.getState();
  const col = s.colorBy;
  const data = col ? fieldColumn(col) : undefined;
  // Keep the current colours while the field loads
  if (col && !data && fieldExists(col)) {
    needFields([col]).then(() => { if (store.getState().colorBy === col) recolorCells(); }, err => {
      if (store.getState().colorBy !== col) return;
      reportError(err, `cannot color by ${col}`);
      actions.setColorBy(null);
    });
    return;
  }
  const scale = col ? scaleKey(col) : null;
  const { colors, fill, legend } = cellColorBuffer(state.cells.n, data ?? null,
    col ? s.categoryStyles[col] : undefined, columnScale(scale, s.colorScales));
  if (legend?.type === 'continuous') legend.column = scale;
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
    showEmpty(state.manifest.project ?? null);
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

  // ── Store subscriptions ───────────────────────────────────────────────────
  initRenderScheduler();
  onLive(requestRender);
  initSelection();
  store.subscribe(s => s.colorBy, recolorCells);
  // The item colouring the cells stays loaded, and goes to the front of the
  // colour-by menu's recent group
  setItemPins(() => [store.getState().colorBy].filter(isItemKey));
  store.subscribe(s => s.colorBy, c => { if (isItemKey(c)) actions.noteItem(c); });
  store.subscribe(s => s.categoryStyles, recolorCells);
  store.subscribe(s => s.colorScales, recolorCells);
  store.subscribe(s => s.layers, () => { invalidateTx(); updateTiles(spatialView()?.viewState); });
  store.subscribe(s => [s.genes, s.txPalette, s.colorAll], invalidateTx,
    { equalityFn: (a, b) => a.every((v, i) => v === b[i]) });
  applyTheme(store.getState().theme);
  store.subscribe(s => s.theme, t => { applyTheme(t); refreshCharts(); });

  initAnnotations();
  initReleaseGuard();
  initRuleStrip();
  initSelectionBar();
  initJobs();
  initRegions(() => showBuiltin('regions'));
  // The spatial view is a panel: the dock builds it (spatial/view.ts), and it
  // fits itself to the data once laid out
  initDock(document.getElementById('dock'));

  // ── R → viewer messages ───────────────────────────────────────────────────
  let metaCount = 0;
  onMessage('load_metadata', ({ columns }) => {
    // A reconnect re-sends the current metadata; keep the panels as they are
    if (!state.cells || !setMetaInfo(columns ?? [])) return;
    metaCount++;
    const colorBy = store.getState().colorBy;
    // A first launch colors by the first column of the color_by preference
    const first = !colorBy && !restoredConfig() && metaCount === 1
      ? prefs().color_by.split(',').map(c => c.trim()).find(c => c && state.metaInfo.has(c)) : null;
    if (first) actions.setColorBy(first);
    else if (colorBy && !isItemKey(colorBy) && !state.metaInfo.has(colorBy)) actions.setColorBy(null);
    else recolorCells();
    // Rules on metadata columns re-evaluate against the new columns
    recompute({ reset: true });
    refreshBuiltins();
    // Whatever the view and panels asked for loads first
    prefetchColumns();
  });

  // Analysis: the panel opens when R starts one (viewer$analysis())
  initAnalysis({ place: () => showBuiltin('analysis') });

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
  // Preferences come before the saved config. A config field still holding
  // the old preference takes the new one.
  onMessage('preferences', applyPrefs);
  onPrefs((next, prev) => {
    const s = store.getState();
    if (JSON.stringify(s.outline) === JSON.stringify(prefOutline(prev))) actions.setOutline(prefOutline(next));
    if (s.txPalette === prefTxPalette(prev)) actions.setTxPalette(prefTxPalette(next));
    if (JSON.stringify(s.selectionColor) === JSON.stringify(prefSelection(prev)))
      actions.setSelectionColor(prefSelection(next));
    // Every spatial view's background (index.html .spatial-pane)
    document.documentElement.style.setProperty('--view-bg', prefIsSet('background') ? next.background : '');
    recolorCells();
  });
  // The saved config comes from R on connect ('restore'), over the defaults
  // set above, images included
  initPersist();
  // A saved camera replaces the fitted one (a view not laid out yet starts
  // from it itself)
  store.persist.onFinishHydration(s => {
    const view = spatialView();
    if (s.view && view?.initialViewState) setViewState({ ...view.initialViewState,
      target: [s.view.target[0], s.view.target[1], 0], zoom: s.view.zoom });
  });
  onSetView(saveView);
  store.persist.rehydrate();
  initComms();   // after every handler is registered

  $status('ready');
}

// No object loaded: the start page, to open a project and one of its
// snapshots (`project`: the project R has open), or wait for R to load one
function showEmpty(project) {
  document.body.classList.add('empty');
  const host = document.createElement('div');
  host.className = 'spatial-pane start-host';
  document.getElementById('main-layout').prepend(host);
  showStartPage(host, project);
  initRStatus();
  initComms();
  $status('no object');
}

// Handles for tests and debugging from the browser console
window.__giottolens = { state, store, actions, panel: panelHandle, regions: regionList,
  analysis: analysisModel, get spatial() { return spatialView(); } };

main().catch(err => {
  $status('error: ' + err.message);
  initComms();   // so the error still reaches R
  reportError(err, 'boot');
});
