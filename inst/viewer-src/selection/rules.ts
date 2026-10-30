// Selection rules: what a selection *is*, independent of what is loaded.
// Each source (spatial view, scatter, a histogram, metadata filter, R) holds
// one rule. Rules evaluate to masks over all cells (Uint8Array, 1 = in);
// masks are a cache, rules are what is saved and sent to R.
import { ringTester, segDist2, type Pt, type Ring } from './geometry.ts';
import { tilesInBox, type Cells } from '../data/cells.ts';
import type { Meta, MetaColumn } from '../data/meta.ts';

interface Base { source: string; negate?: boolean }
export type CompareOp = '=' | '!=' | '>' | '<' | 'contains';
export type Rule = Base & (
  | { kind: 'polygon'; space: 'spatial' | { x: string; y: string }; params: { rings: Ring[] } }
  | { kind: 'stroke'; space: 'spatial'; params: { path: Pt[]; radius: number } }
  | { kind: 'range'; space: string; params: { min: number; max: number } }
  | { kind: 'categories'; space: string; params: { values: string[] } }
  | { kind: 'compare'; space: string; params: { op: CompareOp; value: string } }
  | { kind: 'ids'; params: { mask: string } }
  | { kind: 'union'; params: { parts: Rule[] } }
);

export interface Ctx { cells: Cells; meta: Meta | null }

let cache = new WeakMap<object, Uint8Array>();

// Drop cached masks, e.g. when metadata changes under column rules
export function resetMaskCache(): void { cache = new WeakMap(); }

// Mask for a rule. Cached by rule object: rules are never mutated in place.
export function evaluate(rule: Rule, ctx: Ctx): Uint8Array {
  let m = cache.get(rule);
  if (!m) {
    m = evalRaw(rule, ctx);
    if (rule.negate) for (let i = 0; i < m.length; i++) m[i] ^= 1;
    cache.set(rule, m);
  }
  return m;
}

// Seed the cache, e.g. with a brush mask built incrementally while drawing
export function primeMask(rule: Rule, mask: Uint8Array): void { cache.set(rule, mask); }

function evalRaw(rule: Rule, ctx: Ctx): Uint8Array {
  const n = ctx.cells.n;
  const m = new Uint8Array(n);
  switch (rule.kind) {
    case 'polygon': {
      const sp = rule.space;
      for (const ring of rule.params.rings) {
        if (ring.length < 3) continue;
        const T = ringTester(ring);
        if (sp === 'spatial') {
          const { x, y } = ctx.cells;
          for (const t of tilesInBox(ctx.cells, T.xmin, T.xmax, T.ymin, T.ymax))
            for (let i = t.offset, e = t.offset + t.n; i < e; i++)
              if (!m[i] && T.test(x[i], y[i])) m[i] = 1;
        } else {
          const cx = column(ctx, sp.x).values, cy = column(ctx, sp.y).values;
          for (let i = 0; i < n; i++) if (!m[i] && T.test(cx[i], cy[i])) m[i] = 1;
        }
      }
      return m;
    }
    case 'stroke': {
      const { path, radius } = rule.params;
      if (path.length === 1) markSegment(m, ctx.cells, path[0], path[0], radius);
      for (let k = 1; k < path.length; k++) markSegment(m, ctx.cells, path[k - 1], path[k], radius);
      return m;
    }
    case 'range': {
      const col = column(ctx, rule.space);
      const { min, max } = rule.params;
      const v = col.values;
      for (let i = 0; i < n; i++) if (v[i] >= min && v[i] <= max) m[i] = 1;
      return m;
    }
    case 'categories': {
      const col = column(ctx, rule.space);
      const want = new Set(rule.params.values);
      const codes = (col.levels ?? []).map(l => want.has(l) ? 1 : 0);
      const v = col.values;
      for (let i = 0; i < n; i++) if (v[i] >= 0 && codes[v[i]]) m[i] = 1;
      return m;
    }
    case 'compare':
      return compare(column(ctx, rule.space), rule.params.op, rule.params.value, n);
    case 'ids':
      return decodeMask(rule.params.mask, n);
    case 'union': {
      for (const p of rule.params.parts) {
        const pm = evaluate(p, ctx);
        for (let i = 0; i < n; i++) m[i] |= pm[i];
      }
      return m;
    }
  }
}

function column(ctx: Ctx, name: string): MetaColumn {
  const c = ctx.meta?.get(name);
  if (!c) throw new Error(`selection: no metadata column '${name}'`);
  return c;
}

function compare(col: MetaColumn, op: CompareOp, value: string, n: number): Uint8Array {
  const m = new Uint8Array(n);
  const v = col.values;
  if (col.kind === 'categorical') {
    const lv = col.levels ?? [];
    const needle = value.toLowerCase();
    const hit = lv.map(l => {
      if (op === 'contains') return l.toLowerCase().includes(needle);
      if (op === '=') return l === value;
      if (op === '!=') return l !== value;
      const a = Number(l), b = Number(value);
      return op === '>' ? a > b : a < b;
    });
    for (let i = 0; i < n; i++) if (v[i] >= 0 && hit[v[i]]) m[i] = 1;
    return m;
  }
  const b = Number(value);
  if (op === 'contains') {
    for (let i = 0; i < n; i++) if (v[i] === v[i] && String(v[i]).includes(value)) m[i] = 1;
    return m;
  }
  for (let i = 0; i < n; i++) {
    const a = v[i];
    if (a !== a) continue;
    if (op === '=' ? a === b : op === '!=' ? a !== b : op === '>' ? a > b : a < b) m[i] = 1;
  }
  return m;
}

// Mark cells whose centroid is within `r` of segment a–b
export function markSegment(m: Uint8Array, cells: Cells, a: Pt, b: Pt, r: number): number {
  const r2 = r * r;
  let added = 0;
  const { x, y } = cells;
  const xmin = Math.min(a[0], b[0]) - r, xmax = Math.max(a[0], b[0]) + r;
  const ymin = Math.min(a[1], b[1]) - r, ymax = Math.max(a[1], b[1]) + r;
  for (const t of tilesInBox(cells, xmin, xmax, ymin, ymax))
    for (let i = t.offset, e = t.offset + t.n; i < e; i++) {
      if (m[i]) continue;
      const xi = x[i], yi = y[i];
      if (xi < xmin || xi > xmax || yi < ymin || yi > ymax) continue;
      if (segDist2(xi, yi, a, b) <= r2) { m[i] = 1; added++; }
    }
  return added;
}

// ── Combining ─────────────────────────────────────────────────────────────────

// Combine source masks: 'or' unions them, 'and' (crossfilter) intersects.
// `except` leaves one source out, which is what a panel filters itself by.
export function combine(rules: Record<string, Rule>, ctx: Ctx, mode: 'or' | 'and', except?: string): { mask: Uint8Array | null; count: number } {
  const masks = Object.entries(rules).filter(([s]) => s !== except).map(([, r]) => evaluate(r, ctx));
  if (!masks.length) return { mask: null, count: 0 };
  if (masks.length === 1) return { mask: masks[0], count: countMask(masks[0]) };
  const n = ctx.cells.n;
  const out = new Uint8Array(masks[0]);
  for (let k = 1; k < masks.length; k++) {
    const mk = masks[k];
    if (mode === 'and') for (let i = 0; i < n; i++) out[i] &= mk[i];
    else for (let i = 0; i < n; i++) out[i] |= mk[i];
  }
  return { mask: out, count: countMask(out) };
}

export function countMask(m: Uint8Array): number {
  let c = 0;
  for (let i = 0; i < m.length; i++) c += m[i];
  return c;
}

// ── Transport ────────────────────────────────────────────────────────────────
// Bit i of the mask is bit (i & 7), least significant first, of byte i >> 3;
// base64 encoded. N/8 bytes whatever is selected. Matches R's .decode_mask().

export function encodeMask(m: Uint8Array | null, n: number): string {
  const bytes = new Uint8Array(Math.ceil(n / 8));
  if (m) for (let i = 0; i < n; i++) if (m[i]) bytes[i >> 3] |= 1 << (i & 7);
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000)
    s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000) as unknown as number[]);
  return btoa(s);
}

export function decodeMask(b64: string, n: number): Uint8Array {
  const bin = atob(b64);
  const m = new Uint8Array(n);
  for (let i = 0; i < n; i++) m[i] = (bin.charCodeAt(i >> 3) >> (i & 7)) & 1;
  return m;
}
