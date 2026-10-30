// Tile scheduling: which tiles are in view, eviction, and load order.
// Anything that moves the camera goes through setViewState() so tiles load.
import { state } from '../core/state.js';
import { store } from '../core/store.ts';
import { TRANSCRIPT_ZOOM_THRESHOLD, POLYGON_ZOOM_THRESHOLD, MAX_TRANSCRIPT_TILES } from '../core/constants.js';
import { visibleTiles, loadTile, invalidateTx, txStride } from './tiles.js';
import { requestRender } from '../render/schedule.js';
import { updateScalebar, viewportSize } from '../ui/dom.js';

export function updateTiles(viewState) {
  state.currentViewState = viewState;
  const newTier = Math.min(3, Math.max(0, Math.floor(viewState.zoom - TRANSCRIPT_ZOOM_THRESHOLD)));
  if (newTier !== state.txZoomTier) { state.txZoomTier = newTier; invalidateTx(); }
  const { layers } = store.getState();
  const size      = viewportSize();
  const txLayer   = state.manifest.layers.transcripts;
  const polyLayer = state.manifest.layers.polygons;
  const wantTx    = layers.tx.show && txLayer && viewState.zoom >= TRANSCRIPT_ZOOM_THRESHOLD;
  // Centroids come from the cell table at every zoom; tiles are only for
  // outlines, fetched half a zoom level before they are drawn
  const wantPoly  = layers.poly.show && polyLayer && viewState.zoom >= POLYGON_ZOOM_THRESHOLD - 0.5;
  const polyTiles = wantPoly ? visibleTiles(viewState, polyLayer.tiles, size) : [];
  const txTiles   = wantTx ? visibleTiles(viewState, txLayer.tiles, size) : [];
  const inScope   = new Set([
    ...polyTiles.map(t => `polygons:${t.index}`),
    ...txTiles.map(t => `transcripts:${t.index}`),
  ]);

  for (const key of state.cache.keys()) {
    if (inScope.has(key)) continue;
    state.cache.delete(key);
  }

  for (const key of state.pending)
    if (!inScope.has(key)) state.cancelled.add(key);

  requestRender();

  for (const t of polyTiles)
    loadTile('polygons', t, requestRender);

  if (wantTx) {
    const [cx, cy] = viewState.target;
    const txPending = [...state.pending].filter(k => k.startsWith('transcripts:')).length;
    const stride = txStride();
    txTiles
      .filter(t => !(state.cache.get(`transcripts:${t.index}`)?.stride <= stride) && !state.pending.has(`transcripts:${t.index}`))
      .sort((a, b) =>
        Math.hypot((a.xmin+a.xmax)/2 - cx, (a.ymin+a.ymax)/2 - cy) -
        Math.hypot((b.xmin+b.xmax)/2 - cx, (b.ymin+b.ymax)/2 - cy)
      )
      .slice(0, MAX_TRANSCRIPT_TILES - txPending)
      .forEach(t => loadTile('transcripts', t, vs => { requestRender(); updateTiles(vs); }));
  }
}

// Debounced tile update for continuous camera moves (pan, zoom)
export function scheduleTiles(viewState, delay = 150) {
  clearTimeout(state.tileTimer);
  state.tileTimer = setTimeout(() => updateTiles(viewState), delay);
}

// Jump the camera (fit, zoom-to-annotation) and load what is now in view
export function setViewState(viewState) {
  state.currentViewState = viewState;
  state.deckgl.setProps({ viewState });
  updateScalebar(viewState);
  updateTiles(viewState);
}
