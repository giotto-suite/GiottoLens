// Commands from R (the LensViewer methods, and so the agent API). Each one
// maps onto store actions; nothing here holds state of its own.
import { state } from './state.js';
import { store, actions, getConfig } from './store.ts';
import { onMessage, sendToR } from './comms.js';
import { setViewState } from '../data/schedule.js';
import { fitZoom, viewportSize } from '../ui/dom.js';
import { primeMask, decodeMask } from '../selection/rules.ts';

const LAYERS = ['poly', 'tx', 'annotations'];

// Camera plus the data-space box on screen (xmin, xmax, ymin, ymax)
function viewInfo(vs) {
  const { width, height } = viewportSize();
  const s = Math.pow(2, vs.zoom), [cx, cy] = vs.target;
  return {
    target: [cx, cy], zoom: vs.zoom,
    bounds: [cx - width / 2 / s, cx + width / 2 / s, cy - height / 2 / s, cy + height / 2 / s],
  };
}

export function initRemote() {
  onMessage('get_state', () => ({
    config: { ...getConfig(), annotations: undefined },
    view: state.currentViewState && viewInfo(state.currentViewState),
    n_cells: state.cells?.n ?? 0,
    selected: store.getState().selection.count,
    metadata: state.meta ? [...state.meta.keys()] : [],
  }));

  onMessage('set_rule', ({ source, rule, replace, combine }) => {
    if (combine) actions.setCombine(combine);
    if (rule?.kind === 'ids' && state.cells) primeMask(rule, decodeMask(rule.params.mask, state.cells.n));
    if (replace) actions.setRules(rule ? { [source]: rule } : {});
    else actions.setRule(source, rule ?? null);
    return { selected: store.getState().selection.count };
  });

  onMessage('set_view', ({ target, zoom, bounds }) => {
    let vs = { ...state.currentViewState };
    if (bounds) {
      const [xmin, xmax, ymin, ymax] = bounds;
      vs.target = [(xmin + xmax) / 2, (ymin + ymax) / 2, 0];
      vs.zoom = fitZoom(xmax - xmin, ymax - ymin) - 0.2;
    }
    if (target) vs.target = [target[0], target[1], 0];
    if (zoom != null) vs.zoom = zoom;
    setViewState(vs);
    return viewInfo(vs);
  });

  onMessage('set_color_by', ({ column }) => {
    if (column != null && !state.meta?.has(column)) throw new Error(`no metadata column '${column}'`);
    actions.setColorBy(column ?? null);
  });

  onMessage('set_layer', ({ name, show, alpha }) => {
    if (!LAYERS.includes(name)) throw new Error(`layer must be one of ${LAYERS.join(', ')}`);
    actions.setLayer(name, { ...(show != null && { show }), ...(alpha != null && { alpha }) });
  });

  onMessage('set_genes', ({ genes }) => {
    const idx = (genes ?? []).map(g => state.geneIndex.get(g)).filter(i => i != null);
    actions.clearGenes();
    actions.addGenes(idx);
    return { matched: idx.length };
  });

  onMessage('screenshot', () => {
    state.deckgl.redraw('screenshot');
    return { png: document.getElementById('deck-canvas').toDataURL('image/png') };
  });

  // A short log of what the user did, for R and agents to read back
  const log = (action, detail) => sendToR('log', { action, detail });
  store.subscribe(s => s.rules, (rules, prev) => {
    for (const src of new Set([...Object.keys(rules), ...Object.keys(prev)]))
      if (rules[src] !== prev[src]) log(rules[src] ? 'select' : 'clear', { source: src, kind: rules[src]?.kind ?? null });
  });
  store.subscribe(s => s.colorBy, c => log('color_by', { column: c }));
  store.subscribe(s => s.combine, c => log('combine', { mode: c }));
  store.subscribe(s => s.annotations.length, n => log('annotations', { count: n }));
}
