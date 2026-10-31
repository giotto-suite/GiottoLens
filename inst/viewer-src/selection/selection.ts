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
// Every tool, in both combine modes: a plain stroke replaces its view's rule,
// Shift adds to it and Alt (Option) or Ctrl/Cmd subtracts from it. The view's
// rule becomes the stroke, union(rule, stroke) or intersect(rule, not stroke).
// The × on a rule chip drops one view's rule.

export type StrokeOp = 'replace' | 'add' | 'subtract';
export function strokeOp(e: { shiftKey?: boolean; altKey?: boolean; ctrlKey?: boolean; metaKey?: boolean }): StrokeOp {
  if (e.altKey || e.ctrlKey || e.metaKey) return 'subtract';
  return e.shiftKey ? 'add' : 'replace';
}

// The view's rule after a stroke. Subtracting from a view with no rule leaves
// it without one. Unions and intersections are extended, not nested.
export function strokeRule(prev: Rule | undefined, part: Rule, op: StrokeOp, source: string): Rule | null {
  if (op === 'replace') return part;
  if (!prev) return op === 'add' ? part : null;
  if (op === 'add') {
    const parts = prev.kind === 'union' && !prev.negate ? [...prev.params.parts, part] : [prev, part];
    return { source, kind: 'union', params: { parts } };
  }
  const parts = prev.kind === 'intersect' && !prev.negate ? [...prev.params.parts, part] : [prev, part];
  return { source, kind: 'intersect', params: { parts } };
}

// Subtracted strokes are negated parts of an intersection
const asPart = (part: Rule, op: StrokeOp): Rule => op === 'subtract' ? { ...part, negate: !part.negate } : part;

export function lassoSpatial(ring: Ring, op: StrokeOp = 'replace'): void {
  const part: Rule = { source: 'spatial', kind: 'polygon', space: 'spatial', params: { rings: [ring] } };
  actions.setRule('spatial', strokeRule(store.getState().rules.spatial, asPart(part, op), op, 'spatial'));
}

export function lassoScatter(ring: Ring, x: string, y: string, op: StrokeOp = 'replace'): void {
  const part: Rule = { source: 'scatter', kind: 'polygon', space: { x, y }, params: { rings: [ring] } };
  actions.setRule('scatter', strokeRule(store.getState().rules.scatter, asPart(part, op), op, 'scatter'));
}

// Brush: the stroke's mask is built incrementally while dragging and handed
// to the rule cache, so moves cost only the cells near the new segment (and,
// when subtracting, one pass to invert it).
let _brush: { mask: Uint8Array; path: Pt[]; radius: number; base: Rule | undefined; op: StrokeOp } | null = null;
export function brushStart(p: Pt, radius: number, op: StrokeOp = 'replace'): void {
  if (!state.cells) return;
  _brush = { mask: new Uint8Array(state.cells.n), path: [p], radius, base: store.getState().rules.spatial, op };
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
  const { mask, op } = _brush;
  const stroke = asPart({ source: 'spatial', kind: 'stroke', space: 'spatial',
    params: { path: _brush.path.slice(), radius: _brush.radius } }, op);
  if (op === 'subtract') {
    const inv = new Uint8Array(mask.length);
    for (let i = 0; i < mask.length; i++) inv[i] = mask[i] ^ 1;
    primeMask(stroke, inv);
  } else {
    primeMask(stroke, mask);
  }
  actions.setRule('spatial', strokeRule(_brush.base, stroke, op, 'spatial'));
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
