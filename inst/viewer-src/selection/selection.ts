// Selection: tools emit rules into the store; this module turns rules into the
// combined mask and reports the selection to R.
import { store, actions } from '../core/store.ts';
import { state } from '../core/state.js';
// @ts-ignore: plain JS module
import { sendToR } from '../core/comms.js';
import { combine, evaluate, primeMask, markSegment, encodeMask, resetMaskCache, type Rule, type Ctx, type CompareOp } from './rules.ts';
import type { Pt, Ring } from './geometry.ts';

export function ctx(): Ctx | null {
  return state.cells ? { cells: state.cells, meta: state.meta } : null;
}

export function recompute({ reset = false } = {}): void {
  if (reset) resetMaskCache();
  const c = ctx();
  const s = store.getState();
  if (!c) { actions.setSelection(null, 0); return; }
  let res: { mask: Uint8Array | null; count: number };
  try {
    res = combine(s.rules, c, s.combine);
  } catch (e) {
    console.warn('GiottoLens: selection', e);
    res = { mask: null, count: 0 };
  }
  state.selPositions = selectedPositions(res.mask);
  actions.setSelection(res.mask, res.count);
}

// Mask of everything except one source (what a crossfilter panel shows)
export function maskExcept(source: string): Uint8Array | null {
  const c = ctx();
  if (!c) return null;
  const s = store.getState();
  return combine(s.rules, c, s.combine, source).mask;
}

function selectedPositions(mask: Uint8Array | null): Float32Array | null {
  if (!mask || !state.cells) return null;
  const { x, y, n } = state.cells;
  let k = 0;
  for (let i = 0; i < n; i++) k += mask[i];
  const out = new Float32Array(k * 2);
  for (let i = 0, j = 0; i < n; i++) if (mask[i]) { out[j++] = x[i]; out[j++] = y[i]; }
  return out;
}

// ── Reporting to R ───────────────────────────────────────────────────────────
let _sendTimer: ReturnType<typeof setTimeout> | undefined;
function scheduleSend(): void {
  if (state.brushDown) return;   // sent on mouse-up
  clearTimeout(_sendTimer);
  _sendTimer = setTimeout(sendSelection, 30);
}
export function sendSelection(): void {
  if (!state.cells) return;
  const s = store.getState();
  sendToR('cell_selection', {
    n: state.cells.n,
    count: s.selection.count,
    mask: encodeMask(s.selection.mask, state.cells.n),
    combine: s.combine,
    rules: Object.values(s.rules),
  });
}

export function initSelection(): void {
  store.subscribe(s => s.rules, () => recompute());
  store.subscribe(s => s.combine, () => recompute());
  store.subscribe(s => s.selection.version, scheduleSend);
}

// ── Tools ────────────────────────────────────────────────────────────────────
// 'or' mode: new strokes add to what is selected. 'and' (crossfilter): a new
// lasso replaces its view's selection, so views narrow each other.

function spatialParts(): Rule[] {
  const r = store.getState().rules.spatial;
  return r?.kind === 'union' ? r.params.parts : r ? [r] : [];
}
function setSpatial(parts: Rule[]): void {
  actions.setRule('spatial', parts.length ? { source: 'spatial', kind: 'union', params: { parts } } : null);
}

export function lassoSpatial(ring: Ring): void {
  const part: Rule = { source: 'spatial', kind: 'polygon', space: 'spatial', params: { rings: [ring] } };
  setSpatial(store.getState().combine === 'and' ? [part] : [...spatialParts(), part]);
}

export function lassoScatter(ring: Ring, x: string, y: string): void {
  const prev = store.getState().rules.scatter;
  const sameSpace = prev?.kind === 'polygon' && typeof prev.space === 'object' && prev.space.x === x && prev.space.y === y;
  const rings = store.getState().combine === 'or' && sameSpace && prev.kind === 'polygon' ? [...prev.params.rings, ring] : [ring];
  actions.setRule('scatter', { source: 'scatter', kind: 'polygon', space: { x, y }, params: { rings } });
}

// Brush: the stroke's mask is built incrementally while dragging and handed
// to the rule cache, so moves cost only the cells near the new segment.
let _brush: { mask: Uint8Array; path: Pt[]; radius: number; base: Rule[] } | null = null;
export function brushStart(p: Pt, radius: number): void {
  if (!state.cells) return;
  _brush = { mask: new Uint8Array(state.cells.n), path: [p], radius, base: spatialParts() };
  markSegment(_brush.mask, state.cells, p, p, radius);
  commitBrush();
}
export function brushMove(p: Pt): void {
  if (!_brush || !state.cells) return;
  const last = _brush.path[_brush.path.length - 1];
  if (Math.hypot(p[0] - last[0], p[1] - last[1]) < _brush.radius / 4) return;
  _brush.path.push(p);
  markSegment(_brush.mask, state.cells, last, p, _brush.radius);
  commitBrush();
}
export function brushEnd(): void {
  if (!_brush) return;
  _brush = null;
  sendSelection();
}
function commitBrush(): void {
  if (!_brush) return;
  const stroke: Rule = { source: 'spatial', kind: 'stroke', space: 'spatial',
    params: { path: _brush.path.slice(), radius: _brush.radius } };
  primeMask(stroke, _brush.mask);
  setSpatial([..._brush.base, stroke]);
}

export function invertSelection(): void {
  const c = ctx();
  const { rules, selection } = store.getState();
  const entries = Object.entries(rules);
  if (!c || !entries.length) return;
  if (entries.length === 1) {
    const [src, r] = entries[0];
    actions.setRule(src, { ...r, negate: !r.negate });
    return;
  }
  // Several sources: freeze the inverse of the combined result
  const inv = new Uint8Array(c.cells.n);
  const m = selection.mask;
  for (let i = 0; i < inv.length; i++) inv[i] = m && m[i] ? 0 : 1;
  const rule: Rule = { source: 'spatial', kind: 'ids', params: { mask: encodeMask(inv, inv.length) } };
  primeMask(rule, inv);
  actions.setRules({ spatial: rule });
}

export function filterMeta(column: string, op: CompareOp, value: string): void {
  const rule: Rule = { source: 'meta', kind: 'compare', space: column, params: { op, value } };
  if (store.getState().combine === 'and') actions.setRule('meta', rule);
  else actions.setRules({ meta: rule });
}

export function setRangeRule(source: string, column: string, range: [number, number] | null): void {
  actions.setRule(source, range ? { source, kind: 'range', space: column, params: { min: range[0], max: range[1] } } : null);
}
export function setCategoryRule(source: string, column: string, values: string[] | null): void {
  actions.setRule(source, values?.length ? { source, kind: 'categories', space: column, params: { values } } : null);
}

export { evaluate };
