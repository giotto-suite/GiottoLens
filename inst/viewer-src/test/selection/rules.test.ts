import { describe, it, expect } from 'vitest';
import { ringTester, type Ring } from '../../selection/geometry.ts';
import { evaluate, combine, encodeMask, decodeMask, markSegment, countMask, ruleColumns, type Rule } from '../../selection/rules.ts';
import { rng, grid, gridMeta } from '../helpers.ts';

function naivePip(ring: Ring, x: number, y: number) {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [xi, yi] = ring[i], [xj, yj] = ring[j];
    if ((yi > y) !== (yj > y) && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

describe('ringTester', () => {
  it('agrees with the plain even-odd test on a concave ring', () => {
    const ring: Ring = Array.from({ length: 50 }, (_, k) => {
      const a = (k / 50) * 2 * Math.PI, r = 5 + 2 * Math.sin(5 * a);
      return [10 + r * Math.cos(a), 10 + r * Math.sin(a)];
    });
    const T = ringTester(ring, 16);
    const rand = rng(1);
    for (let i = 0; i < 2000; i++) {
      const x = rand() * 20, y = rand() * 20;
      expect(T.test(x, y)).toBe(naivePip(ring, x, y));
    }
  });
});

describe('rules', () => {
  const cells = grid();
  const ctx = { cells, meta: gridMeta(cells) };
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

describe('ruleColumns', () => {
  it('collects the metadata columns a rule reads', () => {
    const r: Rule = { source: 's', kind: 'union', params: { parts: [
      { source: 's', kind: 'polygon', space: { x: 'u1', y: 'u2' }, params: { rings: [] } },
      { source: 's', kind: 'polygon', space: 'spatial', params: { rings: [] } },
      { source: 's', kind: 'intersect', params: { parts: [
        { source: 's', kind: 'range', space: 'score', params: { min: 0, max: 1 } },
        { source: 's', kind: 'compare', space: 'lab', params: { op: '=', value: 'x' } },
      ] } },
    ] } };
    expect([...ruleColumns(r)]).toEqual(['u1', 'u2', 'score', 'lab']);
  });
});
