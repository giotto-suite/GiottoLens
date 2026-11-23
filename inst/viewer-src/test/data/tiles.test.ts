import { describe, it, expect } from 'vitest';
import { visibleTiles } from '../../data/tiles.js';

describe('visibleTiles', () => {
  const tiles = [
    { index: 1, xmin: 0, xmax: 10, ymin: 0, ymax: 10 },
    { index: 2, xmin: 100, xmax: 110, ymin: 0, ymax: 10 },
  ];
  it('uses the given viewport size, not the window', () => {
    const vs = { target: [5, 5], zoom: 0 };   // 1 px per unit
    expect(visibleTiles(vs, tiles, { width: 20, height: 20 }).map((t: any) => t.index)).toEqual([1]);
    expect(visibleTiles(vs, tiles, { width: 220, height: 20 }).map((t: any) => t.index)).toEqual([1, 2]);
  });
});
