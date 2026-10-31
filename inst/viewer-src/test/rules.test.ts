import { describe, it, expect } from 'vitest';
import { ringTester, type Ring } from '../selection/geometry.ts';
import { evaluate, combine, encodeMask, decodeMask, markSegment, countMask, type Rule } from '../selection/rules.ts';
import type { Cells } from '../data/cells.ts';
import type { Meta } from '../data/meta.ts';

function naivePip(ring: Ring, x: number, y: number) {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [xi, yi] = ring[i], [xj, yj] = ring[j];
    if ((yi > y) !== (yj > y) && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

// 10 x 10 grid of cells at (i + 0.5, j + 0.5), two tiles split at x = 5
function grid(): Cells {
  const n = 100, x = new Float32Array(n), y = new Float32Array(n);
  let k = 0;
  for (const half of [0, 1]) for (let i = 0; i < 5; i++) for (let j = 0; j < 10; j++) {
    x[k] = half * 5 + i + 0.5; y[k] = j + 0.5; k++;
  }
  return { n, x, y, url: '', tiles: [
    { index: 1, offset: 0, n: 50, bounds: [0.5, 4.5, 0.5, 9.5] },
    { index: 2, offset: 50, n: 50, bounds: [5.5, 9.5, 0.5, 9.5] },
  ] };
}
function meta(cells: Cells): Meta {
  const score = new Float64Array(cells.n), lab = new Int32Array(cells.n);
  for (let i = 0; i < cells.n; i++) { score[i] = cells.x[i]; lab[i] = i % 3 === 0 ? -1 : i % 2; }
  return new Map([
    ['score', { name: 'score', kind: 'continuous', values: score, min: 0.5, max: 9.5 }],
    ['lab', { name: 'lab', kind: 'categorical', levels: ['a', 'b'], values: lab, min: 0, max: 0 }],
  ]);
}

describe('ringTester', () => {
  it('agrees with the plain even-odd test on a concave ring', () => {
    const ring: Ring = Array.from({ length: 50 }, (_, k) => {
      const a = (k / 50) * 2 * Math.PI, r = 5 + 2 * Math.sin(5 * a);
      return [10 + r * Math.cos(a), 10 + r * Math.sin(a)];
    });
    const T = ringTester(ring, 16);
    for (let i = 0; i < 2000; i++) {
      const x = Math.random() * 20, y = Math.random() * 20;
      expect(T.test(x, y)).toBe(naivePip(ring, x, y));
    }
  });
});

describe('rules', () => {
  const cells = grid();
  const ctx = { cells, meta: meta(cells) };
  const sq: Ring = [[0, 0], [3, 0], [3, 3], [0, 3]];

  it('polygon over centroids, across tiles, and negated', () => {
    const r: Rule = { source: 's', kind: 'polygon', space: 'spatial', params: { rings: [sq] } };
    expect(countMask(evaluate(r, ctx))).toBe(9);
    const wide: Rule = { source: 's', kind: 'polygon', space: 'spatial', params: { rings: [[[4, 0], [7, 0], [7, 1], [4, 1]]] } };
    expect(countMask(evaluate(wide, ctx))).toBe(3);   // x = 4.5 | 5.5 | 6.5
    expect(countMask(evaluate({ ...r, negate: true }, ctx))).toBe(91);
  });

  it('polygon in a scatter space uses the metadata columns', () => {
    const r: Rule = { source: 'sc', kind: 'polygon', space: { x: 'score', y: 'score' }, params: { rings: [[[0, 0], [2, 0], [2, 2], [0, 2]]] } };
    expect(countMask(evaluate(r, ctx))).toBe(20);     // score 0.5 and 1.5
  });

  it('stroke marks cells within the radius of the path', () => {
    const r: Rule = { source: 's', kind: 'stroke', space: 'spatial', params: { path: [[0.5, 0.5], [9.5, 0.5]], radius: 0.1 } };
    expect(countMask(evaluate(r, ctx))).toBe(10);
    const m = new Uint8Array(cells.n);
    expect(markSegment(m, cells, [0.5, 0.5], [0.5, 0.5], 1.01)).toBe(3);
  });

  it('range, categories and compare', () => {
    expect(countMask(evaluate({ source: 'h', kind: 'range', space: 'score', params: { min: 2, max: 4 } }, ctx))).toBe(20);
    const cats = evaluate({ source: 'h', kind: 'categories', space: 'lab', params: { values: ['b'] } }, ctx);
    for (let i = 0; i < cells.n; i++) expect(cats[i]).toBe(i % 3 !== 0 && i % 2 === 1 ? 1 : 0);
    expect(countMask(evaluate({ source: 'm', kind: 'compare', space: 'score', params: { op: '>', value: '8' } }, ctx))).toBe(20);
    expect(countMask(evaluate({ source: 'm', kind: 'compare', space: 'lab', params: { op: 'contains', value: 'A' } }, ctx)))
      .toBe(evaluate({ source: 'h', kind: 'categories', space: 'lab', params: { values: ['a'] } }, ctx).reduce((s, v) => s + v, 0));
  });

  it('union, and/or combine, and leaving a source out', () => {
    const a: Rule = { source: 'spatial', kind: 'range', space: 'score', params: { min: 0, max: 5 } };
    const b: Rule = { source: 'hist', kind: 'range', space: 'score', params: { min: 3, max: 10 } };
    expect(combine({ spatial: a, hist: b }, ctx, 'and').count).toBe(20);
    expect(combine({ spatial: a, hist: b }, ctx, 'or').count).toBe(100);
    expect(combine({ spatial: a, hist: b }, ctx, 'and', 'hist').count).toBe(50);
    expect(combine({}, ctx, 'and').mask).toBeNull();
    const u: Rule = { source: 'spatial', kind: 'union', params: { parts: [a, b] } };
    expect(countMask(evaluate(u, ctx))).toBe(100);
  });

  it('masks round-trip through base64, matching R bit order', () => {
    const m = new Uint8Array(13); m[0] = 1; m[9] = 1; m[12] = 1;
    const b64 = encodeMask(m, 13);
    expect(b64).toBe(btoa(String.fromCharCode(0b00000001, 0b00010010)));
    expect([...decodeMask(b64, 13)]).toEqual([...m]);
    const ids: Rule = { source: 'r', kind: 'ids', params: { mask: encodeMask(m, 100) } };
    expect(countMask(evaluate(ids, ctx))).toBe(3);
  });
});

describe('stroke modifiers', async () => {
  const { strokeOp, strokeRule, lassoSpatial, lassoScatter, brushStart, brushMove, brushEnd } = await import('../selection/selection.ts');
  const { store, actions } = await import('../core/store.ts');
  const { state } = await import('../core/state.js');
  const cells = grid();
  const ctx = { cells, meta: meta(cells) };
  const box = (x0: number, x1: number, y0: number, y1: number): Ring => [[x0, y0], [x1, y0], [x1, y1], [x0, y1]];
  const n = (r: Rule | undefined) => r ? countMask(evaluate(r, ctx)) : 0;

  it('Shift adds, Alt or Ctrl/Cmd subtracts, plain replaces', () => {
    expect(strokeOp({})).toBe('replace');
    expect(strokeOp({ shiftKey: true })).toBe('add');
    for (const k of ['altKey', 'ctrlKey', 'metaKey']) expect(strokeOp({ [k]: true })).toBe('subtract');
    const a: Rule = { source: 's', kind: 'range', space: 'score', params: { min: 0, max: 5 } };
    expect(strokeRule(undefined, a, 'subtract', 's')).toBeNull();
    expect(strokeRule(undefined, a, 'add', 's')).toBe(a);
  });

  for (const combine of ['or', 'and'] as const) {
    it(`spatial lasso replaces, adds and subtracts the same way in '${combine}' mode`, () => {
      actions.clearSelection(); actions.setCombine(combine);
      lassoSpatial(box(0, 4, 0, 10));                        // 40 cells
      expect(n(store.getState().rules.spatial)).toBe(40);
      lassoSpatial(box(0, 2, 0, 10));                        // replaces
      expect(n(store.getState().rules.spatial)).toBe(20);
      lassoSpatial(box(6, 8, 0, 10), 'add');                 // + 20
      expect(n(store.getState().rules.spatial)).toBe(40);
      lassoSpatial(box(0, 10, 0, 5), 'subtract');            // drops the lower half
      const r = store.getState().rules.spatial!;
      expect(r.kind).toBe('intersect');
      expect(n(r)).toBe(20);
      lassoSpatial(box(0, 10, 9, 10), 'subtract');           // extends the intersection
      expect((store.getState().rules.spatial as any).params.parts.length).toBe(3);
      expect(n(store.getState().rules.spatial)).toBe(16);
    });
  }

  it('the scatter keeps lassos in different axes as one union', () => {
    actions.clearSelection();
    lassoScatter(box(0, 2, 0, 10), 'score', 'score');
    lassoScatter(box(8, 10, 0, 10), 'x', 'y', 'add');
    const r = store.getState().rules.scatter!;
    expect(r.kind).toBe('union');
  });

  it('a subtracting brush removes what it covers', () => {
    actions.clearSelection();
    state.cells = cells;
    lassoSpatial(box(0, 10, 0, 10));                         // all 100
    brushStart([0.5, 0.5], 0.6, 'subtract');
    brushMove([0.5, 9.5]);                                   // column x = 0.5
    brushEnd();
    const r = store.getState().rules.spatial!;
    expect(r.kind).toBe('intersect');
    expect(n(r)).toBe(90);
    state.cells = null;
  });
});
