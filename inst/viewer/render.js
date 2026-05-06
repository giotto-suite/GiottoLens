import { state } from './state.js';
import { TRANSCRIPT_ZOOM_THRESHOLD, POLYGON_ZOOM_THRESHOLD } from './constants.js';
import { getCachedTxData, getCachedPolyData } from './data.js';

export function renderLayers(viewState) {
  if (!state.deckgl || !viewState) return;
  const layers         = [];
  const inOverview     = viewState.zoom < TRANSCRIPT_ZOOM_THRESHOLD;
  const polyZoneOk     = viewState.zoom >= POLYGON_ZOOM_THRESHOLD;

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
      layers.push(new deck.PathLayer({
        id: 'poly-outline',
        data: polyData.polys,
        getPath: d => d.polygon[0],
        getColor: d => d.id != null && state.selectedCells.has(d.id) ? [255, 220, 50, 255] : [255, 255, 255, 255],
        getWidth: d => d.id != null && state.selectedCells.has(d.id) ? 2 : 1,
        widthUnits: 'pixels', widthMinPixels: 1,
        opacity: state.alphaPoly,
        updateTriggers: { getColor: state.selVersion, getWidth: state.selVersion },
      }));
    } else if (polyData?.centroids?.length) {
      const pos = polyData.centroids;
      layers.push(new deck.ScatterplotLayer({
        id: 'poly-centroids',
        data: { length: pos.length / 2, attributes: { getPosition: { value: pos, size: 2 } } },
        getRadius: 3, getFillColor: [255, 255, 255, 200],
        radiusUnits: 'pixels', radiusMinPixels: 1,
        opacity: state.alphaPoly,
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
          getRadius: 5, radiusUnits: 'pixels', radiusMinPixels: 2,
          updateTriggers: { data: state.selVersion },
        }));
    }
  }

  // Transcript scatter points
  if (!inOverview && state.showTx && state.alphaTx > 0) {
    const tx = getCachedTxData();
    if (tx) {
      layers.push(new deck.ScatterplotLayer({
        id: 'transcripts',
        data: { length: tx.length,
                attributes: {
                  getPosition: { value: tx.pos,    size: 2 },
                  getFillColor: { value: tx.colors, size: 4, normalized: true },
                }},
        opacity: state.alphaTx,
        getRadius: 2, radiusUnits: 'pixels', radiusMinPixels: 1,
      }));
    }
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

  state.deckgl.setProps({ layers });
}
