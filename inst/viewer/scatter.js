import { state }  from './state.js';
import { PALETTE } from './constants.js';
import { sel, mc } from './mosaic.js';
import { sendToR } from './comms.js';
import { notify }  from './coordination.js';

let scatterDeck   = null;
let scatterPos    = null;   // Float32Array [x0,y0, x1,y1, ...]
let scatterIds    = null;   // String[]
let scatterColors = null;   // Uint8Array [r,g,b,a, ...]
let scatterXCol   = null;
let scatterYCol   = null;

// ── Load data ─────────────────────────────────────────────────────────────────
let _colorCol = null;
let _catMap   = null;  // category string → [r,g,b] for fallback coloring

export async function loadScatterData(xCol, yCol, colorCol) {
  scatterXCol = xCol; scatterYCol = yCol; _colorCol = colorCol;
  const q = colorCol
    ? `SELECT cell_ID, "${xCol}" AS x, "${yCol}" AS y, "${colorCol}" AS c FROM cell_meta`
    : `SELECT cell_ID, "${xCol}" AS x, "${yCol}" AS y FROM cell_meta`;
  const tbl  = await state.polyConn.query(q);
  const rows = tbl.toArray();
  const n    = rows.length;

  scatterPos    = new Float32Array(n * 2);
  scatterColors = new Uint8Array(n * 4);
  scatterIds    = new Array(n);

  // Build category → color fallback (used when state.metaColors not available)
  _catMap = new Map();
  if (colorCol) {
    rows.forEach(r => {
      const v = String(r.c ?? 'NA');
      if (!_catMap.has(v)) _catMap.set(v, PALETTE[_catMap.size % PALETTE.length]);
    });
  }

  rows.forEach((r, i) => {
    scatterPos[i*2]   = r.x;
    scatterPos[i*2+1] = r.y;
    scatterIds[i]     = String(r.cell_ID);
  });

  _applyColors(rows);
}

function _applyColors(rows) {
  // Prefer state.metaColors (matches spatial view exactly) when colorCol aligns
  const useMeta = _colorCol && _colorCol === state.metaCol && state.metaColors;
  (rows ?? scatterIds.map((id, i) => ({ cell_ID: id, c: null }))).forEach((r, i) => {
    const id  = scatterIds[i];
    let col;
    if (useMeta) {
      col = state.metaColors.get(id) ?? [80, 80, 80, 180];
    } else if (_colorCol && _catMap) {
      col = [...(_catMap.get(String(r?.c ?? 'NA')) ?? [160,160,160]), 200];
    } else {
      col = [100, 180, 255, 200];
    }
    scatterColors[i*4]   = col[0]; scatterColors[i*4+1] = col[1];
    scatterColors[i*4+2] = col[2]; scatterColors[i*4+3] = col[3] ?? 200;
  });
}

// Call after buildMetaColors() to keep UMAP colours in sync with spatial view
export function refreshScatterColors() {
  if (!scatterIds) return;
  _applyColors(null);
  renderScatter();
}

// ── Render ────────────────────────────────────────────────────────────────────
function buildLayers() {
  if (!scatterPos) return [];
  const sel = state.selectedCells;
  return [new deck.ScatterplotLayer({
    id: 'umap-points',
    data: { length: scatterIds.length, attributes: {
      getPosition: { value: scatterPos, size: 2 },
      getFillColor: { value: scatterColors, size: 4, normalized: true },
    }},
    getRadius: 1.5, radiusUnits: 'pixels', radiusMinPixels: 1,
    opacity: 0.8,
    updateTriggers: { getFillColor: scatterColors },
  }),
  ...(sel.size > 0 ? [new deck.ScatterplotLayer({
    id: 'umap-selected',
    data: scatterIds.reduce((pts, id, i) => {
      if (sel.has(id)) pts.push([scatterPos[i*2], scatterPos[i*2+1]]);
      return pts;
    }, []),
    getPosition: d => d,
    getFillColor: [255, 220, 50, 220],
    getLineColor: [255, 220, 50, 255],
    stroked: true, getLineWidth: 1, lineWidthUnits: 'pixels',
    getRadius: 2, radiusUnits: 'pixels',
    updateTriggers: { data: state.selVersion },
  })] : [])];
}

export function renderScatter() {
  scatterDeck?.setProps({ layers: buildLayers() });
}

let _homeVS = null;
export function resetScatterView() {
  if (scatterDeck && _homeVS) scatterDeck.setProps({ viewState: { ..._homeVS } });
}

// ── Initialise deck.gl in the panel ──────────────────────────────────────────
export function initScatterDeck(containerId) {
  const container = document.getElementById(containerId);
  if (!container || !scatterPos) return;
  container.innerHTML = '';

  const canvas = document.createElement('canvas');
  canvas.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;';
  container.style.position = 'relative';
  container.appendChild(canvas);

  // Compute initial extent
  let xmin = Infinity, xmax = -Infinity, ymin = Infinity, ymax = -Infinity;
  for (let i = 0; i < scatterIds.length; i++) {
    const x = scatterPos[i*2], y = scatterPos[i*2+1];
    if (x < xmin) xmin = x; if (x > xmax) xmax = x;
    if (y < ymin) ymin = y; if (y > ymax) ymax = y;
  }
  const cx = (xmin+xmax)/2, cy = (ymin+ymax)/2;
  const w  = Math.max(container.clientWidth  || 0, 200);
  const h  = Math.max(container.clientHeight || 0, 200);
  const zoom = Math.log2(Math.min(w / (xmax-xmin), h / (ymax-ymin))) - 0.5;
  const vs = { target: [cx,cy,0], zoom, minZoom: zoom-3, maxZoom: zoom+8 };
  _homeVS = vs;

  scatterDeck = new deck.Deck({
    canvas,
    width: '100%', height: '100%',
    views: new deck.OrthographicView({ id: 'umap', controller: true, flipY: false }),
    initialViewState: vs,
    controller: { doubleClickZoom: false },
    layers: buildLayers(),
    onViewStateChange: ({ viewState }) => scatterDeck.setProps({ viewState }),
  });

  attachUMAPEvents(canvas, vs);
}

// ── Lasso + rect events ───────────────────────────────────────────────────────
function canvasToUMAP(canvas, clientX, clientY, viewState) {
  const rect  = canvas.getBoundingClientRect();
  const scale = Math.pow(2, viewState.zoom);
  const [cx, cy] = viewState.target;
  return [
    cx + (clientX - rect.left - rect.width  / 2) / scale,
    cy - (clientY - rect.top  - rect.height / 2) / scale,
  ];
}

function pointInPoly(ring, x, y) {
  let inside = false;
  for (let i = 0, j = ring.length-1; i < ring.length; j=i++) {
    const [xi,yi]=ring[i], [xj,yj]=ring[j];
    if ((yi>y)!==(yj>y) && x<((xj-xi)*(y-yi))/(yj-yi)+xi) inside=!inside;
  }
  return inside;
}

async function applyUMAPSelection(ring) {
  const newSel = new Set(state.selectedCells);
  for (let i = 0; i < scatterIds.length; i++)
    if (pointInPoly(ring, scatterPos[i*2], scatterPos[i*2+1]))
      newSel.add(scatterIds[i]);
  state.selectedCells = newSel;
  state.selVersion++;
  notify('cellSelection');

  // Bridge to Mosaic histogram via cell_ID IN (...)
  if (newSel.size > 0) {
    const ids = [...newSel].map(id => `'${id}'`).join(',');
    try {
      sel.update({ source: scatterDeck, predicate: `cell_ID IN (${ids})` });
    } catch(e) { console.warn('umap→mosaic bridge:', e); }
  } else {
    try { sel.update({ source: scatterDeck, predicate: null }); } catch(_) {}
  }
}

function attachUMAPEvents(canvas, initialVS) {
  let currentVS    = initialVS;
  let lassoActive  = false;
  let lassoRing    = [];
  let lassoLastPx  = null;
  let lassoDragged = false;
  let umapMode     = 'pan';   // 'pan' | 'lasso'

  // Expose mode toggle so the panel control can switch
  canvas._setMode = m => {
    umapMode = m;
    scatterDeck?.setProps({ controller: m === 'lasso'
      ? { dragPan: false, doubleClickZoom: false }
      : { doubleClickZoom: false } });
  };

  scatterDeck.setProps({ onViewStateChange: ({ viewState }) => {
    currentVS = viewState;
    scatterDeck.setProps({ viewState });
  }});

  canvas.addEventListener('mousedown', e => {
    if (umapMode !== 'lasso') return;
    lassoDragged = false; lassoLastPx = [e.clientX, e.clientY];
    lassoActive = true;
    lassoRing = [canvasToUMAP(canvas, e.clientX, e.clientY, currentVS)];
  });

  canvas.addEventListener('mousemove', e => {
    if (!lassoActive || umapMode !== 'lasso') return;
    const dx = e.clientX-lassoLastPx[0], dy = e.clientY-lassoLastPx[1];
    if (Math.hypot(dx,dy) < 5) return;
    lassoLastPx = [e.clientX, e.clientY]; lassoDragged = true;
    lassoRing.push(canvasToUMAP(canvas, e.clientX, e.clientY, currentVS));
    // Draw lasso overlay
    _drawLasso(canvas, lassoRing, currentVS);
  });

  window.addEventListener('mouseup', async e => {
    if (!lassoActive || umapMode !== 'lasso') return;
    lassoActive = false;
    if (lassoDragged && lassoRing.length >= 3) {
      await applyUMAPSelection([...lassoRing, lassoRing[0]]);
    }
    lassoRing = [];
    _clearLasso(canvas);
  });
}

// Light SVG lasso overlay
function _getOverlay(canvas) {
  let svg = canvas.parentElement.querySelector('.umap-lasso-svg');
  if (!svg) {
    svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.classList.add('umap-lasso-svg');
    svg.style.cssText = 'position:absolute;inset:0;pointer-events:none;';
    canvas.parentElement.appendChild(svg);
  }
  return svg;
}
function _drawLasso(canvas, ring, vs) {
  const svg  = _getOverlay(canvas);
  const rect = canvas.getBoundingClientRect();
  const scale = Math.pow(2, vs.zoom);
  const [cx, cy] = vs.target;
  const toScreen = ([dx, dy]) => [
    rect.width/2  + (dx-cx)*scale,
    rect.height/2 - (dy-cy)*scale,
  ];
  const pts = ring.map(toScreen).map(([x,y]) => `${x},${y}`).join(' ');
  svg.innerHTML = `<polyline points="${pts}" fill="none" stroke="rgba(100,200,255,0.8)" stroke-width="1.5"/>`;
}
function _clearLasso(canvas) {
  canvas.parentElement.querySelector('.umap-lasso-svg')?.remove();
}
