// WKB polygon decoding into flat coordinate arrays for deck.gl binary layers.
// Only the exterior ring of the first polygon is kept (cell outlines).

// Appends the exterior ring of one (MULTI)POLYGON to `out` and returns the
// number of vertices written (0 if the geometry is not a polygon).
export function appendExteriorRing(wkb: Uint8Array, out: number[]): number {
  if (!wkb || wkb.byteLength < 9) return 0;
  const v = new DataView(wkb.buffer, wkb.byteOffset, wkb.byteLength);
  let off = 0;
  const le = v.getUint8(off++) === 1;
  const type = v.getUint32(off, le); off += 4;
  const base = type & 0xffff;
  if (type & 0x20000000) off += 4;            // EWKB SRID
  if (base === 6) {                             // MULTIPOLYGON: first part
    const n = v.getUint32(off, le); off += 4;
    if (!n) return 0;
    const ple = v.getUint8(off++) === 1;
    const pt = v.getUint32(off, ple) & 0xffff; off += 4;
    if (pt !== 3) return 0;
    return readRing(v, off, ple, out);
  }
  if (base !== 3) return 0;
  return readRing(v, off, le, out);
}

function readRing(v: DataView, off: number, le: boolean, out: number[]): number {
  const nRings = v.getUint32(off, le); off += 4;
  if (!nRings) return 0;
  const n = v.getUint32(off, le); off += 4;
  for (let p = 0; p < n; p++) {
    out.push(v.getFloat64(off, le), v.getFloat64(off + 8, le));
    off += 16;
  }
  return n;
}

export interface FlatPolygons {
  length: number;                // polygons
  positions: Float32Array;       // x, y pairs
  startIndices: Uint32Array;     // vertex index where each polygon starts (+ end)
}

export function decodePolygons(geoms: ArrayLike<Uint8Array | null>): FlatPolygons {
  const coords: number[] = [];
  const starts = new Uint32Array(geoms.length + 1);
  let vtx = 0;
  for (let i = 0; i < geoms.length; i++) {
    starts[i] = vtx;
    const g = geoms[i];
    if (g) vtx += appendExteriorRing(g, coords);
  }
  starts[geoms.length] = vtx;
  return { length: geoms.length, positions: Float32Array.from(coords), startIndices: starts };
}
