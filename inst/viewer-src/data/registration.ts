// Image registration by landmarks: 2D affine transforms, the least-squares
// fit from landmark pairs, the starting placement of the image being
// registered, and the flips and rotations of its own pane (adr/0012).
//
// An affine is [a, b, c, d, e, f]: x' = a x + b y + c, y' = d x + e y + f, the
// same form as a manifest image's `affine`. An image's transform maps its
// pixels (x = column, y = row, level 0) to data coordinates.

export type Affine = [number, number, number, number, number, number];
export type XY = [number, number];

export interface Landmark {
  id: string;
  moving: XY | null;   // pixel of the image being registered
  fixed: XY | null;    // data coordinates
}

export interface Registration {
  image: string;               // the image being registered
  reference: string | null;    // the image the fixed points are placed on
  base: Affine;                // pixels → data before a fit
  landmarks: Landmark[];
  orient: Affine;              // pixels → the image's own pane: flips, quarter turns
  preview: boolean;            // the image drawn with the fit over the reference
  link: boolean;               // the two panes move together (with a fit)
}

// Row 0 at the top of the image's pane
export const UPRIGHT: Affine = [1, 0, 0, 0, -1, 0];

export interface Fit {
  transform: Affine;
  residuals: number[];         // per complete pair, data units, in landmark order
  rmse: number;
}

export const IDENTITY: Affine = [1, 0, 0, 0, 1, 0];
export const MIN_PAIRS = 3;

export function apply(p: Affine, [x, y]: XY): XY {
  return [p[0] * x + p[1] * y + p[2], p[3] * x + p[4] * y + p[5]];
}

// p after q: compose(p, q)(v) = p(q(v))
export function compose(p: Affine, q: Affine): Affine {
  return [
    p[0] * q[0] + p[1] * q[3], p[0] * q[1] + p[1] * q[4], p[0] * q[2] + p[1] * q[5] + p[2],
    p[3] * q[0] + p[4] * q[3], p[3] * q[1] + p[4] * q[4], p[3] * q[2] + p[4] * q[5] + p[5],
  ];
}

export function invert(p: Affine): Affine | null {
  const det = p[0] * p[4] - p[1] * p[3];
  if (!Number.isFinite(det) || det === 0) return null;
  const a = p[4] / det, b = -p[1] / det, d = -p[3] / det, e = p[0] / det;
  return [a, b, -(a * p[2] + b * p[5]), d, e, -(d * p[2] + e * p[5])];
}

export interface Extent { xmin: number; xmax: number; ymin: number; ymax: number }

// Pixels → data for an image spanning `extent`, row 0 at ymax
export function extentAffine(ext: Extent, width: number, height: number): Affine {
  return [(ext.xmax - ext.xmin) / width, 0, ext.xmin, 0, -(ext.ymax - ext.ymin) / height, ext.ymax];
}

// The image's own transform: its extent, then its `affine` if it has one
export function pixelToData(ext: Extent, width: number, height: number, affine?: number[] | null): Affine {
  const e = extentAffine(ext, width, height);
  return affine ? compose(affine as Affine, e) : e;
}

// The whole image inside `box`, centred, square pixels, row 0 at the top
export function fitPlacement(width: number, height: number, box: Extent): Affine {
  const s = Math.min((box.xmax - box.xmin) / width, (box.ymax - box.ymin) / height);
  const cx = (box.xmin + box.xmax) / 2, cy = (box.ymin + box.ymax) / 2;
  return [s, 0, cx - s * width / 2, 0, -s, cy + s * height / 2];
}

// `op` in data space about the image's centre, applied after `p`
function aboutCentre(p: Affine, width: number, height: number, op: Affine): Affine {
  const [cx, cy] = apply(p, [width / 2, height / 2]);
  const t: Affine = [1, 0, cx, 0, 1, cy], tInv: Affine = [1, 0, -cx, 0, 1, -cy];
  return compose(t, compose(op, compose(tInv, p)));
}

// Quarter turns as seen on screen (y up): 1 is 90 degrees counterclockwise
export function rotate90(p: Affine, width: number, height: number, turns: number): Affine {
  const k = ((Math.round(turns) % 4) + 4) % 4;
  const op: Affine[] = [IDENTITY, [0, -1, 0, 1, 0, 0], [-1, 0, 0, 0, -1, 0], [0, 1, 0, -1, 0, 0]];
  return aboutCentre(p, width, height, op[k]);
}

// 'h' mirrors left-right on screen, 'v' top-bottom
export function flip(p: Affine, width: number, height: number, axis: 'h' | 'v'): Affine {
  return aboutCentre(p, width, height, axis === 'h' ? [-1, 0, 0, 0, 1, 0] : [1, 0, 0, 0, -1, 0]);
}

// Least-squares affine taking `src` to `dst`; null for fewer than three
// pairs or points on one line
export function fitAffine(src: XY[], dst: XY[]): Fit | null {
  const n = src.length;
  if (n < MIN_PAIRS || dst.length !== n) return null;
  let sx = 0, sy = 0, tx = 0, ty = 0;
  for (let i = 0; i < n; i++) { sx += src[i][0]; sy += src[i][1]; tx += dst[i][0]; ty += dst[i][1]; }
  sx /= n; sy /= n; tx /= n; ty /= n;
  let sxx = 0, sxy = 0, syy = 0, xu = 0, yu = 0, xv = 0, yv = 0;
  for (let i = 0; i < n; i++) {
    const x = src[i][0] - sx, y = src[i][1] - sy, u = dst[i][0] - tx, v = dst[i][1] - ty;
    sxx += x * x; sxy += x * y; syy += y * y;
    xu += x * u; yu += y * u; xv += x * v; yv += y * v;
  }
  const det = sxx * syy - sxy * sxy;
  if (!(det > 1e-12 * (sxx + syy) * (sxx + syy))) return null;
  const a = (syy * xu - sxy * yu) / det, b = (sxx * yu - sxy * xu) / det;
  const d = (syy * xv - sxy * yv) / det, e = (sxx * yv - sxy * xv) / det;
  const transform: Affine = [a, b, tx - a * sx - b * sy, d, e, ty - d * sx - e * sy];
  const residuals = src.map((p, i) => {
    const [x, y] = apply(transform, p);
    return Math.hypot(x - dst[i][0], y - dst[i][1]);
  });
  const rmse = Math.sqrt(residuals.reduce((s, r) => s + r * r, 0) / n);
  return { transform, residuals, rmse };
}

export function completePairs(reg: Registration): Landmark[] {
  return reg.landmarks.filter(l => l.moving && l.fixed);
}

// The fit from the complete pairs, or null while there are too few
export function registrationFit(reg: Registration): Fit | null {
  const done = completePairs(reg);
  return fitAffine(done.map(l => l.moving as XY), done.map(l => l.fixed as XY));
}

// Pixels → data as drawn: the fit once there is one, the base before
export function currentTransform(reg: Registration): Affine {
  return registrationFit(reg)?.transform ?? reg.base;
}

// The view of one pane as seen in another: `m` maps the first pane's
// coordinates to the second's. The centre moves through `m`, and the zoom
// changes by the scale of `m` so both show the same extent. `into` is the
// second pane's current view (its other settings are kept). deck.gl's
// controller adds zoomX and zoomY, which take precedence over zoom; they are
// dropped so that zoom applies.
export interface View { target: number[]; zoom: number; zoomX?: number; zoomY?: number; [k: string]: unknown }
export function mapView(from: View, m: Affine, into: View): View {
  const { zoomX: _x, zoomY: _y, ...rest } = into;
  const z = typeof from.zoomX === 'number' ? from.zoomX : from.zoom;
  const scale = Math.sqrt(Math.abs(m[0] * m[4] - m[1] * m[3]));
  return { ...rest, target: [...apply(m, [from.target[0], from.target[1]]), 0], zoom: z - Math.log2(scale) };
}

// Column-major 4x4 for deck.gl's modelMatrix
export function matrix4(p: Affine): number[] {
  return [p[0], p[3], 0, 0, p[1], p[4], 0, 0, 0, 0, 1, 0, p[2], p[5], 0, 1];
}
