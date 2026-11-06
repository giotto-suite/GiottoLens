// A brush being dragged on a panel (adr/0013). Its rule is set once, on
// release. While it moves, only the cells in buckets along its edges are
// tested, so a frame costs what the brush swept, not a pass over every cell.
// Panel counts and the selected count stay exact (the same inclusive test as
// a range rule); the spatial view filters on the GPU (render.js).
import { state } from '../core/state.js';
import { store } from '../core/store.ts';
import { combine, countMask } from './rules.ts';
import { ctx, selectedPositions } from './selection.ts';
import type { MetaColumn } from '../data/meta.ts';

export type Box = [number, number][];   // [min, max] per column

// ── Bucket index ─────────────────────────────────────────────────────────────
// Cells ordered by bucket over one or two columns: bucket k's cells are
// order[start[k] .. start[k + 1]). Buckets are row-major (y * nb + x), so a
// row of buckets is one contiguous run. NaN cells are left out.

export interface Index { cols: MetaColumn[]; nb: number; lo: number[]; sc: number[]; order: Int32Array; start: Uint32Array }

// Fine buckets keep the cells tested per move few: a move tests the buckets
// between the old and new edges, and outliers stretch every bucket.
export function buildIndex(cols: MetaColumn[], nb = cols.length === 1 ? 16384 : 1024): Index {
  const n = cols[0].values.length, total = cols.length === 1 ? nb : nb * nb;
  const lo = cols.map(c => c.min), sc = cols.map(c => nb / ((c.max - c.min) || 1));
  const top = nb - 1, keys = new Int32Array(n), start = new Uint32Array(total + 1);
  const xv = cols[0].values, yv = cols[1]?.values;
  for (let i = 0; i < n; i++) {
    const a = xv[i];
    let k = a === a ? Math.min(top, ((a - lo[0]) * sc[0]) | 0) : -1;
    if (yv && k >= 0) {
      const b = yv[i];
      k = b === b ? Math.min(top, ((b - lo[1]) * sc[1]) | 0) * nb + k : -1;
    }
    keys[i] = k;
    if (k >= 0) start[k + 1]++;
  }
  for (let k = 0; k < total; k++) start[k + 1] += start[k];
  const order = new Int32Array(start[total]), fill = start.slice(0, total);
  for (let i = 0; i < n; i++) if (keys[i] >= 0) order[fill[keys[i]]++] = i;
  return { cols, nb, lo, sc, order, start };
}

// Buckets a range touches, and those inside it: every bucket but the end
// ones. Exact under rounding: a value and the range's ends go through the
// same expression, which is monotonic.
interface Span { r0: number; r1: number; i0: number; i1: number }
function span(ix: Index, d: number, [a, b]: [number, number]): Span | null {
  const c = ix.cols[d];
  if (!(b >= c.min && a <= c.max && a <= b)) return null;
  const f = (v: number) => Math.max(0, Math.min(ix.nb - 1, Math.floor((v - ix.lo[d]) * ix.sc[d])));
  const r0 = f(a), r1 = f(b);
  return { r0, r1, i0: r0 + 1, i1: r1 - 1 };
}

// ── Counts that follow a moving box ──────────────────────────────────────────

// A panel's bins: `bin(i)` is the bin of cell i (-1: none). Cells count only
// where `gate` is set (null: all). `sel` starts at the panel's counts from
// cells outside the box (e.g. the rest of an OR selection).
export interface Target { bin: (i: number) => number; gate: Uint8Array | null; sel: Uint32Array }

export class LiveCounts {
  box: Box | null = null;
  readonly inBox: Uint8Array;
  constructor(readonly ix: Index, readonly targets: Target[],
              readonly countGate: Uint8Array | null, public count: number) {
    this.inBox = new Uint8Array(ix.cols[0].values.length);
  }

  // Move the box (null: no box); returns the number of cells that changed
  move(box: Box | null): number {
    const ix = this.ix, dims = ix.cols.length, nb = ix.nb;
    const spans = (b: Box | null) => {
      if (!b) return null;
      const s = b.map((r, d) => span(ix, d, r));
      return s.every(Boolean) ? s as Span[] : null;
    };
    const o = spans(this.box), n = spans(box);
    this.box = box;
    if (!o && !n) return 0;
    // A missing second column or box side passes every cell
    const xv = ix.cols[0].values, yv = ix.cols[1]?.values ?? xv;
    const [ax, bx] = box?.[0] ?? [1, 0], [ay, by] = box?.[dims - 1] ?? [1, 0];
    const { order, start } = ix, inBox = this.inBox, T = this.targets, cg = this.countGate;
    let changed = 0;
    const visit = (k0: number, k1: number) => {   // buckets k0..k1, one row
      for (let p = start[k0], e = start[k1 + 1]; p < e; p++) {
        const i = order[p], a = xv[i], b = yv[i];
        const now = a >= ax && a <= bx && b >= ay && b <= by ? 1 : 0;
        if (now === inBox[i]) continue;
        inBox[i] = now;
        const dv = now ? 1 : -1;
        changed++;
        if (!cg || cg[i]) this.count += dv;
        for (let t = 0; t < T.length; t++) {
          const g = T[t].gate;
          if (g && !g[i]) continue;
          const k = T[t].bin(i);
          if (k >= 0) T[t].sel[k] += dv;
        }
      }
    };
    // Rows of buckets either box touches; skip the run inside both boxes
    const sx = 0, sy = dims - 1;
    const y0 = Math.min(o?.[sy].r0 ?? Infinity, n?.[sy].r0 ?? Infinity);
    const y1 = Math.max(o?.[sy].r1 ?? -1, n?.[sy].r1 ?? -1);
    for (let y = dims === 2 ? y0 : 0; y <= (dims === 2 ? y1 : 0); y++) {
      const on = (s: Span[] | null) => !!s && (dims === 1 || (y >= s[sy].r0 && y <= s[sy].r1));
      const inner = (s: Span[] | null) => !!s && (dims === 1 || (y >= s[sy].i0 && y <= s[sy].i1));
      const parts = [o, n].filter(on) as Span[][];
      if (!parts.length) continue;
      const a = Math.min(...parts.map(s => s[sx].r0)), b = Math.max(...parts.map(s => s[sx].r1));
      const row = dims === 2 ? y * nb : 0;
      let s0 = Infinity, s1 = -Infinity;
      if (inner(o) && inner(n)) { s0 = Math.max(o![sx].i0, n![sx].i0); s1 = Math.min(o![sx].i1, n![sx].i1); }
      if (s0 > s1) visit(row + a, row + b);
      else {
        if (a < s0) visit(row + a, row + s0 - 1);
        if (s1 < b) visit(row + s1 + 1, row + b);
      }
    }
    return changed;
  }
}

// ── Sessions ─────────────────────────────────────────────────────────────────

// A panel that shows counts while another panel's brush moves
export interface LiveConsumer {
  source: () => string | null;          // its own rule's source
  bins: () => { bins: number; bin: (i: number) => number } | null;   // null: not drawn
  show: (sel: Uint32Array) => void;
}
const consumers = new Set<LiveConsumer>();
export function addLiveConsumer(c: LiveConsumer): () => void {
  consumers.add(c);
  return () => consumers.delete(c);
}

const listeners = new Set<() => void>();
export function onLive(fn: () => void): void { listeners.add(fn); }

interface Session {
  source: string; counts: LiveCounts; shown: [LiveConsumer, Target][];
  base: Float32Array | null;    // positions of cells selected by other rules (OR)
}
let session: Session | null = null;

// One index per column set, kept while its columns are loaded
let indexes: Index[] = [];
function indexFor(cols: MetaColumn[]): Index {
  let ix = indexes.find(x => x.cols.length === cols.length && x.cols.every((c, d) => c === cols[d]));
  if (!ix) {
    ix = buildIndex(cols);
    indexes = [ix, ...indexes.filter(x => x.cols.every(c => state.meta?.get(c.name) === c))].slice(0, 3);
  }
  return ix;
}

// Build the index ahead of a drag, e.g. when the pointer enters the panel
export function prepareLive(cols: MetaColumn[]): void {
  const go = () => { if (state.cells) { indexFor(cols); filterValues(cols); } };
  'requestIdleCallback' in window ? requestIdleCallback(go, { timeout: 200 }) : setTimeout(go, 0);
}

const not = (m: Uint8Array) => { const out = new Uint8Array(m.length); for (let i = 0; i < m.length; i++) out[i] = m[i] ^ 1; return out; };

// Start a drag of `source`'s box over `cols`. In OR mode every panel shows the
// other rules' cells plus the box's; in cross-filter mode each panel shows
// the box within the rules other than its own (its own panel is unchanged).
export function beginLive(source: string, cols: MetaColumn[]): void {
  const c = ctx();
  if (!c) return;
  const s = store.getState(), ix = indexFor(cols);
  const shown: [LiveConsumer, Target][] = [];
  let counts: LiveCounts, base: Float32Array | null = null;
  if (s.combine === 'or') {
    const others = combine(s.rules, c, 'or', source).mask;
    const gate = others && not(others);
    for (const k of consumers) {
      const b = k.bins();
      if (!b) continue;
      const sel = new Uint32Array(b.bins);
      if (others) for (let i = 0; i < others.length; i++) if (others[i]) { const j = b.bin(i); if (j >= 0) sel[j]++; }
      shown.push([k, { bin: b.bin, gate, sel }]);
    }
    counts = new LiveCounts(ix, shown.map(x => x[1]), gate, others ? countMask(others) : 0);
    base = selectedPositions(others);
  } else {
    for (const k of consumers) {
      const own = k.source(), b = k.bins();
      if (own === source || !b) continue;
      const gate = combine(s.rules, c, 'and', [source, ...(own ? [own] : [])]).mask;
      shown.push([k, { bin: b.bin, gate, sel: new Uint32Array(b.bins) }]);
    }
    counts = new LiveCounts(ix, shown.map(x => x[1]), combine(s.rules, c, 'and', source).mask, 0);
  }
  session = { source, counts, shown, base };
}

export function moveLive(box: Box | null): void {
  if (!session) return;
  session.counts.move(box);
  for (const [k, t] of session.shown) k.show(t.sel);
  listeners.forEach(f => f());
}

// The drag is over; the caller sets the rule, which recomputes the selection
export function endLive(): void {
  session = null;
  listeners.forEach(f => f());
}

export const liveSource = (): string | null => session?.source ?? null;

// What the spatial view draws during a drag: the cells in the box (filtered
// on the GPU by `values`), where `gate` is set, over the `base` cells
export function liveView(): { values: Float32Array; dims: number; box: Box | null; gate: Float32Array | null;
                               base: Float32Array | null; count: number } | null {
  if (!session) return null;
  const { counts } = session;
  return { values: filterValues(counts.ix.cols), dims: counts.ix.cols.length, box: counts.box,
    gate: gateValues(counts.countGate), base: session.base, count: counts.count };
}

// Columns as one interleaved float32 attribute, built once per column set
let fv: { cols: MetaColumn[]; values: Float32Array } | null = null;
function filterValues(cols: MetaColumn[]): Float32Array {
  if (fv && fv.cols.length === cols.length && fv.cols.every((c, d) => c === cols[d])) return fv.values;
  const n = cols[0].values.length, dims = cols.length, values = new Float32Array(n * dims);
  for (let d = 0; d < dims; d++) {
    const v = cols[d].values;
    for (let i = 0; i < n; i++) values[i * dims + d] = v[i];
  }
  fv = { cols, values };
  return values;
}
let gv: { mask: Uint8Array; values: Float32Array } | null = null;
function gateValues(mask: Uint8Array | null): Float32Array | null {
  if (!mask) return null;
  if (gv?.mask !== mask) gv = { mask, values: Float32Array.from(mask) };
  return gv.values;
}
