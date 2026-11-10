import { describe, it, expect } from 'vitest';
import { cellColorBuffer, DEFAULT_CELL, continuousColor, scaleStops, SCALE_PRESETS } from '../render/colors.ts';

describe('cellColorBuffer', () => {
  it('fills the default colour without a column', () => {
    const { colors, legend } = cellColorBuffer(2, null);
    expect([...colors.slice(4, 8)]).toEqual(DEFAULT_CELL);
    expect(legend).toBeNull();
  });
  it('colours categories by level and greys NA', () => {
    const col = { name: 'c', kind: 'categorical' as const, levels: ['a', 'b'], values: Int32Array.from([1, -1, 0]), min: 0, max: 0 };
    const { colors, legend } = cellColorBuffer(3, col);
    expect(legend?.type).toBe('categorical');
    expect([...colors.slice(4, 8)]).toEqual([80, 80, 80, 180]);
    expect([...colors.slice(0, 3)]).not.toEqual([...colors.slice(8, 11)]);
  });
  it('keeps the default category alpha: centroids 255, fills 230', () => {
    const col = { name: 'c', kind: 'categorical' as const, levels: ['a'], values: Int32Array.from([0]), min: 0, max: 0 };
    const { colors, fill } = cellColorBuffer(1, col);
    expect(colors[3]).toBe(255);
    expect(fill[0]).toBe(230);
  });
  it('applies per-category color, visibility and opacity', () => {
    const col = { name: 'c', kind: 'categorical' as const, levels: ['a', 'b', 'c'], values: Int32Array.from([0, 1, 2, -1]), min: 0, max: 0 };
    const { colors, fill, legend } = cellColorBuffer(4, col, {
      a: { color: [1, 2, 3], alpha: 1 },
      b: { show: false },
      c: { alpha: 0.2 },
    });
    expect([...colors.slice(0, 4)]).toEqual([1, 2, 3, 255]);
    expect(fill[0]).toBe(255);
    expect(fill[1]).toBe(20);
    expect([...colors.slice(4, 8)]).toEqual([160, 160, 160, 120]);
    expect(fill[2]).toBe(51);
    expect(colors[11]).toBe(102);
    expect(legend?.type === 'categorical' && legend.items.map(i => [i.label, i.show, i.alpha]))
      .toEqual([['a', true, 1], ['b', false, 0.9], ['c', true, 0.2]]);
  });
  it('interpolates between evenly spaced stops', () => {
    const st: [number, number, number][] = [[0, 0, 0], [100, 200, 0], [200, 0, 100]];
    expect(continuousColor(0, st)).toEqual([0, 0, 0, 220]);
    expect(continuousColor(0.25, st)).toEqual([50, 100, 0, 220]);
    expect(continuousColor(0.5, st)).toEqual([100, 200, 0, 220]);
    expect(continuousColor(1, st)).toEqual([200, 0, 100, 220]);
    expect(continuousColor(0.5, SCALE_PRESETS['blue-red'])).toEqual([128, 0, 128, 220]);
    expect(continuousColor(0)).toEqual([0x44, 0x01, 0x54, 220]);   // viridis by default
  });
  it('picks preset, custom and reversed scales', () => {
    expect(scaleStops()).toEqual(SCALE_PRESETS.viridis);
    expect(scaleStops({ preset: 'blue-red' })[0]).toEqual([0, 0, 255]);
    expect(scaleStops({ preset: 'custom', colors: [[1, 1, 1], [2, 2, 2]], reverse: true })).toEqual([[2, 2, 2], [1, 1, 1]]);
    expect(scaleStops({ preset: 'nope' })).toEqual(SCALE_PRESETS.viridis);
    const col = { name: 'v', kind: 'continuous' as const, values: Float64Array.from([0, 10]), min: 0, max: 10 };
    const { colors } = cellColorBuffer(2, col, {}, { preset: 'gray', reverse: true });
    expect([...colors.slice(0, 3)]).toEqual([255, 255, 255]);
    expect([...colors.slice(4, 7)]).toEqual([48, 48, 48]);
  });
  it('spans the numeric range', () => {
    const col = { name: 'v', kind: 'continuous' as const, values: Float64Array.from([0, 10, NaN]), min: 0, max: 10 };
    const { colors, legend } = cellColorBuffer(3, col);
    expect(legend).toMatchObject({ type: 'continuous', column: 'v', min: 0, max: 10 });
    expect([...colors.slice(0, 3)]).toEqual([0x44, 0x01, 0x54]);
    expect([...colors.slice(4, 7)]).toEqual([0xfd, 0xe7, 0x25]);
  });
});
