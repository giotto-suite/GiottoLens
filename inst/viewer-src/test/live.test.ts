import { describe, it, expect } from 'vitest';
import { buildIndex, LiveCounts, type Box, type Target } from '../selection/live.ts';
import type { MetaColumn } from '../data/meta.ts';

function rng(seed: number) {
  let s = seed;
  return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296);
}
function col(name: string, v: Float64Array): MetaColumn {
  let min = Infinity, max = -Infinity;
  for (const x of v) if (x === x) { if (x < min) min = x; if (x > max) max = x; }
  return { name, kind: 'continuous', values: v, min, max };
}

// Clustered values with NaNs and ties, so boxes cut through dense buckets
function data(n: number, seed: number) {
  const r = rng(seed);
  const x = new Float64Array(n), y = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    x[i] = i % 97 === 0 ? NaN : Math.round((r() + r()) * 500) / 100;
    y[i] = i % 89 === 0 ? NaN : (r() * r()) * 10 - 2;
  }
  return { x: col('x', x), y: col('y', y) };
}

// Counts the slow way: every cell in the box (and its gate), by bin
function brute(cols: MetaColumn[], box: Box | null, t: Target, base: Uint32Array, bins: number) {
  const sel = base.slice();
  const n = cols[0].values.length;
  if (box) for (let i = 0; i < n; i++) {
    if (!cols.every((c, d) => c.values[i] >= box[d][0] && c.values[i] <= box[d][1])) continue;
    if (t.gate && !t.gate[i]) continue;
    const k = t.bin(i);
    if (k >= 0 && k < bins) sel[k]++;
  }
  return sel;
}

describe('live brush counts', () => {
  const n = 20000;
  const { x, y } = data(n, 7);
  const bin = (i: number) => { const v = x.values[i]; return v === v ? Math.min(15, Math.floor((v - x.min) / (x.max - x.min) * 16)) : -1; };

  it('orders every non-NaN cell by bucket', () => {
    const ix = buildIndex([x, y], 16);
    const expected = [...Array(n).keys()].filter(i => x.values[i] === x.values[i] && y.values[i] === y.values[i]).length;
    expect(ix.order.length).toBe(expected);
    expect(ix.start[16 * 16]).toBe(expected);
    expect(new Set(ix.order).size).toBe(expected);
  });

  for (const dims of [1, 2]) it(`match a full recount after every move (${dims}D), with and without a gate`, () => {
    const cols = dims === 1 ? [x] : [x, y];
    const r = rng(dims);
    const gate = Uint8Array.from({ length: n }, (_, i) => (i % 3 ? 1 : 0));
    const base = new Uint32Array(16).fill(5);
    const targets: Target[] = [
      { bin, gate: null, sel: new Uint32Array(16) },
      { bin, gate, sel: base.slice() },
    ];
    const lc = new LiveCounts(buildIndex(cols, dims === 1 ? 64 : 16), targets, gate, 3);
    const rand = (c: MetaColumn) => c.min + (r() * 1.4 - 0.2) * (c.max - c.min);
    let box: Box | null = null;
    for (let step = 0; step < 60; step++) {
      // Small drags, jumps, resizes, empty and inverted boxes, and no box
      const kind = step % 10;
      if (kind === 9) box = null;
      else if (kind === 8 || !box) box = cols.map(c => { const a = rand(c), b = rand(c); return [Math.min(a, b), Math.max(a, b)]; });
      else if (kind === 7) box = cols.map(c => [c.max + 1, c.max + 2]);
      else box = box.map(([a, b], d) => { const s = (r() - 0.5) * 0.1 * (cols[d].max - cols[d].min); return [a + s, b + (kind % 2 ? s : 2 * s)]; });
      lc.move(box);
      expect([...targets[0].sel]).toEqual([...brute(cols, box, { ...targets[0], sel: new Uint32Array(16) }, new Uint32Array(16), 16)]);
      expect([...targets[1].sel]).toEqual([...brute(cols, box, { ...targets[1] }, base, 16)]);
      let count = 3;
      if (box) for (let i = 0; i < n; i++)
        if (gate[i] && cols.every((c, d) => c.values[i] >= box![d][0] && c.values[i] <= box![d][1])) count++;
      expect(lc.count).toBe(count);
    }
  });

  it('tests only the cells near the edges when a box moves a little', () => {
    const lc = new LiveCounts(buildIndex([x, y]), [], null, 0);
    lc.move([[2, 8], [-1, 5]]);
    // Visiting is what costs; count the cells tested through the index
    let tested = 0;
    const ix = lc.ix, orig = ix.order;
    const spy = new Proxy(orig, { get(t, p) { if (typeof p === 'string' && /^\d+$/.test(p)) tested++; return Reflect.get(t, p); } });
    (lc as any).ix = { ...ix, order: spy };
    lc.move([[2.01, 8.01], [-1, 5]]);
    expect(tested).toBeLessThan(n * 0.15);
    expect(tested).toBeGreaterThan(0);
  });
});

describe('live brush sessions', () => {
  it('show what each panel shows once the rule is set, in OR and cross-filter mode', async () => {
    const { state } = await import('../core/state.js');
    const { store, actions } = await import('../core/store.ts');
    const { combine } = await import('../selection/rules.ts');
    const { addLiveConsumer, beginLive, moveLive, endLive, liveView } = await import('../selection/live.ts');
    const n = 5000, r = rng(3);
    const v = () => Float64Array.from({ length: n }, () => Math.round(r() * 1000) / 100);
    const a = col('a', v()), b = col('b', v()), c = col('c', v());
    state.cells = { n, x: new Float32Array(n), y: new Float32Array(n), tiles: [], url: '' };
    state.meta = new Map([['a', a], ['b', b], ['c', c]]);
    const range = (source: string, space: string, min: number, max: number) =>
      ({ source, kind: 'range' as const, space, params: { min, max } });
    const binOf = (m: MetaColumn, k: number) => (i: number) => Math.min(k - 1, Math.floor((m.values[i] - m.min) / (m.max - m.min) * k));
    const panels = [
      { source: 'hist:c', bins: 8, bin: binOf(c, 8) },
      { source: 'density', bins: 16, bin: (i: number) => binOf(b, 4)(i) * 4 + binOf(a, 4)(i) },
      { source: 'hist:a', bins: 5, bin: binOf(a, 5) },
    ];
    const shown = new Map<string, Uint32Array>();
    const off = panels.map(p => addLiveConsumer({ source: () => p.source, bins: () => p,
      show: sel => shown.set(p.source, sel.slice()) }));
    const box: Box = [[2, 7.5], [1, 6]];
    const boxRule = { source: 'density', kind: 'intersect' as const, params: { parts: [
      range('density', 'a', ...box[0]), range('density', 'b', ...box[1])] } };
    for (const mode of ['or', 'and'] as const) {
      actions.setCombine(mode);
      actions.setRules({ 'hist:c': range('hist:c', 'c', 1, 6), other: range('other', 'b', 0, 3) });
      shown.clear();
      beginLive('density', [a, b]);
      moveLive([[0, 1], [0, 1]]);
      moveLive([[1.5, 7], [2, 6.5]]);
      moveLive(box);
      const rules = { ...store.getState().rules, density: boxRule };
      const ctx = { cells: state.cells, meta: state.meta };
      expect(liveView()!.count).toBe(combine(rules, ctx, mode).count);
      for (const p of panels) {
        if (mode === 'and' && p.source === 'density') { expect(shown.has('density')).toBe(false); continue; }
        const fg = mode === 'or' ? combine(rules, ctx, 'or').mask : combine(rules, ctx, 'and', p.source).mask;
        const want = new Uint32Array(p.bins);
        if (fg) for (let i = 0; i < n; i++) if (fg[i]) want[p.bin(i)]++;
        expect([...shown.get(p.source)!]).toEqual([...want]);
      }
      endLive();
      expect(liveView()).toBeNull();
    }
    off.forEach(f => f());
  });
});
