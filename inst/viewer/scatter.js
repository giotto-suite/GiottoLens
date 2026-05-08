import { state }  from './state.js';
import { PALETTE } from './constants.js';
import { sel, mc } from './mosaic.js';
import { notify, onCoord, recomputeCrossFilter, clearFilters } from './coordination.js';

// ── Factory ───────────────────────────────────────────────────────────────────
// Each call creates an independent scatter panel with its own deck.gl instance,
// data arrays, and coordination handlers.  Returns { destroy, resetView }.

export function createScatterPanel(bodyId, metaCols) {

  // ── Per-instance state ──────────────────────────────────────────────────────
  let _deck    = null;
  let _pos     = null;    // Float32Array [x0,y0, x1,y1, ...]
  let _ids     = null;    // String[]
  let _colors  = null;    // Uint8Array [r,g,b,a, ...]
  let _homeVS  = null;
  let _colorCol = null;
  let _catMap   = null;

  // ── Color helpers ───────────────────────────────────────────────────────────
  function _applyColors(rows) {
    if (!_ids) return;
    const useMeta = _colorCol && _colorCol === state.metaCol && state.metaColors;
    (rows ?? _ids.map((id) => ({ cell_ID: id, c: null }))).forEach((r, i) => {
      const id = _ids[i];
      let col;
      if (useMeta)            col = state.metaColors.get(id) ?? [80, 80, 80, 180];
      else if (_colorCol && _catMap) col = [...(_catMap.get(String(r?.c ?? 'NA')) ?? [160,160,160]), 200];
      else                    col = [100, 180, 255, 200];
      _colors[i*4]   = col[0]; _colors[i*4+1] = col[1];
      _colors[i*4+2] = col[2]; _colors[i*4+3] = col[3] ?? 200;
    });
  }

  // ── Data loading ────────────────────────────────────────────────────────────
  async function _loadData(xCol, yCol, colorCol) {
    _colorCol = colorCol;
    const q = colorCol
      ? `SELECT cell_ID, "${xCol}" AS x, "${yCol}" AS y, "${colorCol}" AS c FROM cell_meta`
      : `SELECT cell_ID, "${xCol}" AS x, "${yCol}" AS y FROM cell_meta`;
    const rows = (await state.polyConn.query(q)).toArray();
    const n    = rows.length;
    _pos    = new Float32Array(n * 2);
    _colors = new Uint8Array(n * 4);
    _ids    = new Array(n);
    _catMap = new Map();
    if (colorCol) rows.forEach(r => {
      const v = String(r.c ?? 'NA');
      if (!_catMap.has(v)) _catMap.set(v, PALETTE[_catMap.size % PALETTE.length]);
    });
    rows.forEach((r, i) => { _pos[i*2] = r.x; _pos[i*2+1] = r.y; _ids[i] = String(r.cell_ID); });
    _applyColors(rows);
  }

  // ── Layer building ──────────────────────────────────────────────────────────
  function _buildLayers() {
    if (!_pos) return [];
    const sel = state.selectedCells;
    return [
      new deck.ScatterplotLayer({
        id: `scatter-points-${bodyId}`,
        data: { length: _ids.length, attributes: {
          getPosition: { value: _pos, size: 2 },
          getFillColor: { value: _colors, size: 4, normalized: true },
        }},
        getRadius: 1.5, radiusUnits: 'pixels', radiusMinPixels: 1, opacity: 0.8,
        updateTriggers: { getFillColor: _colors },
      }),
      ...(sel.size > 0 ? [new deck.ScatterplotLayer({
        id: `scatter-sel-${bodyId}`,
        data: _ids.reduce((pts, id, i) => {
          if (sel.has(id)) pts.push([_pos[i*2], _pos[i*2+1]]);
          return pts;
        }, []),
        getPosition: d => d,
        getFillColor: [255, 220, 50, 220],
        getLineColor: [255, 220, 50, 255],
        stroked: true, getLineWidth: 1, lineWidthUnits: 'pixels',
        getRadius: 2, radiusUnits: 'pixels',
        updateTriggers: { data: state.selVersion },
      })] : []),
    ];
  }

  function _render() { _deck?.setProps({ layers: _buildLayers() }); }

  // ── Deck init ───────────────────────────────────────────────────────────────
  function _initDeck(containerId) {
    const container = document.getElementById(containerId);
    if (!container || !_pos) return;
    container.innerHTML = '';
    container.style.position = 'relative';
    const canvas = document.createElement('canvas');
    canvas.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;';
    container.appendChild(canvas);

    let xmin=Infinity, xmax=-Infinity, ymin=Infinity, ymax=-Infinity;
    for (let i = 0; i < _ids.length; i++) {
      const x = _pos[i*2], y = _pos[i*2+1];
      if (x<xmin) xmin=x; if (x>xmax) xmax=x;
      if (y<ymin) ymin=y; if (y>ymax) ymax=y;
    }
    const cx = (xmin+xmax)/2, cy = (ymin+ymax)/2;
    const w  = Math.max(container.clientWidth  || 0, 200);
    const h  = Math.max(container.clientHeight || 0, 200);
    const zoom = Math.log2(Math.min(w/(xmax-xmin), h/(ymax-ymin))) - 0.5;
    const vs = { target:[cx,cy,0], zoom, minZoom:zoom-3, maxZoom:zoom+8 };
    _homeVS = vs;

    let currentVS = vs;
    _deck = new deck.Deck({
      canvas, width:'100%', height:'100%',
      views: new deck.OrthographicView({ id:`scatter-${bodyId}`, controller:true, flipY:false }),
      initialViewState: vs,
      controller: { doubleClickZoom:false },
      layers: _buildLayers(),
      onViewStateChange: ({ viewState }) => { currentVS = viewState; _deck.setProps({ viewState }); },
    });

    _attachEvents(canvas, () => currentVS);
  }

  // ── Lasso + events ──────────────────────────────────────────────────────────
  function _toData(canvas, clientX, clientY, getVS) {
    const rect  = canvas.getBoundingClientRect();
    const vs    = getVS();
    const scale = Math.pow(2, vs.zoom);
    const [cx, cy] = vs.target;
    return [cx+(clientX-rect.left-rect.width/2)/scale, cy-(clientY-rect.top-rect.height/2)/scale];
  }

  function _pip(ring, x, y) {
    let inside = false;
    for (let i=0, j=ring.length-1; i<ring.length; j=i++) {
      const [xi,yi]=ring[i], [xj,yj]=ring[j];
      if ((yi>y)!==(yj>y) && x<((xj-xi)*(y-yi))/(yj-yi)+xi) inside=!inside;
    }
    return inside;
  }

  function _attachEvents(canvas, getVS) {
    let mode = 'pan', ring = [], lastPx = null, dragged = false, lassoActive = false;

    canvas._setMode = m => {
      mode = m;
      _deck?.setProps({ controller: m==='lasso'
        ? { dragPan:false, doubleClickZoom:false }
        : { doubleClickZoom:false } });
    };

    canvas.addEventListener('mousedown', e => {
      if (mode !== 'lasso') return;
      dragged = false; lastPx = [e.clientX, e.clientY]; lassoActive = true;
      ring = [_toData(canvas, e.clientX, e.clientY, getVS)];
    });

    canvas.addEventListener('mousemove', e => {
      if (!lassoActive || mode !== 'lasso') return;
      const dx = e.clientX-lastPx[0], dy = e.clientY-lastPx[1];
      if (Math.hypot(dx,dy) < 5) return;
      lastPx = [e.clientX, e.clientY]; dragged = true;
      ring.push(_toData(canvas, e.clientX, e.clientY, getVS));
      _drawLasso(canvas, ring, getVS());
    });

    window.addEventListener('mouseup', async () => {
      if (!lassoActive || mode !== 'lasso') return;
      lassoActive = false;
      if (dragged && ring.length >= 3) {
        const closed = [...ring, ring[0]];
        const lassoSet = new Set();
        for (let i=0; i<_ids.length; i++)
          if (_pip(closed, _pos[i*2], _pos[i*2+1])) lassoSet.add(_ids[i]);
        if (state.crossFilter) {
          state.scatterFilter = lassoSet;
          recomputeCrossFilter();
        } else {
          state.selectedCells = new Set([...state.selectedCells, ...lassoSet]);
          state.selVersion++;
          notify('cellSelection');
        }
        try {
          const active = [...state.selectedCells].map(id => `'${id}'`).join(',');
          if (active) sel.update({ source: 'scatter-lasso', predicate: `cell_ID IN (${active})` });
          else        sel.update({ source: 'scatter-lasso', predicate: null });
        } catch(_) {}
      }
      ring = [];
      _clearLasso(canvas);
    });
  }

  function _getOverlay(canvas) {
    let svg = canvas.parentElement.querySelector(`.scatter-lasso-svg-${bodyId}`);
    if (!svg) {
      svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
      svg.classList.add(`scatter-lasso-svg-${bodyId}`);
      svg.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;pointer-events:none;overflow:visible;';
      canvas.parentElement.appendChild(svg);
    }
    return svg;
  }
  function _drawLasso(canvas, ring, vs) {
    const svg = _getOverlay(canvas);
    const rect = canvas.getBoundingClientRect();
    const scale = Math.pow(2, vs.zoom), [cx,cy] = vs.target;
    const pts = ring.map(([dx,dy]) => [
      rect.width/2  + (dx-cx)*scale,
      rect.height/2 - (dy-cy)*scale,
    ]).map(([x,y]) => `${x},${y}`).join(' ');
    svg.innerHTML = `<polyline points="${pts}" fill="none" stroke="rgba(100,200,255,0.8)" stroke-width="1.5"/>`;
  }
  function _clearLasso(canvas) {
    canvas.parentElement.querySelector(`.scatter-lasso-svg-${bodyId}`)?.remove();
  }

  // ── Controls ────────────────────────────────────────────────────────────────
  function _buildControls(cols, xDef, yDef, colorDef) {
    const body = document.getElementById(bodyId);
    if (!body) return {};
    body.querySelector('.stats-controls')?.remove();
    const bar = document.createElement('div');
    bar.className = 'stats-controls';
    const els = {};
    [{ key:'x', label:'x', options:cols },
     { key:'y', label:'y', options:cols },
     { key:'color', label:'color', options:[{value:'',label:'none'},...cols.map(c=>({value:c,label:c}))]}
    ].forEach(({ key, label, options }) => {
      const wrap = document.createElement('label');
      wrap.className = 'stats-ctrl-wrap'; wrap.textContent = label;
      const sel = document.createElement('select');
      sel.className = 'stats-ctrl-sel';
      options.forEach(o => {
        const opt = document.createElement('option');
        opt.value = o.value??o; opt.textContent = o.label??o; sel.appendChild(opt);
      });
      wrap.appendChild(sel); bar.appendChild(wrap); els[key] = sel;
    });
    if (xDef)     els.x.value     = xDef;
    if (yDef)     els.y.value     = yDef;
    if (colorDef) els.color.value = colorDef;

    // Mode + action buttons
    let mode = 'pan';
    const sep = document.createElement('span');
    sep.style.cssText = 'width:1px;height:14px;background:#374151;margin:0 4px;flex-shrink:0;align-self:center;';
    bar.appendChild(sep);
    [['pan','hand'],['lasso','lasso']].forEach(([m, icon]) => {
      const btn = document.createElement('button');
      btn.className = 'tool-btn' + (m==='pan' ? ' active' : ''); btn.title = m;
      const i = document.createElement('i'); i.setAttribute('data-lucide', icon);
      btn.appendChild(i);
      btn.addEventListener('click', () => {
        mode = m;
        bar.querySelectorAll('.tool-btn').forEach(b => b.classList.toggle('active', b===btn));
        document.getElementById(bodyId)?.querySelector('canvas')?._setMode?.(m);
      });
      bar.appendChild(btn);
    });
    const sep2 = sep.cloneNode(); bar.appendChild(sep2);
    [['circle-x','clear', () => {
        clearFilters();
        try {
          sel.update({ source:'scatter-lasso', predicate:null });
          sel.update({ source:'spatial', predicate:null });
        } catch(_) {}
      }],
     ['maximize-2','zoom to fit', () => { if (_deck && _homeVS) _deck.setProps({ viewState:{..._homeVS} }); }]
    ].forEach(([icon, title, fn]) => {
      const btn = document.createElement('button');
      btn.className = 'tool-btn'; btn.title = title;
      const i = document.createElement('i'); i.setAttribute('data-lucide', icon);
      btn.appendChild(i); btn.addEventListener('click', fn); bar.appendChild(btn);
    });
    body.insertBefore(bar, body.firstChild);
    lucide.createIcons({ nodes: bar.querySelectorAll('[data-lucide]') });
    return els;
  }

  // ── Coordination handlers ───────────────────────────────────────────────────
  const _cleanupSel    = onCoord('cellSelection', _render);
  const _cleanupColors = onCoord('metaColors', () => { _applyColors(null); _render(); });

  // ── Public API ──────────────────────────────────────────────────────────────
  // Initialise synchronously (build controls) then load data async
  const cols    = metaCols.map(c => c.name);
  const dims    = cols.filter(c => /umap|tsne|pca/i.test(c));
  const numCols = metaCols.filter(c => c.numeric).map(c => c.name);
  const xDef    = dims.find(c => /1$|_x$/i.test(c)) ?? dims[0] ?? numCols[0] ?? cols[0];
  const yDef    = dims.find(c => /2$|_y$/i.test(c)) ?? dims[1] ?? numCols[1] ?? cols[1];
  const colorDef = cols.find(c => /clus|type|label|class|leiden/i.test(c)) ?? '';

  const ctrls = _buildControls(cols, xDef, yDef, colorDef);

  const area = (() => {
    const body = document.getElementById(bodyId);
    let a = body?.querySelector('.stats-chart-area');
    if (!a && body) { a = document.createElement('div'); a.className = 'stats-chart-area'; body.appendChild(a); }
    return a;
  })();
  if (area) { area.id = area.id || `${bodyId}-deck`; }
  const h3 = document.getElementById(bodyId)?.closest('.stats-pane')?.querySelector('.stats-pane-title');
  if (h3) h3.textContent = 'scatter';

  const _reload = async () => {
    await _loadData(ctrls.x?.value, ctrls.y?.value, ctrls.color?.value || null);
    if (area) _initDeck(area.id);
    area?.querySelector('canvas')?._setMode?.('pan');
  };
  ['x','y','color'].forEach(k => ctrls[k]?.addEventListener('change', _reload));
  _reload(); // fire-and-forget — async init

  return {
    destroy() {
      _cleanupSel(); _cleanupColors();
      _deck?.finalize(); _deck = null;
    },
    resetView() {
      if (_deck && _homeVS) _deck.setProps({ viewState:{..._homeVS} });
    },
  };
}
