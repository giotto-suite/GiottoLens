import { describe, it, expect } from 'vitest';
import { tableRows, windowFor, applyPick, ROW_H } from '../panels/table.ts';

describe('cell table', () => {
  it('rows are the cells a mask holds, or all', () => {
    expect([...tableRows(null, 4)]).toEqual([0, 1, 2, 3]);
    expect([...tableRows(Uint8Array.from([0, 1, 0, 1, 1]), 5)]).toEqual([1, 3, 4]);
  });

  it('draws the rows in view, scrolled one row at a time', () => {
    const w = windowFor(ROW_H * 10 + 5, ROW_H * 5, 1000);
    expect(w.first).toBe(10);
    expect(w.top).toBe(ROW_H * 10);
    expect(w.height).toBe(1000 * ROW_H);
    expect(w.count).toBe(6 + 4);
    expect(windowFor(ROW_H * 998, ROW_H * 5, 1000).count).toBe(2);
    expect(windowFor(0, 100, 0).count).toBe(0);
  });

  it('scales the scroll range past the height cap and reaches the last row', () => {
    const n = 10_000_000, view = ROW_H * 5, cap = 1_000_000;
    const top = windowFor(0, view, n, ROW_H, cap);
    expect(top.height).toBe(cap);
    expect(top.first).toBe(0);
    const end = windowFor(cap - view, view, n, ROW_H, cap);
    expect(end.top).toBe(cap - view);
    expect(end.first + end.count).toBe(n);
    const mid = windowFor((cap - view) / 2, view, n, ROW_H, cap);
    expect(Math.abs(mid.first - n / 2)).toBeLessThan(10);
  });

  it('picks replace, toggle and add ranges', () => {
    const rows = Int32Array.from([2, 5, 7, 9]);
    const one = applyPick(null, 10, rows, 1, 'replace', null);
    expect([...one.keys()].filter(i => one[i])).toEqual([5]);
    // Clicking the only pick again clears it
    expect(applyPick(one, 10, rows, 1, 'replace', 1).every(v => v === 0)).toBe(true);
    const two = applyPick(one, 10, rows, 3, 'toggle', 1);
    expect([...two.keys()].filter(i => two[i])).toEqual([5, 9]);
    const back = applyPick(two, 10, rows, 3, 'toggle', 3);
    expect([...back.keys()].filter(i => back[i])).toEqual([5]);
    const range = applyPick(one, 10, rows, 3, 'range', 1);
    expect([...range.keys()].filter(i => range[i])).toEqual([5, 7, 9]);
    expect(one[5]).toBe(1);   // inputs are not changed
  });
});
