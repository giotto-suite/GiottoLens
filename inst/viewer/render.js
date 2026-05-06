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
        getColor: [255, 255, 255, 255],
        getWidth: 1,
        widthUnits: 'pixels',
        widthMinPixels: 1,
        opacity: state.alphaPoly,
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

  state.deckgl.setProps({ layers });
}
