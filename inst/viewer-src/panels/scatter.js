// Scatter panel over two metadata columns (UMAP, PCA, …): one point per cell,
// drawn from the typed metadata arrays. A lasso emits a 'scatter' rule.
import { state } from '../core/state.js';
import { store } from '../core/store.ts';
import { lassoScatter, strokeOp } from '../selection/selection.ts';
import { cellColorBuffer } from '../render/colors.ts';
import { clientToWorld, worldToClient, fitZoom } from '../ui/dom.js';
import { buildControlBar, chartArea, setTitle } from './controls.js';
import { Deck, OrthographicView, ScatterplotLayer } from 'deck.gl';

export function createScatterPanel(body) {
  const cols     = [...state.meta.values()];
  const numeric  = cols.filter(c => c.kind === 'continuous').map(c => c.name);
  const dims     = numeric.filter(c => /umap|tsne|pca/i.test(c));
  const xDef     = dims.find(c => /1$|_x$/i.test(c)) ?? dims[0] ?? numeric[0];
  const yDef     = dims.find(c => /2$|_y$/i.test(c)) ?? dims[1] ?? numeric[1] ?? xDef;
  const colorDef = '';   // '' follows the spatial view's colour-by column

  let deck = null, pos = null, colors = null, selPos = null, homeVS = null, mode = 'pan';
  let pointData = null, selData = null;   // kept so deck.gl reuses its buffers
  const listeners = new AbortController();
  const unsub = [];

  const ctrls = buildControlBar(body, [
    { key: 'x', label: 'x', options: numeric, value: xDef },
    { key: 'y', label: 'y', options: numeric, value: yDef },
    { key: 'color', label: 'color', value: colorDef,
      options: [{ value: '', label: 'as spatial' }, ...cols.map(c => c.name)] },
  ], [
    { icon: 'hand', title: 'pan', toggle: 'mode', active: true, onClick: () => setMode('pan') },
    { icon: 'lasso', title: 'lasso (Shift adds, Alt or Ctrl/Cmd subtracts)', toggle: 'mode', onClick: () => setMode('lasso') },
    { icon: 'maximize-2', title: 'zoom to fit', onClick: () => homeVS && deck?.setProps({ viewState: { ...homeVS } }) },
  ]);
  const area = chartArea(body);
  setTitle(body, 'scatter');

  function setMode(m) {
    mode = m;
    deck?.setProps({ controller: m === 'lasso' ? { dragPan: false, doubleClickZoom: false } : { doubleClickZoom: false } });
    if (m !== 'lasso') clearLasso();
    body.querySelectorAll('[data-toggle="mode"]').forEach(b => b.classList.toggle('active', b.title === m));
  }

  function recolor() {
    const name = ctrls.color.value;
    colors = name ? cellColorBuffer(state.cells.n, state.meta.get(name) ?? null).colors : state.cellColors;
    pointData = null;
    render();
  }

  function reselect() {
    const mask = store.getState().selection.mask;
    if (!mask || !pos) { selPos = null; render(); return; }
    let k = 0;
    for (let i = 0; i < mask.length; i++) k += mask[i];
    selPos = new Float32Array(k * 2);
    for (let i = 0, j = 0; i < mask.length; i++) if (mask[i]) { selPos[j++] = pos[i * 2]; selPos[j++] = pos[i * 2 + 1]; }
    selData = null;
    render();
  }

  function render() {
    if (!deck || !pos) return;
    pointData ??= { length: pos.length / 2, attributes: {
      getPosition:  { value: pos, size: 2 },
      getFillColor: { value: colors, size: 4, normalized: true },
    } };
    if (selPos?.length) selData ??= { length: selPos.length / 2, attributes: { getPosition: { value: selPos, size: 2 } } };
    const layers = [new ScatterplotLayer({
      id: 'scatter-points', data: pointData,
      getRadius: 1.5, radiusUnits: 'pixels', radiusMinPixels: 1, opacity: 0.8,
    })];
    if (selPos?.length) layers.push(new ScatterplotLayer({
      id: 'scatter-sel', data: selData,
      getFillColor: [255, 220, 50, 220], getRadius: 2, radiusUnits: 'pixels',
    }));
    deck.setProps({ layers });
  }

  function load() {
    const cx = state.meta.get(ctrls.x.value)?.values, cy = state.meta.get(ctrls.y.value)?.values;
    if (!cx || !cy) return;
    const n = state.cells.n;
    pos = new Float32Array(n * 2);
    pointData = null;
    let xmin = Infinity, xmax = -Infinity, ymin = Infinity, ymax = -Infinity;
    for (let i = 0; i < n; i++) {
      const x = cx[i], y = cy[i];
      pos[i * 2] = x; pos[i * 2 + 1] = y;
      if (x === x && y === y) {
        if (x < xmin) xmin = x; if (x > xmax) xmax = x;
        if (y < ymin) ymin = y; if (y > ymax) ymax = y;
      }
    }
    const size = { width: Math.max(area.clientWidth, 200), height: Math.max(area.clientHeight, 200) };
    const zoom = fitZoom(xmax - xmin, ymax - ymin, size) - 0.5;
    homeVS = { target: [(xmin + xmax) / 2, (ymin + ymax) / 2, 0], zoom, minZoom: zoom - 3, maxZoom: zoom + 8 };
    if (!deck) initDeck(); else deck.setProps({ viewState: { ...homeVS } });
    recolor();
    reselect();
  }

  // ── Deck + lasso ──────────────────────────────────────────────────────────
  let canvas = null, svg = null, viewState = null;
  function initDeck() {
    area.replaceChildren();
    area.style.position = 'relative';
    canvas = document.createElement('canvas');
    canvas.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;';
    area.appendChild(canvas);
    viewState = homeVS;
    deck = new Deck({
      canvas, width: '100%', height: '100%',
      views: new OrthographicView({ id: 'scatter', controller: true, flipY: false }),
      initialViewState: homeVS, controller: { doubleClickZoom: false },
      onViewStateChange: ({ viewState: vs }) => { viewState = vs; deck.setProps({ viewState: vs }); },
    });

    let ring = [], lastPx = null, active = false, dragged = false, op = 'replace';
    const opts = { signal: listeners.signal };
    canvas.addEventListener('mousedown', e => {
      if (mode !== 'lasso') return;
      active = true; dragged = false; lastPx = [e.clientX, e.clientY]; op = strokeOp(e);
      ring = [clientToWorld(e.clientX, e.clientY, canvas, viewState)];
    }, opts);
    canvas.addEventListener('mousemove', e => {
      if (!active) return;
      if (Math.hypot(e.clientX - lastPx[0], e.clientY - lastPx[1]) < 5) return;
      lastPx = [e.clientX, e.clientY]; dragged = true;
      ring.push(clientToWorld(e.clientX, e.clientY, canvas, viewState));
      drawLasso(ring);
    }, opts);
    window.addEventListener('mouseup', () => {
      if (!active) return;
      active = false;
      if (dragged && ring.length >= 3) lassoScatter(ring, ctrls.x.value, ctrls.y.value, op);
      ring = [];
      clearLasso();
    }, opts);
    canvas.addEventListener('contextmenu', e => { if (e.ctrlKey && mode === 'lasso') e.preventDefault(); }, opts);
    document.addEventListener('lens:pan', () => setMode('pan'), opts);
  }

  function drawLasso(ring) {
    if (!svg) {
      svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
      svg.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;pointer-events:none;overflow:visible;';
      area.appendChild(svg);
    }
    const rect = canvas.getBoundingClientRect();
    const pts = ring.map(([x, y]) => {
      const [sx, sy] = worldToClient(x, y, canvas, viewState);
      return `${sx - rect.left},${sy - rect.top}`;
    }).join(' ');
    svg.innerHTML = `<polyline points="${pts}" fill="none" stroke="rgba(100,200,255,0.8)" stroke-width="1.5"/>`;
  }
  function clearLasso() { svg?.remove(); svg = null; }

  ['x', 'y'].forEach(k => ctrls[k].addEventListener('change', load, { signal: listeners.signal }));
  ctrls.color.addEventListener('change', recolor, { signal: listeners.signal });
  unsub.push(store.subscribe(s => s.selection.version, reselect));
  unsub.push(store.subscribe(s => s.metaVersion, () => { if (!ctrls.color.value) recolor(); }));
  load();

  return {
    destroy() {
      unsub.forEach(u => u());
      listeners.abort();
      deck?.finalize(); deck = null;
    },
  };
}
