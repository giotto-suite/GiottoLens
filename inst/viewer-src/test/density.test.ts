import { describe, it, expect } from 'vitest';
import { binDensity, densityPixels, boxRule, boxFrom, sameBox } from '../panels/density.ts';
import type { MetaColumn } from '../data/meta.ts';

const col = (name: string, v: number[]): MetaColumn => {
  const values = Float64Array.from(v);
  const ok = v.filter(x => x === x);
  return { name, kind: 'continuous', values, min: Math.min(...ok), max: Math.max(...ok) };
};

describe('density panel', () => {
  const x = col('x', [0, 1, 2, 3, 4, NaN]);
  const y = col('y', [0, 0, 4, 4, 4, 1]);

  it('bins cells over the columns\' range, the maximum in the last bin', () => {
    const d = binDensity(x, y, null, 4);
    expect(d.sel).toBeNull();
    expect([...d.all].reduce((a, b) => a + b, 0)).toBe(5);   // the NaN row is left out
    expect(d.all[0 * 4 + 0]).toBe(1);   // (0, 0)
    expect(d.all[0 * 4 + 1]).toBe(1);   // (1, 0)
    expect(d.all[3 * 4 + 2]).toBe(1);   // (2, 4)
    expect(d.all[3 * 4 + 3]).toBe(2);   // (3, 4) and (4, 4): the maximum stays in range
    expect(d.maxAll).toBe(2);
  });

  it('bins only the cells inside a zoomed domain, over its full width', () => {
    const d = binDensity(x, y, null, 4, [1, 3], [0, 4]);
    expect([...d.all].reduce((a, b) => a + b, 0)).toBe(3);   // x = 1, 2, 3
    expect(d.all[0 * 4 + 0]).toBe(1);   // (1, 0) is now the first column
    expect(d.all[3 * 4 + 2]).toBe(1);   // (2, 4)
    expect(d.all[3 * 4 + 3]).toBe(1);   // (3, 4): the domain's maximum stays in range
  });

  it('counts the foreground cells separately', () => {
    const d = binDensity(x, y, Uint8Array.from([0, 0, 0, 1, 1, 0]), 4);
    expect(d.sel![3 * 4 + 3]).toBe(2);
    expect([...d.sel!].reduce((a, b) => a + b, 0)).toBe(2);
    expect(d.maxSel).toBe(2);
  });

  it('draws the largest y on the top row, empty bins transparent, counts in viridis', () => {
    const at = (px: Uint8ClampedArray, row: number, colm: number) => [...px.slice((row * 4 + colm) * 4, (row * 4 + colm) * 4 + 4)];
    const top = [253, 231, 37, 255];   // viridis' bright end
    // No selection: the fullest bin, (3..4, 4) on the top row, gets the bright end
    const all = densityPixels(binDensity(x, y, null, 4), 4);
    expect(at(all, 0, 3)).toEqual(top);
    expect(at(all, 3, 0)[3]).toBe(255);         // (0, 0): bottom row, one cell
    expect(at(all, 3, 0)).not.toEqual(top);
    expect(at(all, 1, 1)).toEqual([0, 0, 0, 0]);   // empty
    // A selection: its cells are coloured, bins without any are grey
    const sel = densityPixels(binDensity(x, y, Uint8Array.from([0, 0, 0, 1, 1, 0]), 4), 4);
    expect(at(sel, 0, 3)).toEqual(top);
    expect(at(sel, 3, 0)).toEqual([55, 65, 81, 255]);
  });

  it('turns a rectangle into two ranges and back', () => {
    const r = boxRule('density', 'x', 'y', { x: [3, 1], y: [0.5, 2] })!;
    expect(r).toEqual({ source: 'density', kind: 'intersect', params: { parts: [
      { source: 'density', kind: 'range', space: 'x', params: { min: 1, max: 3 } },
      { source: 'density', kind: 'range', space: 'y', params: { min: 0.5, max: 2 } },
    ] } });
    expect(boxFrom(r, 'x', 'y')).toEqual({ x: [1, 3], y: [0.5, 2] });
    expect(boxFrom(r, 'x', 'z')).toBeNull();              // other columns
    expect(boxFrom({ ...r, negate: true }, 'x', 'y')).toBeNull();
    expect(boxFrom({ source: 'density', kind: 'range', space: 'x', params: { min: 0, max: 1 } }, 'x', 'y')).toBeNull();
    expect(boxRule('density', 'x', 'y', null)).toBeNull();
    // Float noise from a round trip through pixels is the same rectangle
    const noisy = boxRule('density', 'x', 'y', { x: [1 + 1e-15, 3], y: [0.5, 2 - 1e-15] });
    expect(sameBox(r, noisy, 'x', 'y')).toBe(true);
    expect(sameBox(r, boxRule('density', 'x', 'y', { x: [1.01, 3], y: [0.5, 2] }), 'x', 'y')).toBe(false);
    expect(sameBox(null, undefined, 'x', 'y')).toBe(true);
    expect(sameBox(r, null, 'x', 'y')).toBe(false);
  });
});
