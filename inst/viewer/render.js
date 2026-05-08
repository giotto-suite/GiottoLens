import { state } from './state.js';
import { TRANSCRIPT_ZOOM_THRESHOLD, POLYGON_ZOOM_THRESHOLD } from './constants.js';
import { getCachedTxData, getCachedPolyData } from './data.js';
import { notify } from './coordination.js';

export function renderLayers(viewState) {
  if (!state.deckgl || !viewState) return;
  const layers         = [];
  const inOverview     = viewState.zoom < TRANSCRIPT_ZOOM_THRESHOLD;
  const polyZoneOk     = viewState.zoom >= POLYGON_ZOOM_THRESHOLD;

  const selCountEl = document.getElementById('sel-count');
  if (selCountEl) selCountEl.textContent = state.selectedCells.size > 0
    ? `${state.selectedCells.size.toLocaleString()} selected` : '';

  // Overview density bins
  if (inOverview && state.showOverview && state.alphaOverview > 0 && state.overviewBins) {
    const h = state.manifest.layers.transcripts.overview.cell_size / 2;
    const { indices, centers, colors } = state.overviewBins;
    layers.push(new deck.SolidPolygonLayer({
      id: 'overview',
      data: indices,
      getPolygon: i => {
        const cx = centers[i*2], cy = centers[i*2+1];
        return [[cx-h,cy-h],[cx+h,cy-h],[cx+h,cy+h],[cx-h,cy+h]];
      },
      getFillColor: i => [colors[i*4], colors[i*4+1], colors[i*4+2], colors[i*4+3]],
      opacity: state.alphaOverview,
      stroked: false, extruded: false,
      updateTriggers: { getPolygon: state.overviewBins, getFillColor: state.overviewBins },
    }));
  }

  // Centroids always visible once tiles load; outlines replace them above polygon threshold
  if (state.showPoly && state.alphaPoly > 0) {
    const polyData = getCachedPolyData();
    if (polyZoneOk && polyData?.polys?.length) {
      layers.push(new deck.PolygonLayer({
        id: 'poly-outline',
        data: polyData.polys,
        getPolygon: d => d.polygon[0],
        filled: true,
        getFillColor: d => {
          if (d.id != null && state.metaColors) return state.metaColors.get(d.id) ?? [80, 80, 80, 80];
          return [255, 255, 255, 20];
        },
        stroked: true,
        getLineColor: d => d.id != null && state.selectedCells.has(d.id)
          ? [255, 220, 50, 255] : [255, 255, 255, 200],
        getLineWidth: d => d.id != null && state.selectedCells.has(d.id) ? 2 : 1,
        lineWidthUnits: 'pixels', lineWidthMinPixels: 1,
        opacity: state.alphaPoly,
        updateTriggers: {
          getFillColor: state.metaCol,
          getLineColor: state.selVersion,
          getLineWidth: state.selVersion,
        },
      }));
    } else if (polyData?.centroids?.length) {
      layers.push(new deck.ScatterplotLayer({
        id: 'poly-centroids',
        data: { length: polyData.ids.length,
                attributes: { getPosition: { value: polyData.centroids, size: 2 } } },
        getFillColor: (_, { index }) => {
          const id = polyData.ids[index];
          if (id != null && state.selectedCells.has(id)) return [255, 220, 50, 255];
          if (id != null && state.metaColors) return state.metaColors.get(id) ?? [160, 160, 160, 180];
          return [255, 255, 255, 200];
        },
        getRadius: 2, radiusUnits: 'pixels', radiusMinPixels: 1,
        opacity: state.alphaPoly,
        updateTriggers: { getFillColor: [state.selVersion, state.metaCol] },
      }));
    }

    // Selected cell overlay (visible at all zooms, including centroid view)
    if (polyData?.ids && state.selectedCells.size > 0) {
      const selPos = [];
      const cents  = polyData.centroids;
      for (let i = 0; i < polyData.ids.length; i++)
        if (polyData.ids[i] != null && state.selectedCells.has(polyData.ids[i]))
          selPos.push([cents[i*2], cents[i*2+1]]);
      if (selPos.length)
        layers.push(new deck.ScatterplotLayer({
          id: 'selected-cells',
          data: selPos,
          getPosition: d => d,
          getFillColor: [255, 220, 50, 180],
          getLineColor: [255, 220, 50, 255],
          stroked: true, getLineWidth: 1, lineWidthUnits: 'pixels',
          getRadius: 3, radiusUnits: 'pixels', radiusMinPixels: 1,
          updateTriggers: { data: state.selVersion },
        }));
    }
  }

  // Transcript scatter points
  const txSampleEl = document.getElementById('tx-sample');
  if (!inOverview && state.showTx && state.alphaTx > 0) {
    const tx = getCachedTxData();
    const tier = Math.min(3, Math.max(0, state.txZoomTier));
    const label = ['1/16', '1/4', null, null][tier];
    if (txSampleEl) txSampleEl.textContent = label ? `tx ${label}` : '';
    if (tx) {
      layers.push(new deck.ScatterplotLayer({
        id: 'transcripts',
        data: { length: tx.length,
                attributes: {
                  getPosition: { value: tx.pos,    size: 2 },
                  getFillColor: { value: tx.colors, size: 4, normalized: true },
                }},
        opacity: state.alphaTx,
        getRadius: Math.max(0.5, Math.min(1.5, viewState.zoom - TRANSCRIPT_ZOOM_THRESHOLD + 0.5)),
        radiusUnits: 'pixels', radiusMinPixels: 0.5,
      }));
    }
  } else {
    if (txSampleEl) txSampleEl.textContent = '';
  }

  // Persisted annotations
  if (state.showAnnotations && state.alphaAnnotations > 0 && state.annotations.length > 0) {
    layers.push(new deck.PolygonLayer({
      id: 'annotations',
      data: state.annotations,
      getPolygon: d => d.coords,
      filled: true,
      getFillColor: d => d.id === state.selectedAnnotId
        ? [255, 200, 50, 50] : [100, 200, 255, 25],
      stroked: true,
      getLineColor: d => d.id === state.selectedAnnotId
        ? [255, 200, 50, 255] : [100, 200, 255, 220],
      getLineWidth: 2,
      lineWidthUnits: 'pixels', lineWidthMinPixels: 1,
      opacity: state.alphaAnnotations,
      pickable: true,
      onClick: ({ object }) => {
        const newId = object?.id === state.selectedAnnotId ? null : object?.id;
        state.selectedAnnotId = newId;
        notify('annotSelect');
        renderLayers(viewState);
      },
      updateTriggers: {
        getFillColor: state.selectedAnnotId,
        getLineColor: state.selectedAnnotId,
      },
    }));
  }

  // Rectangle preview in progress
  if (state.rectStart && state.rectPreview) {
    const [x0, y0] = state.rectStart, [x1, y1] = state.rectPreview;
    layers.push(new deck.PathLayer({
      id: 'rect-preview',
      data: [[[x0,y0],[x1,y0],[x1,y1],[x0,y1],[x0,y0]]],
      getPath: d => d,
      getColor: [255, 200, 50], getWidth: 2,
      widthUnits: 'pixels', widthMinPixels: 1,
    }));
  }

  // Draw polygon ring in progress
  if (state.drawRing.length >= 1) {
    const preview = state.drawRing.length >= 2
      ? [...state.drawRing, state.drawRing[0]] : state.drawRing;
    layers.push(new deck.PathLayer({
      id: 'draw-ring',
      data: [preview], getPath: d => d,
      getColor: [255, 200, 50], getWidth: 2,
      widthUnits: 'pixels', widthMinPixels: 1,
    }));
    layers.push(new deck.ScatterplotLayer({
      id: 'draw-verts',
      data: state.drawRing, getPosition: d => d,
      getFillColor: [255, 200, 50, 255],
      getRadius: 4, radiusUnits: 'pixels',
    }));
  }

  // Lasso ring in progress
  if (state.lassoRing.length >= 2) {
    layers.push(new deck.PathLayer({
      id: 'lasso-ring',
      data: [[...state.lassoRing, state.lassoRing[0]]], getPath: d => d,
      getColor: [100, 200, 255], getWidth: 2,
      widthUnits: 'pixels', widthMinPixels: 1,
    }));
  }

  // Brush cursor
  if (state.mode === 'brush' && state.brushPos) {
    const r = state.brushRadius / Math.pow(2, viewState.zoom);
    layers.push(new deck.ScatterplotLayer({
      id: 'brush-cursor',
      data: [state.brushPos], getPosition: d => d,
      getFillColor: [100, 200, 255, state.brushDown ? 30 : 10],
      getLineColor: [100, 200, 255, 180],
      stroked: true, filled: true,
      getLineWidth: 1.5, lineWidthUnits: 'pixels',
      getRadius: r,
      updateTriggers: { getFillColor: state.brushDown, getRadius: state.brushRadius },
    }));
  }

  // Ruler
  if (state.rulerStart && state.rulerEnd) {
    layers.push(new deck.PathLayer({
      id: 'ruler-line',
      data: [[state.rulerStart, state.rulerEnd]], getPath: d => d,
      getColor: [255, 255, 100], getWidth: 1.5,
      widthUnits: 'pixels', widthMinPixels: 1,
    }));
    layers.push(new deck.ScatterplotLayer({
      id: 'ruler-points',
      data: [state.rulerStart, state.rulerEnd], getPosition: d => d,
      getFillColor: [255, 255, 100, 255],
      getRadius: 3, radiusUnits: 'pixels',
    }));
  }

  state.deckgl.setProps({ layers });
}
