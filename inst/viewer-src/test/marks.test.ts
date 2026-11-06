import { describe, it, expect } from 'vitest';
import { cellMarkLayer, drawnMark, showsShape, DOT_PX, type Mark } from '../render/marks.ts';
import { store, actions } from '../core/store.ts';

const square: Mark = { shape: 'square', size: 2, angle: 10 };
const layer = (mark: Mark | undefined, zoom: number) =>
  cellMarkLayer({ mark, zoom, data: { length: 0, attributes: {} }, opacity: 1, onHover: () => {} });

describe('cell marks', () => {
  it('draws dots without a mark', () => {
    expect(showsShape(undefined, 10)).toBe(false);
    expect(layer(undefined, 10).id).toBe('cell-centroids');
  });
  it('draws circles at every zoom, sized in data units with a pixel minimum', () => {
    const l: any = layer({ shape: 'circle', size: 6, angle: 0 }, -5);
    expect(l.id).toBe('cell-circles');
    expect(l.props.getRadius).toBe(3);
    expect(l.props.radiusUnits).toBe('common');
    expect(l.props.radiusMinPixels).toBe(DOT_PX);
  });
  it('switches squares from dots to shapes once they are as wide as a dot', () => {
    // 2 units across: 4 px at zoom 1, the width of a dot
    expect(layer(square, 0.9).id).toBe('cell-centroids');
    const l: any = layer(square, 1);
    expect(l.id).toBe('cell-squares');
    expect(l.props.radius).toBe(1);
    expect(l.props.angle).toBe(10);
    expect(l.props.vertices).toHaveLength(4);
  });
  it('draws hexagons that are `size` across their flats', () => {
    const l: any = layer({ shape: 'hex', size: 2, angle: 0 }, 3);
    expect(l.id).toBe('cell-hexagons');
    const xs = l.props.vertices.map((v: number[]) => v[0]);
    expect(Math.max(...xs) - Math.min(...xs)).toBeCloseTo(2);
  });
});

describe('drawnMark', () => {
  const bins = { mark: square, marks: true };
  const segmented = { mark: { shape: 'circle' as const, size: 10, angle: 0 }, marks: false };
  it('is the launch mark where it is drawn by default, and dots elsewhere', () => {
    expect(drawnMark(bins, {})).toEqual(square);
    expect(drawnMark(segmented, {})).toBeUndefined();
    expect(drawnMark(undefined, { show: true })).toBeUndefined();
  });
  it('takes the setting over the launch mark, field by field', () => {
    expect(drawnMark(bins, { shape: 'circle', size: 3 })).toEqual({ shape: 'circle', size: 3, angle: 10 });
    expect(drawnMark(bins, { show: false, size: 3 })).toBeUndefined();
    expect(drawnMark(segmented, { show: true })).toEqual(segmented.mark);
  });
});

describe('setCellMark', () => {
  it('merges fields, or resets all', () => {
    actions.setCellMark(null);
    actions.setCellMark({ shape: 'hex', size: 4 });
    actions.setCellMark({ angle: 30 });
    expect(store.getState().cellMark).toEqual({ shape: 'hex', size: 4, angle: 30 });
    actions.setCellMark(null);
    expect(store.getState().cellMark).toEqual({});
  });
});
