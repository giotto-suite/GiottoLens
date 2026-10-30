import { describe, it, expect } from 'vitest';
import fs from 'node:fs';
import { parquetMetadataAsync } from 'hyparquet';
import { decodePoints, GENE_NONE, UnsupportedLayout } from '../data/point-decode.ts';
import { readColumns } from '../data/parquet.ts';

const load = (f: string) => { const b = fs.readFileSync(new URL(`./fixtures/${f}`, import.meta.url)); return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength); };

async function reference(ab: ArrayBuffer, genes: Map<string, number>) {
  const c = await readColumns(ab, ['x_index', 'y_index', 'feat_ID']);
  return Array.from(c.x_index, (x: any, i) => [x ?? NaN, c.y_index[i] ?? NaN, c.feat_ID[i] == null ? GENE_NONE : genes.get(c.feat_ID[i]) ?? GENE_NONE]);
}

describe('decodePoints', () => {
  // tile.parquet: arrow writer, dictionary pages, v1, snappy, 3 row groups.
  // tile-plain-v2.parquet: DuckDB writer, v2 pages, nulls, uncompressed.
  for (const file of ['tile.parquet', 'tile-plain-v2.parquet']) {
    it(`matches hyparquet on ${file}, at every stride`, async () => {
      const ab = load(file);
      const md = await parquetMetadataAsync(ab);
      const genes = new Map([['A', 0], ['B', 1]]);   // 'C' is not in the panel
      const ref = await reference(ab, genes);
      for (const stride of [1, 4, 16]) {
        let res;
      try {
        res = await decodePoints((a, b) => ab.slice(a, b), md, genes, stride);
      } catch (e) {
        // An encoding the fast path does not cover must say so (callers fall back)
        expect(e).toBeInstanceOf(UnsupportedLayout);
        return;
      }
      const { pos, geneIdxs } = res;
        const want = ref.filter((_, i) => i % stride === 0);
        expect(geneIdxs.length).toBe(want.length);
        for (let k = 0; k < want.length; k++) {
          const [x, y, g] = want[k];
          if (Number.isNaN(x)) expect(pos[2 * k]).toBeNaN(); else expect(pos[2 * k]).toBeCloseTo(x, 5);
          expect(pos[2 * k + 1]).toBeCloseTo(y, 5);
          expect(geneIdxs[k]).toBe(g);
        }
      }
    });
  }
});

import { readIndicesStrided } from '../data/point-decode.ts';
// @ts-ignore
import { readRleBitPackedHybrid } from 'hyparquet/src/encoding.js';

describe('readIndicesStrided', () => {
  // Hybrid stream: RLE run of 10 × 5, then a bit-packed run of 16 values, width 3
  const vals = [1, 2, 3, 4, 5, 6, 7, 0, 7, 6, 5, 4, 3, 2, 1, 0];
  const packed: number[] = [];
  let acc = 0, bits = 0;
  for (const v of vals) { acc |= v << bits; bits += 3; while (bits >= 8) { packed.push(acc & 0xff); acc >>>= 8; bits -= 8; } }
  if (bits) packed.push(acc & 0xff);
  const bytes = Uint8Array.from([10 << 1, 5, (2 << 1) | 1, ...packed]);
  const all = [...Array(10).fill(5), ...vals];
  it('matches a full decode at any start and stride', () => {
    const full = new Int32Array(all.length);
    readRleBitPackedHybrid({ view: new DataView(bytes.buffer), offset: 0 }, 3, full, bytes.length);
    expect(Array.from(full)).toEqual(all);
    for (const stride of [1, 3, 16]) for (const first of [0, 1, 2]) {
      const want = all.filter((_, i) => i >= first && (i - first) % stride === 0);
      const out = new Int32Array(want.length);
      readIndicesStrided(bytes, 0, bytes.length, 3, all.length, first, stride, out);
      expect(Array.from(out)).toEqual(want);
    }
  });
});
