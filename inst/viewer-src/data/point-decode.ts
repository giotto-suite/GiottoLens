// Fast decoder for the three columns the viewer draws from a transcript tile
// (x, y, gene), straight into typed arrays, optionally keeping every
// `stride`-th row. hyparquet materialises every row of every column as JS
// values; here dictionary-encoded columns are decoded as integer indices and
// only the kept rows are looked up, and gene names are mapped to gene indices
// once per dictionary entry rather than once per row.
//
// Handles flat (non-nested) columns, PLAIN, dictionary or (numbers)
// BYTE_STREAM_SPLIT encoded, in v1 or v2 data pages, with any codec in
// data/parquet.ts `compressors`. Anything else throws
// UnsupportedLayout and the caller falls back to hyparquet.
// @ts-ignore: hyparquet internals have no type exports
import { deserializeTCompactProtocol } from 'hyparquet/src/thrift.js';
// @ts-ignore
import { readRleBitPackedHybrid } from 'hyparquet/src/encoding.js';
import { compressors } from './parquet.ts';

export class UnsupportedLayout extends Error {}

export const GENE_NONE = 0xffff;

type Kind = 'double' | 'float' | 'string';
interface Column {
  name: string;
  kind: Kind;
  optional: boolean;
}

const TYPE_KIND: Record<number, Kind> = { 5: 'double', 4: 'float', 6: 'string' }; // parquet physical types

function columnInfo(metadata: any, name: string): Column {
  const el = metadata.schema.find((e: any) => e.name === name && !e.num_children);
  if (!el) throw new UnsupportedLayout(`no column ${name}`);
  const t = typeof el.type === 'string'
    ? ({ DOUBLE: 'double', FLOAT: 'float', BYTE_ARRAY: 'string' } as Record<string, Kind>)[el.type]
    : TYPE_KIND[el.type];
  if (!t) throw new UnsupportedLayout(`${name}: type ${el.type}`);
  const rep = el.repetition_type;
  if (rep === 'REPEATED' || rep === 2) throw new UnsupportedLayout(`${name}: repeated`);
  return { name, kind: t, optional: rep === 'OPTIONAL' || rep === 1 };
}

function decompress(bytes: Uint8Array, size: number, codec: string): Uint8Array {
  if (codec === 'UNCOMPRESSED') return bytes;
  const fn = (compressors as Record<string, ((b: Uint8Array, n: number) => Uint8Array) | undefined>)[codec];
  if (!fn) throw new UnsupportedLayout(`codec ${codec}`);
  return fn(bytes, size);
}

// Decoded dictionary: numbers for coordinates, gene indices for names
type Dict = Float64Array | Float32Array | Uint16Array;

// Coordinate dictionaries are nearly as long as the column (coordinates rarely
// repeat), so they are viewed in place, not copied: only looked-up entries are
// ever read. Parquet is little-endian, as are the platforms browsers run on.
function readDictionary(page: Uint8Array, n: number, col: Column, genes: Map<string, number>): Dict | Float32Array {
  const w = col.kind === 'double' ? 8 : 4;
  if (col.kind !== 'string') {
    const bytes = page.byteOffset % w === 0 ? page : page.slice();   // typed views need alignment
    return col.kind === 'double'
      ? new Float64Array(bytes.buffer, bytes.byteOffset, n)
      : new Float32Array(bytes.buffer, bytes.byteOffset, n);
  }
  const v = new DataView(page.buffer, page.byteOffset, page.byteLength);
  const dec = new TextDecoder();
  const d = new Uint16Array(n);
  let off = 0;
  for (let i = 0; i < n; i++) {
    const len = v.getUint32(off, true); off += 4;
    d[i] = genes.get(dec.decode(page.subarray(off, off + len))) ?? GENE_NONE;
    off += len;
  }
  return d;
}

// Dictionary indices of the values at positions first, first + stride, … (<
// n) from an RLE / bit-packed hybrid run sequence, without unpacking the rest:
// a bit-packed run has a fixed width, so any position is computed directly.
export function readIndicesStrided(bytes: Uint8Array, offset: number, end: number, width: number,
                                   n: number, first: number, stride: number, out: Int32Array): void {
  const mask = width === 32 ? 0xffffffff : (1 << width) - 1;
  let pos = 0, next = first, k = 0;
  while (pos < n && offset < end && next < n) {
    // varint run header
    let header = 0, shift = 0, b;
    do { b = bytes[offset++]; header |= (b & 0x7f) << shift; shift += 7; } while (b & 0x80);
    if (header & 1) {                                   // bit-packed: (header >> 1) groups of 8
      const count = (header >>> 1) * 8;
      const base = offset;
      while (next < pos + count && next < n) {
        const bit = (next - pos) * width;
        let byte = base + (bit >>> 3);
        const sh = bit & 7;
        // little-endian bit order; gather enough bytes for width + shift bits
        let v = bytes[byte] >>> sh, got = 8 - sh;
        while (got < width) { v |= bytes[++byte] << got; got += 8; }
        out[k++] = (v & mask) >>> 0;
        next += stride;
      }
      offset = base + ((count * width) >>> 3);
      pos += count;
    } else {                                            // RLE: one value repeated
      const count = header >>> 1;
      let v = 0;
      for (let i = 0, nb = (width + 7) >>> 3; i < nb; i++) v |= bytes[offset++] << (i * 8);
      while (next < pos + count && next < n) { out[k++] = v; next += stride; }
      pos += count;
    }
  }
}

// Writes the kept rows of one column chunk into `out` starting at `outPos`.
// `rowStart`: tile row of the chunk's first row. Returns rows kept.
function decodeChunk(chunk: Uint8Array, meta: any, col: Column, stride: number, rowStart: number,
                     genes: Map<string, number>, out: Float32Array | Uint16Array, outStep: number, outPos: number): number {
  const reader = { view: new DataView(chunk.buffer, chunk.byteOffset, chunk.byteLength), offset: 0 };
  const codec = String(meta.codec);
  const nRows = Number(meta.num_values);
  let dict: Dict | null = null;
  let row = 0;        // row within the chunk
  let kept = 0;
  const isGene = col.kind === 'string';
  const missing = isGene ? GENE_NONE : NaN;

  while (row < nRows && reader.offset < chunk.byteLength) {
    const h = deserializeTCompactProtocol(reader);
    const type = h.field_1, usize = h.field_2, csize = h.field_3;
    const body = chunk.subarray(reader.offset, reader.offset + csize);
    reader.offset += csize;

    if (type === 2) {                                   // dictionary page (PLAIN)
      dict = readDictionary(decompress(body, usize, codec), h.field_7.field_1, col, genes);
      continue;
    }
    if (type !== 0 && type !== 3) continue;             // index pages etc.

    let page: Uint8Array, nValues: number, encoding: number, defBytes: Uint8Array | null = null;
    if (type === 0) {                                   // data page v1
      page = decompress(body, usize, codec);
      nValues = h.field_5.field_1; encoding = h.field_5.field_2;
    } else {                                            // data page v2: levels are uncompressed
      const d = h.field_8;
      nValues = d.field_1; encoding = d.field_4;
      const defLen = d.field_5 ?? 0, repLen = d.field_6 ?? 0;
      if (repLen) throw new UnsupportedLayout('repetition levels');
      defBytes = body.subarray(0, defLen);
      const rest = body.subarray(defLen);
      page = d.field_7 === false ? rest : decompress(rest, usize - defLen, codec);
    }
    const pv = { view: new DataView(page.buffer, page.byteOffset, page.byteLength), offset: 0 };

    // definition levels → which rows have a value
    let defs: Uint8Array | null = null;
    if (col.optional) {
      defs = new Uint8Array(nValues);
      if (defBytes) readRleBitPackedHybrid({ view: new DataView(defBytes.buffer, defBytes.byteOffset, defBytes.byteLength), offset: 0 }, 1, defs, defBytes.byteLength);
      else readRleBitPackedHybrid(pv, 1, defs);
      let all = true;
      for (let i = 0; i < nValues; i++) if (!defs[i]) { all = false; break; }
      if (all) defs = null;
    }
    let nNonNull = nValues;
    if (defs) { nNonNull = 0; for (let i = 0; i < nValues; i++) nNonNull += defs[i]; }

    // Fast path, no nulls in the page: touch only the kept rows
    const first = ((stride - (rowStart + row) % stride) % stride);
    if (!defs && (encoding === 8 || encoding === 2)) {
      if (!dict) throw new UnsupportedLayout('dictionary page missing');
      const width = pv.view.getUint8(pv.offset++);
      const m = first < nValues ? Math.ceil((nValues - first) / stride) : 0;
      const sel = new Int32Array(m);
      if (width) readIndicesStrided(page, pv.offset, page.byteLength, width, nValues, first, stride, sel);
      const d = dict;
      for (let j = 0; j < m; j++) out[(outPos + kept + j) * outStep] = d[sel[j]];
      kept += m;
      row += nValues;
      continue;
    }

    // values: dictionary indices (8 = RLE_DICTIONARY, 2 = PLAIN_DICTIONARY) or PLAIN (0)
    let idx: Int32Array | null = null, plain: DataView | null = null, plainStrings: Uint16Array | null = null;
    if (encoding === 8 || encoding === 2) {
      if (!dict) throw new UnsupportedLayout('dictionary page missing');
      const width = pv.view.getUint8(pv.offset++);
      idx = new Int32Array(nNonNull);
      if (width) readRleBitPackedHybrid(pv, width, idx, page.byteLength - pv.offset);
    } else if (encoding === 9 && !isGene) {           // BYTE_STREAM_SPLIT: byte k of every value, then k + 1
      const w = col.kind === 'double' ? 8 : 4;
      const src = page.subarray(pv.offset, pv.offset + w * nNonNull);
      const joined = new Uint8Array(w * nNonNull);
      for (let k = 0; k < w; k++) for (let i = 0; i < nNonNull; i++) joined[i * w + k] = src[k * nNonNull + i];
      plain = new DataView(joined.buffer);
    } else if (encoding === 0) {
      if (isGene) {
        plainStrings = readDictionary(page.subarray(pv.offset), nNonNull, col, genes) as Uint16Array;
      } else {
        plain = new DataView(page.buffer, page.byteOffset + pv.offset, page.byteLength - pv.offset);
      }
    } else {
      throw new UnsupportedLayout(`encoding ${encoding}`);
    }

    // keep every stride-th tile row
    let vi = 0;   // index into non-null values
    for (let i = 0; i < nValues; i++, row++) {
      const has = !defs || defs[i] === 1;
      if ((rowStart + row) % stride === 0) {
        let x: number = missing;
        if (has) {
          if (idx) x = (dict as Dict)[idx[vi]];
          else if (plainStrings) x = plainStrings[vi];
          else x = col.kind === 'double' ? plain!.getFloat64(vi * 8, true) : plain!.getFloat32(vi * 4, true);
        }
        out[(outPos + kept) * outStep] = x;
        kept++;
      }
      if (has) vi++;
    }
  }
  return kept;
}

export interface PointColumns { x: string; y: string; gene: string }

// Decode a tile's points. `read(start, end)` returns the bytes of a range
// (whole-file buffer or merged Range reads); `metadata` from hyparquet.
export async function decodePoints(
  read: (start: number, end: number) => Promise<ArrayBuffer> | ArrayBuffer,
  metadata: any, genes: Map<string, number>, stride = 1,
  names: PointColumns = { x: 'x_index', y: 'y_index', gene: 'feat_ID' },
): Promise<{ pos: Float32Array; geneIdxs: Uint16Array }> {
  const cols = { x: columnInfo(metadata, names.x), y: columnInfo(metadata, names.y), gene: columnInfo(metadata, names.gene) };
  const total = Number(metadata.num_rows);
  const m = Math.ceil(total / stride);
  const pos = new Float32Array(m * 2);
  const geneIdxs = new Uint16Array(m);
  // Interleaved x/y: write x at 2k and y at 2k + 1 via two views over pos
  const posY = new Float32Array(pos.buffer, 4);

  let rowStart = 0, outPos = 0;
  for (const rg of metadata.row_groups) {
    let kept = 0;
    for (const [key, col] of Object.entries(cols) as [keyof typeof cols, Column][]) {
      const chunk = rg.columns.find((c: any) => c.meta_data.path_in_schema[0] === col.name)?.meta_data;
      if (!chunk) throw new UnsupportedLayout(`no chunk for ${col.name}`);
      const start = Number(chunk.dictionary_page_offset || chunk.data_page_offset);
      const bytes = new Uint8Array(await read(start, start + Number(chunk.total_compressed_size)));
      const out = key === 'gene' ? geneIdxs : key === 'x' ? pos : posY;
      kept = decodeChunk(bytes, chunk, col, stride, rowStart, genes, out, key === 'gene' ? 1 : 2, outPos);
    }
    rowStart += Number(rg.num_rows);
    outPos += kept;
  }
  return { pos: outPos * 2 === pos.length ? pos : pos.slice(0, outPos * 2), geneIdxs: outPos === m ? geneIdxs : geneIdxs.slice(0, outPos) };
}
