import { describe, it, expect } from 'vitest';
import { cellColorBuffer, DEFAULT_CELL } from '../render/colors.ts';

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
  it('spans the numeric range', () => {
    const col = { name: 'v', kind: 'continuous' as const, values: Float64Array.from([0, 10, NaN]), min: 0, max: 10 };
    const { colors, legend } = cellColorBuffer(3, col);
    expect(legend).toEqual({ type: 'continuous', min: 0, max: 10 });
    expect(colors[4]).toBe(255);
    expect(colors[0]).toBe(0);
  });
});
