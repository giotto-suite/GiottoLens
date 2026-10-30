import { describe, it, expect } from 'vitest';
import { escapeHtml, fitZoom, pointInPolygon, clientToWorld, worldToClient } from '../ui/dom.js';

describe('escapeHtml', () => {
  it('escapes markup and quotes', () => {
    expect(escapeHtml(`<img src=x onerror="a('b')">&`))
      .toBe('&lt;img src=x onerror=&quot;a(&#39;b&#39;)&quot;&gt;&amp;');
  });
  it('stringifies non-strings', () => {
    expect(escapeHtml(12)).toBe('12');
    expect(escapeHtml(null)).toBe('null');
  });
});

describe('fitZoom', () => {
  it('fits the limiting dimension', () => {
    expect(fitZoom(100, 50, { width: 400, height: 400 })).toBeCloseTo(2);   // 400/100 = 4
    expect(fitZoom(10, 100, { width: 400, height: 200 })).toBeCloseTo(1);   // 200/100 = 2
  });
});

describe('pointInPolygon', () => {
  const sq = [[0, 0], [10, 0], [10, 10], [0, 10]];
  it('handles inside, outside and concave rings', () => {
    expect(pointInPolygon(sq, 5, 5)).toBe(true);
    expect(pointInPolygon(sq, 15, 5)).toBe(false);
    const c = [[0, 0], [10, 0], [10, 10], [5, 2], [0, 10]];
    expect(pointInPolygon(c, 5, 8)).toBe(false);
    expect(pointInPolygon(c, 2, 2)).toBe(true);
  });
});

describe('client ↔ world transforms (Y up)', () => {
  const canvas = { getBoundingClientRect: () => ({ left: 100, top: 50, width: 400, height: 200 }) };
  const vs = { target: [10, -20], zoom: 1 };
  it('maps the canvas centre to the view target and up to +y', () => {
    expect(clientToWorld(300, 150, canvas, vs)).toEqual([10, -20]);
    const [, yUp] = clientToWorld(300, 140, canvas, vs);
    expect(yUp).toBeGreaterThan(-20);
  });
  it('round-trips', () => {
    const [cx, cy] = worldToClient(17.5, -3.25, canvas, vs);
    const [x, y] = clientToWorld(cx, cy, canvas, vs);
    expect(x).toBeCloseTo(17.5);
    expect(y).toBeCloseTo(-3.25);
  });
});
