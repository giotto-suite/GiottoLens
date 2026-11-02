import { describe, it, expect } from 'vitest';
import { cellMarkLayer, showsShape, DOT_PX, type Mark } from '../render/marks.ts';

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
