import { describe, it, expect } from 'vitest';
import {
  cellColorBuffer, DEFAULT_CELL, continuousColor, scaleStops, SCALE_PRESETS, scalePosition, scaleRange,
  medianOf, DIVERGENT_PRESETS, SEQUENTIAL_PRESETS, sliderToValue, valueToSlider, dragHandle, autoHandle, barColors,
} from '../../render/colors.ts';
import { applyPrefs, BUILTIN } from '../../core/prefs.ts';

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
  it('gives a continuous scale the fill opacity preference, as categories have', () => {
    const col = { name: 'x', kind: 'continuous' as const, values: Float64Array.from([0, 1, NaN]), min: 0, max: 1 };
    let { colors, fill } = cellColorBuffer(3, col);
    expect([colors[3], fill[0], fill[1]]).toEqual([255, 230, 230]);
    expect([...colors.slice(8, 12)]).toEqual([80, 80, 80, 180]);
    expect(fill[2]).toBe(110);
    applyPrefs({ defaults: BUILTIN, set: { fill_opacity: 0.4 } });
    ({ colors, fill } = cellColorBuffer(3, col));
    expect([colors[3], fill[0]]).toEqual([204, 102]);
    applyPrefs({ defaults: BUILTIN, set: {} });
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
    expect(continuousColor(0.5)).toEqual([255, 255, 255, 220]);
  });
  it('picks preset, custom and reversed scales', () => {
    expect(scaleStops()).toEqual(SCALE_PRESETS['blue-white-red']);
    expect(scaleStops({ style: 'sequential' })).toEqual(SCALE_PRESETS.viridis);
    expect(scaleStops({ preset: 'viridis' })[0]).toEqual([0x44, 0x01, 0x54]);
    expect(scaleStops({ preset: 'custom', colors: [[1, 1, 1], [2, 2, 2]], reverse: true })).toEqual([[2, 2, 2], [1, 1, 1]]);
    expect(scaleStops({ preset: 'nope' })).toEqual(SCALE_PRESETS['blue-white-red']);
    const col = { name: 'v', kind: 'continuous' as const, values: Float64Array.from([0, 10]), min: 0, max: 10 };
    const { colors } = cellColorBuffer(2, col, {}, { preset: 'gray', reverse: true });
    expect([...colors.slice(0, 3)]).toEqual([255, 255, 255]);
    expect([...colors.slice(4, 7)]).toEqual([48, 48, 48]);
  });
  it('spans the numeric range', () => {
    const col = { name: 'v', kind: 'continuous' as const, values: Float64Array.from([0, 10, NaN]), min: 0, max: 10 };
    const { colors, legend } = cellColorBuffer(3, col);
    expect(legend).toMatchObject({ type: 'continuous', column: 'v', min: 0, max: 10 });
    expect(colors[4]).toBe(255);
    expect(colors[0]).toBe(0);
  });
});

describe("Giotto's gradient styles", () => {
  it('lists every preset once, under one style', () => {
    expect([...DIVERGENT_PRESETS, ...SEQUENTIAL_PRESETS].sort()).toEqual(Object.keys(SCALE_PRESETS).sort());
  });
  it('centers a divergent scale on the midpoint, stretched by the larger side', () => {
    expect(scalePosition(2, 0, 10, 'divergent', 2)).toBe(0.5);
    expect(scalePosition(10, 0, 10, 'divergent', 2)).toBe(1);
    expect(scalePosition(0, 0, 10, 'divergent', 2)).toBe(0.375);
    expect(scalePosition(5, 0, 10, 'sequential', 2)).toBe(0.5);
  });
  it('clamps values beyond the limits', () => {
    expect(scalePosition(-5, 0, 10, 'sequential', 5)).toBe(0);
    expect(scalePosition(50, 0, 10, 'sequential', 5)).toBe(1);
    expect(scalePosition(50, 0, 10, 'divergent', 5)).toBe(1);
  });
  it('takes the median and the data range unless set', () => {
    const col = { values: Float64Array.from([0, 0, 1, 3, NaN]), min: 0, max: 3 };
    expect(medianOf(col.values)).toBe(0.5);
    expect(scaleRange(col)).toEqual({ lo: 0, hi: 3, mid: 0.5, style: 'divergent' });
    expect(scaleRange(col, { style: 'sequential', limits: [1, 2], midpoint: 9 }))
      .toEqual({ lo: 1, hi: 2, mid: 9, style: 'sequential' });
  });
  it('colors the median white on the default scale', () => {
    const col = { name: 'v', kind: 'continuous' as const, values: Float64Array.from([0, 1, 4]), min: 0, max: 4 };
    const { colors, legend } = cellColorBuffer(3, col);
    expect([...colors.slice(4, 7)]).toEqual([255, 255, 255]);
    expect(legend).toMatchObject({ style: 'divergent', mid: 1, lo: 0, hi: 4 });
    const seq = cellColorBuffer(3, col, {}, { style: 'sequential', limits: [0, 1] });
    expect([...seq.colors.slice(4, 7)]).toEqual([...seq.colors.slice(8, 11)]);
  });
});

describe('low / mid / high handles', () => {
  const r = { lo: 0, hi: 10, min: 0, max: 10 };
  it('map slider steps to values over the data range and back', () => {
    expect(sliderToValue(0, 0, 10)).toBe(0);
    expect(sliderToValue(500, 0, 10)).toBe(5);
    expect(sliderToValue(1000, 2, 4)).toBe(4);
    expect(valueToSlider(5, 0, 10)).toBe(500);
    expect(valueToSlider(50, 0, 10)).toBe(1000);
    expect(valueToSlider(1, 1, 1)).toBe(0);
  });
  it('move one handle and keep the others', () => {
    expect(dragHandle('mid', 3, r)).toEqual({ midpoint: 3 });
    expect(dragHandle('lo', 2, r)).toEqual({ limits: [2, 10] });
    expect(dragHandle('hi', 7, { ...r, lo: 2 })).toEqual({ limits: [2, 7] });
  });
  it('keep low below high', () => {
    expect(dragHandle('lo', 9, { ...r, hi: 5 })).toEqual({ limits: [4.99, 5] });
    expect(dragHandle('hi', 1, { ...r, lo: 5 })).toEqual({ limits: [5, 5.01] });
  });
  it('go back to automatic at the data range or on double-click', () => {
    expect(dragHandle('lo', 0, r)).toEqual({ limits: null });
    expect(autoHandle('mid', r)).toEqual({ midpoint: null });
    expect(autoHandle('lo', { ...r, lo: 2, hi: 7 })).toEqual({ limits: [0, 7] });
    expect(autoHandle('hi', { ...r, hi: 7 })).toEqual({ limits: null });
  });
});

describe('barColors', () => {
  const stops: [number, number, number][] = [[0, 0, 0], [255, 255, 255]];
  it('draws the data range, flat beyond the limits', () => {
    const c = barColors({ min: 0, max: 10, lo: 2, hi: 8, mid: 5, style: 'sequential', stops }, 11);
    expect(c[0]).toEqual([0, 0, 0]);
    expect(c[2]).toEqual([0, 0, 0]);
    expect(c[5]).toEqual([128, 128, 128]);
    expect(c[8]).toEqual([255, 255, 255]);
    expect(c[10]).toEqual([255, 255, 255]);
  });
  it('puts the middle color of a divergent scale at the midpoint', () => {
    const div: [number, number, number][] = [[0, 0, 255], [255, 255, 255], [255, 0, 0]];
    const c = barColors({ min: 0, max: 10, lo: 0, hi: 10, mid: 2, style: 'divergent', stops: div }, 11);
    expect(c[2]).toEqual([255, 255, 255]);
    expect(c[10]).toEqual([255, 0, 0]);
  });
});
