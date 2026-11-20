import { describe, it, expect } from 'vitest';
// @ts-ignore: plain JS module
import { nextAnnotName, annotationsFromR } from '../ui/annotations.js';

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
