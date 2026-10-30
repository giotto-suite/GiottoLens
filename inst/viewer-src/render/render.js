// Builds the spatial view's deck.gl layers from the store and runtime state.
// Called once per frame at most, through render/schedule.js.
import { state } from '../core/state.js';
import { store, actions } from '../core/store.ts';
import { TRANSCRIPT_ZOOM_THRESHOLD, POLYGON_ZOOM_THRESHOLD } from '../core/constants.js';
import { txDrawTiles, visibleTiles } from '../data/tiles.js';
import { viewportSize } from '../ui/dom.js';
import { showCellTooltip, hideCellTooltip } from '../ui/tooltip.js';
import { SolidPolygonLayer, ScatterplotLayer, PathLayer, PolygonLayer } from 'deck.gl';

const SEL = [255, 220, 50, 255];

// deck.gl compares `data` by reference: a new object each render means
// re-triangulating every polygon and re-uploading every buffer. Build each
// binary data object once per underlying array.
const _memo = new WeakMap();
function once(key, make) {
  let v = _memo.get(key);
  if (!v) { v = make(); _memo.set(key, v); }
  return v;
}

export function renderLayers(viewState) {
  if (!state.deckgl || !viewState) return;
  const s = store.getState();
  const layers = [];
  const inOverview = viewState.zoom < TRANSCRIPT_ZOOM_THRESHOLD;
  const outlines   = viewState.zoom >= POLYGON_ZOOM_THRESHOLD;
  const sel        = s.selection;

  const selCountEl = document.getElementById('sel-count');
  if (selCountEl) selCountEl.textContent = sel.count > 0 ? `${sel.count.toLocaleString()} selected` : '';

  const onHoverCell = idxOf => info => {
    if (!info.picked || info.index < 0) { hideCellTooltip(); return; }
    showCellTooltip(idxOf(info.index), info.x, info.y);
  };

  if (s.layers.poly.show && s.layers.poly.alpha > 0 && state.cells) {
    const polyLayer = state.manifest.layers.polygons;
    const tiles     = outlines ? visibleTiles(viewState, polyLayer.tiles, viewportSize()) : [];
    const loaded    = tiles.map(t => [t, state.cache.get(`polygons:${t.index}`)]).filter(([, d]) => d);
    const colors    = state.cellColors;
    const mask      = sel.mask;
    const colored   = s.colorBy != null && colors;

    for (const [t, d] of loaded) {
      const off = d.offset;
      const fillData = once(d, () => ({ length: d.length, startIndices: d.startIndices,
        attributes: { getPolygon: { value: d.positions, size: 2 } } }));
      const lineData = once(d.positions, () => ({ length: d.length, startIndices: d.startIndices,
        attributes: { getPath: { value: d.positions, size: 2 } } }));
      layers.push(new SolidPolygonLayer({
        id: `poly-fill-${t.index}`, data: fillData,
        getFillColor: (_, { index }) => {
          if (!colored) return [255, 255, 255, 20];
          const k = (off + index) * 4;
          return [colors[k], colors[k + 1], colors[k + 2], 110];
        },
        opacity: s.layers.poly.alpha, pickable: true,
        onHover: onHoverCell(i => off + i),
        updateTriggers: { getFillColor: [s.metaVersion, s.colorBy] },
      }));
      layers.push(new PathLayer({
        id: `poly-line-${t.index}`, data: lineData,
        getColor: (_, { index }) => mask && mask[off + index] ? SEL : [255, 255, 255, 200],
        getWidth: (_, { index }) => mask && mask[off + index] ? 2 : 1,
        widthUnits: 'pixels', widthMinPixels: 1,
        opacity: s.layers.poly.alpha,
        updateTriggers: { getColor: sel.version, getWidth: sel.version },
      }));
    }

    // Centroids for every cell, from the cell table: the whole sample shows at
    // once. Hidden where outlines are drawn and all their tiles are in.
    if (!outlines || loaded.length < tiles.length) {
      layers.push(new ScatterplotLayer({
        id: 'cell-centroids',
        data: once(colors, () => ({ length: state.cells.n, attributes: {
          getPosition:  { value: state.cellPositions, size: 2 },
          getFillColor: { value: colors, size: 4, normalized: true },
        } })),
        getRadius: 2, radiusUnits: 'pixels', radiusMinPixels: 1,
        opacity: s.layers.poly.alpha, pickable: true,
        onHover: onHoverCell(i => i),
      }));
    }

    if (state.selPositions?.length) {
      layers.push(new ScatterplotLayer({
        id: 'selected-cells',
        data: once(state.selPositions, () => ({ length: state.selPositions.length / 2,
          attributes: { getPosition: { value: state.selPositions, size: 2 } } })),
        getFillColor: [255, 220, 50, 180], getLineColor: SEL,
        stroked: !outlines, getLineWidth: 1, lineWidthUnits: 'pixels',
        getRadius: outlines ? 1.5 : 3, radiusUnits: 'pixels', radiusMinPixels: 1,
      }));
    }
  }

  // Transcript points
  const txSampleEl = document.getElementById('tx-sample');
  if (!inOverview && s.layers.tx.show && s.layers.tx.alpha > 0) {
    const tier = Math.min(3, Math.max(0, state.txZoomTier));
    const label = ['1/16', '1/4', null, null][tier];
    if (txSampleEl) txSampleEl.textContent = label ? `tx ${label}` : '';
    const radius = Math.max(0.5, Math.min(1.5, viewState.zoom - TRANSCRIPT_ZOOM_THRESHOLD + 0.5));
    for (const tx of txDrawTiles()) {
      layers.push(new ScatterplotLayer({
        id: `tx-${tx.key}`,
        data: once(tx.pos, () => ({ length: tx.length, attributes: {
          getPosition:  { value: tx.pos,    size: 2 },
          getFillColor: { value: tx.colors, size: 4, normalized: true },
        } })),
        opacity: s.layers.tx.alpha,
        getRadius: radius, radiusUnits: 'pixels', radiusMinPixels: 0.5,
      }));
    }
  } else if (txSampleEl) {
    txSampleEl.textContent = '';
  }

  // Annotations
  if (s.layers.annotations.show && s.layers.annotations.alpha > 0 && s.annotations.length > 0) {
    const selId = s.selectedAnnotId;
    layers.push(new PolygonLayer({
      id: 'annotations',
      data: s.annotations,
      getPolygon: d => d.coords,
      filled: true,
      getFillColor: d => d.id === selId ? [255, 200, 50, 50] : [100, 200, 255, 25],
      stroked: true,
      getLineColor: d => d.id === selId ? [255, 200, 50, 255] : [100, 200, 255, 220],
      getLineWidth: 2,
      lineWidthUnits: 'pixels', lineWidthMinPixels: 1,
      opacity: s.layers.annotations.alpha,
      pickable: true,
      onClick: ({ object }) => actions.selectAnnotation(object?.id === selId ? null : object?.id ?? null),
      updateTriggers: { getFillColor: selId, getLineColor: selId },
    }));
  }

  // In-progress drawing
  const path = (id, d, color, width = 2) => new PathLayer({
    id, data: [d], getPath: p => p, getColor: color, getWidth: width,
    widthUnits: 'pixels', widthMinPixels: 1,
  });
  if (state.rectStart && state.rectPreview) {
    const [x0, y0] = state.rectStart, [x1, y1] = state.rectPreview;
    layers.push(path('rect-preview', [[x0,y0],[x1,y0],[x1,y1],[x0,y1],[x0,y0]], [255, 200, 50]));
  }
  if (state.drawRing.length >= 1) {
    const preview = state.drawRing.length >= 2 ? [...state.drawRing, state.drawRing[0]] : state.drawRing;
    layers.push(path('draw-ring', preview, [255, 200, 50]));
    layers.push(new ScatterplotLayer({
      id: 'draw-verts', data: state.drawRing, getPosition: d => d,
      getFillColor: [255, 200, 50, 255], getRadius: 4, radiusUnits: 'pixels',
    }));
  }
  if (state.txLassoRing?.length >= 2)
    layers.push(path('tx-lasso-completed', [...state.txLassoRing, state.txLassoRing[0]], [255, 255, 100], 1.5));
  if (state.lassoRing.length >= 2)
    layers.push(path('lasso-ring', [...state.lassoRing, state.lassoRing[0]],
      s.mode === 'txlasso' ? [255, 255, 100] : [100, 200, 255], 1.5));

  if (s.mode === 'brush' && state.brushPos) {
    layers.push(new ScatterplotLayer({
      id: 'brush-cursor',
      data: [state.brushPos], getPosition: d => d,
      getFillColor: [100, 200, 255, state.brushDown ? 30 : 10],
      getLineColor: [100, 200, 255, 180],
      stroked: true, filled: true,
      getLineWidth: 1.5, lineWidthUnits: 'pixels',
      getRadius: s.brushRadius / Math.pow(2, viewState.zoom),
      updateTriggers: { getFillColor: state.brushDown },
    }));
  }

  if (state.rulerStart && state.rulerEnd) {
    layers.push(path('ruler-line', [state.rulerStart, state.rulerEnd], [255, 255, 100], 1.5));
    layers.push(new ScatterplotLayer({
      id: 'ruler-points', data: [state.rulerStart, state.rulerEnd], getPosition: d => d,
      getFillColor: [255, 255, 100, 255], getRadius: 3, radiusUnits: 'pixels',
    }));
  }

  state.deckgl.setProps({ layers });
}
