import { describe, it, expect } from 'vitest';
import {
  apply, compose, invert, fitAffine, flip, rotate90, fitPlacement, pixelToData, extentAffine,
  registrationFit, currentTransform, matrix4, mapView, IDENTITY, type Affine, type XY, type Registration,
} from '../data/registration.ts';

// Human_Breast_Biomarkers_S1_Top_he_imagealignment.csv (10x): H&E pixels →
// DAPI pixels. The DAPI image (0.2125 um pixels) spans x 0..W*mu, y -H*mu..0
const TENX: Affine = [0.009888241210118002, 1.2895672288436943, -1108.086547782943,
                      -1.2895672288436943, 0.009888241210118002, 26722.424520037363];
const MU = 0.2125;
const DAPI: Affine = [MU, 0, 0, 0, -MU, 0];
const HE = { width: 20515, height: 43995 };

const close = (a: number[], b: number[], tol: number) =>
  a.forEach((v, i) => expect(Math.abs(v - b[i])).toBeLessThan(tol * Math.max(1, Math.abs(b[i]))));

// Deterministic points over the H&E
function points(n: number): XY[] {
  let s = 7;
  const r = () => ((s = (s * 16807) % 2147483647) / 2147483647);
  return Array.from({ length: n }, () => [r() * HE.width, r() * HE.height] as XY);
}

describe('affine algebra', () => {
  it('composes and inverts', () => {
    const p: Affine = [2, 0.5, 3, -1, 1.5, -4];
    close(compose(p, invert(p)!), IDENTITY, 1e-12);
    close(apply(compose(p, TENX), [10, 20]), apply(p, apply(TENX, [10, 20])), 1e-9);
    expect(invert([1, 2, 0, 2, 4, 0])).toBeNull();
  });

  it('builds the extent transform with row 0 at ymax', () => {
    const e = extentAffine({ xmin: 0, xmax: 100, ymin: -50, ymax: 0 }, 100, 50);
    close(apply(e, [0, 0]), [0, 0], 1e-12);
    close(apply(e, [100, 50]), [100, -50], 1e-12);
  });

  it('applies an image affine after its extent', () => {
    const p = pixelToData({ xmin: 0, xmax: 10, ymin: -10, ymax: 0 }, 10, 10, [0, 1, 5, -1, 0, 0]);
    close(apply(p, [1, 0]), [5, -1], 1e-12);   // extent (1, 0), then (y + 5, -x)
  });

  it('gives a column-major model matrix', () => {
    const m = matrix4([1, 2, 3, 4, 5, 6]);
    expect(m).toEqual([1, 4, 0, 0, 2, 5, 0, 0, 0, 0, 1, 0, 3, 6, 0, 1]);
  });
});

describe('coarse placement', () => {
  const base = fitPlacement(HE.width, HE.height, { xmin: 0, xmax: 1000, ymin: 0, ymax: 500 });
  const centre = apply(base, [HE.width / 2, HE.height / 2]);

  it('fits the image in the box, centred, row 0 on top', () => {
    close(centre, [500, 250], 1e-9);
    const top = apply(base, [0, 0]), bottom = apply(base, [0, HE.height]);
    expect(top[1]).toBeGreaterThan(bottom[1]);
    expect(Math.abs(top[1] - bottom[1])).toBeCloseTo(500, 6);
  });

  it('flips and rotates about the centre', () => {
    for (const p of [flip(base, HE.width, HE.height, 'h'), flip(base, HE.width, HE.height, 'v'),
                     rotate90(base, HE.width, HE.height, 1), rotate90(base, HE.width, HE.height, -1)])
      close(apply(p, [HE.width / 2, HE.height / 2]), centre, 1e-9);
    close(rotate90(rotate90(base, HE.width, HE.height, 1), HE.width, HE.height, -1), base, 1e-9);
    close(flip(flip(base, HE.width, HE.height, 'h'), HE.width, HE.height, 'h'), base, 1e-9);
    let r = base;
    for (let i = 0; i < 4; i++) r = rotate90(r, HE.width, HE.height, 1);
    close(r, base, 1e-9);
  });

  it('turns counterclockwise on screen for +1', () => {
    const r = rotate90([1, 0, 0, 0, 1, 0], 2, 2, 1);   // centre (1, 1)
    close(apply(r, [2, 1]), [1, 2], 1e-12);            // right of centre goes up
  });
});

describe('fitAffine', () => {
  const truth = compose(DAPI, TENX);                    // H&E pixels → data

  it('recovers the 10x alignment from exact pairs', () => {
    const src = points(3);
    const fit = fitAffine(src, src.map(p => apply(truth, p)))!;
    close(fit.transform, truth, 1e-9);
    expect(fit.rmse).toBeLessThan(1e-6);
    close(compose(invert(DAPI)!, fit.transform), TENX, 1e-9);   // back in DAPI pixels
  });

  it('recovers it from noisy pairs with residuals near the noise', () => {
    const src = points(25);
    let s = 3;
    const noise = () => (((s = (s * 48271) % 2147483647) / 2147483647) - 0.5) * 2;   // ±1 um
    const dst = src.map(p => { const [x, y] = apply(truth, p); return [x + noise(), y + noise()] as XY; });
    const fit = fitAffine(src, dst)!;
    expect(fit.residuals).toHaveLength(25);
    expect(fit.rmse).toBeLessThan(1);
    // Corners of the H&E land within a few um of where 10x puts them
    for (const c of [[0, 0], [HE.width, 0], [0, HE.height], [HE.width, HE.height]] as XY[]) {
      const [x, y] = apply(fit.transform, c), [tx, ty] = apply(truth, c);
      expect(Math.hypot(x - tx, y - ty)).toBeLessThan(5);
    }
  });

  it('needs three pairs not on one line', () => {
    expect(fitAffine([[0, 0], [1, 1]], [[0, 0], [1, 1]])).toBeNull();
    expect(fitAffine([[0, 0], [1, 1], [2, 2]], [[0, 0], [1, 1], [2, 2]])).toBeNull();
  });
});

describe('registration state', () => {
  const base: Affine = [0.5, 0, 0, 0, -0.5, 0];
  const truth: Affine = [0, 0.3, 10, -0.3, 0, 20];
  const src = points(4);
  const reg = (n: number, open = false): Registration => ({
    image: 'he', reference: 'dapi', base, orient: [1, 0, 0, 0, -1, 0], preview: false, link: false,
    landmarks: [
      ...src.slice(0, n).map((p, i) => ({ id: String(i), moving: p, fixed: apply(truth, p) })),
      ...(open ? [{ id: 'open', moving: [1, 1] as XY, fixed: null }] : []),
    ],
  });

  it('draws with the base until three pairs are complete', () => {
    expect(registrationFit(reg(2, true))).toBeNull();
    expect(currentTransform(reg(2, true))).toBe(base);
    close(currentTransform(reg(3, true)), truth, 1e-9);
    expect(registrationFit(reg(4, true))!.residuals).toHaveLength(4);
  });
});

describe('linked views', () => {
  // Pane units are H&E pixels; 0.25 data units each, turned 90 degrees
  const m: Affine = [0, -0.25, 100, 0.25, 0, 50];
  const inv = invert(m)!;

  it('show the same extent: zoom moves by the scale, the centre through the map', () => {
    const v = mapView({ target: [40, 20, 0], zoom: -1 }, m, { target: [0, 0, 0], zoom: 3, minZoom: -9 });
    expect(v.target).toEqual([95, 60, 0]);
    expect(v.zoom).toBeCloseTo(1, 12);      // 4 pane units per data unit: 2 zoom levels up
    expect(v.minZoom).toBe(-9);
  });

  it('zoom out in one pane zooms out in the other, both ways', () => {
    const into = { target: [0, 0, 0], zoom: 0 };
    const a = mapView({ target: [40, 20, 0], zoom: -1 }, m, into);
    const b = mapView({ target: [40, 20, 0], zoom: -2 }, m, into);
    expect(b.zoom).toBeLessThan(a.zoom);
    const c = mapView({ target: [95, 60, 0], zoom: 1 }, inv, into);
    const d = mapView({ target: [95, 60, 0], zoom: 0 }, inv, into);
    expect(d.zoom).toBeLessThan(c.zoom);
    expect(c.zoom).toBeCloseTo(-1, 12);
    close(c.target.slice(0, 2), [40, 20], 1e-9);
  });

  it('drops zoomX and zoomY, which deck.gl prefers over zoom, and reads them when given', () => {
    const v = mapView({ target: [0, 0, 0], zoom: 0, zoomX: -1, zoomY: -1 }, m,
                      { target: [0, 0, 0], zoom: 5, zoomX: 5, zoomY: 5 });
    expect(v.zoomX).toBeUndefined();
    expect(v.zoomY).toBeUndefined();
    expect(v.zoom).toBeCloseTo(1, 12);
  });
});
