import { describe, it, expect } from 'vitest';
// @ts-ignore: plain JS module
import { nextAnnotName, annotationsFromR } from '../ui/annotations.js';
import { openRing, closeRing, insertVertex, removeVertex, handles } from '../ui/annot-edit.ts';

describe('annotation names', () => {
  it('a new shape gets annotation_<n>, n above any in use', () => {
    expect(nextAnnotName([])).toBe('annotation_1');
    expect(nextAnnotName(['tumor', 'annotation_3', 'annotation_1'])).toBe('annotation_4');
    expect(nextAnnotName(['annotation_x', 'my_annotation_9'])).toBe('annotation_1');
  });
});

describe('annotations from R', () => {
  it('rebuilds the shapes from the GeoJSON R holds', () => {
    const ring = [[0, 0], [1, 0], [1, 1], [0, 0]];
    const geojson = JSON.stringify({ type: 'Feature', geometry: { type: 'Polygon', coordinates: [ring] } });
    const got = annotationsFromR([{ name: 'tumor', geojson }]);
    expect(got).toHaveLength(1);
    expect(got[0].name).toBe('tumor');
    expect(got[0].coords).toEqual(ring);
    expect(annotationsFromR(undefined)).toEqual([]);
  });
});

describe('annotation vertex editing', () => {
  const square: [number, number][] = [[0, 0], [10, 0], [10, 10], [0, 10]];

  it('edits the open ring and closes it again', () => {
    expect(openRing(closeRing(square))).toEqual(square);
    expect(openRing(square)).toEqual(square);   // already open: left as is
  });
  it('inserts a vertex before `index`', () => {
    expect(insertVertex(square, 1, [5, 0])).toEqual([[0, 0], [5, 0], [10, 0], [10, 10], [0, 10]]);
  });
  it('removes a vertex, but not below a triangle', () => {
    expect(removeVertex(square, 0)).toEqual([[10, 0], [10, 10], [0, 10]]);
    expect(removeVertex(square.slice(0, 3), 0)).toBeNull();
  });
  it('puts a midpoint on each side long enough on screen, the closing one too', () => {
    const { vertices, midpoints } = handles(square, 2);   // 10 units = 40 px
    expect(vertices.map(v => v.index)).toEqual([0, 1, 2, 3]);
    expect(midpoints).toContainEqual({ index: 4, pos: [0, 5] });
    expect(midpoints).toHaveLength(4);
    expect(handles(square, 0).midpoints).toHaveLength(0);   // 10 px sides
  });
});
