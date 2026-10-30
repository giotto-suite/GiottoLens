// Geometry tests over many points.

export type Pt = [number, number];
export type Ring = Pt[];

export interface RingTester {
  xmin: number; xmax: number; ymin: number; ymax: number;
  test(x: number, y: number): boolean;
}

// Point-in-polygon (even-odd) with edges bucketed into horizontal bands, so
// each point checks only the edges spanning its band. ~6x faster than testing
// every edge on a 64-vertex lasso, and nearly flat in vertex count.
export function ringTester(ring: Ring, bands = 256): RingTester {
  let xmin = Infinity, xmax = -Infinity, ymin = Infinity, ymax = -Infinity;
  for (const [x, y] of ring) {
    if (x < xmin) xmin = x; if (x > xmax) xmax = x;
    if (y < ymin) ymin = y; if (y > ymax) ymax = y;
  }
  const n = ring.length;
  const h = (ymax - ymin) / bands || 1;
  const ax = new Float64Array(n), ay = new Float64Array(n), bx = new Float64Array(n), by = new Float64Array(n);
  const lists: number[][] = Array.from({ length: bands }, () => []);
  for (let i = 0, j = n - 1; i < n; j = i++) {
    ax[i] = ring[i][0]; ay[i] = ring[i][1]; bx[i] = ring[j][0]; by[i] = ring[j][1];
    const lo = Math.max(0, Math.floor((Math.min(ay[i], by[i]) - ymin) / h));
    const hi = Math.min(bands - 1, Math.floor((Math.max(ay[i], by[i]) - ymin) / h));
    for (let b = lo; b <= hi; b++) lists[b].push(i);
  }
  const edges = lists.map(l => Int32Array.from(l));
  return {
    xmin, xmax, ymin, ymax,
    test(x, y) {
      if (x < xmin || x > xmax || y < ymin || y > ymax) return false;
      const e = edges[Math.min(bands - 1, ((y - ymin) / h) | 0)];
      let inside = false;
      for (let k = 0; k < e.length; k++) {
        const i = e[k];
        if ((ay[i] > y) !== (by[i] > y) && x < ((bx[i] - ax[i]) * (y - ay[i])) / (by[i] - ay[i]) + ax[i]) inside = !inside;
      }
      return inside;
    },
  };
}

// Squared distance from (x, y) to segment a–b
export function segDist2(x: number, y: number, a: Pt, b: Pt): number {
  const dx = b[0] - a[0], dy = b[1] - a[1];
  const len2 = dx * dx + dy * dy;
  let t = len2 ? ((x - a[0]) * dx + (y - a[1]) * dy) / len2 : 0;
  t = t < 0 ? 0 : t > 1 ? 1 : t;
  const px = a[0] + t * dx - x, py = a[1] + t * dy - y;
  return px * px + py * py;
}
