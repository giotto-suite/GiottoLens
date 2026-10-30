import { describe, it, expect, vi, afterEach } from 'vitest';
import { rangeBuffer, readColumns, compressors } from '../data/parquet.ts';
import fs from 'node:fs';
import { parquetMetadataAsync } from 'hyparquet';
import { decodePoints } from '../data/point-decode.ts';
import { visibleTiles } from '../data/tiles.js';

describe('visibleTiles', () => {
  const tiles = [
    { index: 1, xmin: 0, xmax: 10, ymin: 0, ymax: 10 },
    { index: 2, xmin: 100, xmax: 110, ymin: 0, ymax: 10 },
  ];
  it('uses the given viewport size, not the window', () => {
    const vs = { target: [5, 5], zoom: 0 };   // 1 px per unit
    expect(visibleTiles(vs, tiles, { width: 20, height: 20 }).map((t: any) => t.index)).toEqual([1]);
    expect(visibleTiles(vs, tiles, { width: 220, height: 20 }).map((t: any) => t.index)).toEqual([1, 2]);
  });
});

describe('rangeBuffer', () => {
  afterEach(() => vi.unstubAllGlobals());
  const bytes = Uint8Array.from({ length: 100 }, (_, i) => i);
  const server = ({ range = true } = {}) => vi.fn(async (_url: string, opts: any = {}) => {
    const h = opts.headers?.Range;
    if (!h || !range) return new Response(bytes.slice(), { status: 200 });
    const [, a, b] = h.match(/bytes=(\d+)-(\d+)/);
    return new Response(bytes.slice(+a, +b + 1), {
      status: 206, headers: { 'content-range': `bytes ${a}-${b}/${bytes.length}` },
    });
  });

  it('reads slices with the known size and no probe', async () => {
    const f = server(); vi.stubGlobal('fetch', f);
    const file = await rangeBuffer('u', 100);
    expect(f).not.toHaveBeenCalled();
    expect([...new Uint8Array(await file.slice(10, 14))]).toEqual([10, 11, 12, 13]);
  });

  it('probes for the size when the manifest has none', async () => {
    vi.stubGlobal('fetch', server());
    expect((await rangeBuffer('u')).byteLength).toBe(100);
  });

  it('falls back to one full download when the server ignores Range', async () => {
    const f = server({ range: false }); vi.stubGlobal('fetch', f);
    const file = await rangeBuffer('u');
    expect([...new Uint8Array(await file.slice(98))]).toEqual([98, 99]);
    expect(f).toHaveBeenCalledTimes(1);
  });

  it('fails loudly when a slice comes back as 200', async () => {
    vi.stubGlobal('fetch', server({ range: false }));
    const file = await rangeBuffer('u', 100);
    await expect(file.slice(0, 4)).rejects.toThrow(/not 206/);
  });

  it('keeps at most six requests in flight', async () => {
    let inflight = 0, peak = 0;
    vi.stubGlobal('fetch', vi.fn(async () => {
      inflight++; peak = Math.max(peak, inflight);
      await new Promise(r => setTimeout(r, 5));
      inflight--;
      return new Response(new Uint8Array(1), { status: 206 });
    }));
    const file = await rangeBuffer('u', 100);
    await Promise.all(Array.from({ length: 20 }, (_, i) => file.slice(i, i + 1)));
    expect(peak).toBe(6);
  });
});

describe('codecs', () => {
  const load = (f: string) => { const b = fs.readFileSync(new URL(`./fixtures/${f}`, import.meta.url)); return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength); };
  const genes = new Map([['A', 0], ['B', 1], ['C', 2], ['D', 3]]);

  // arrow writes "lz4" as LZ4_RAW; GiottoDisk's zarr converter writes ZSTD
  it('reads ZSTD, GZIP and LZ4_RAW like SNAPPY, in hyparquet and the point decoder', async () => {
    const ref = await readColumns(load('codec-snappy.parquet'), ['x_index', 'y_index', 'feat_ID']);
    for (const [file, codec] of [['codec-zstd.parquet', 'ZSTD'], ['codec-gzip.parquet', 'GZIP'], ['codec-lz4.parquet', 'LZ4_RAW']]) {
      const ab = load(file);
      const md: any = await parquetMetadataAsync(ab);
      expect(md.row_groups[0].columns[0].meta_data.codec).toBe(codec);
      const c = await readColumns(ab, ['x_index', 'y_index', 'feat_ID'], md);
      expect(Array.from(c.x_index)).toEqual(Array.from(ref.x_index));
      expect(Array.from(c.feat_ID)).toEqual(Array.from(ref.feat_ID));
      const p = await decodePoints((a, b) => ab.slice(a, b), md, genes, 1);
      expect(p.geneIdxs.length).toBe(ref.x_index.length);
      for (let i = 0; i < p.geneIdxs.length; i += 37) {
        expect(p.pos[2 * i]).toBeCloseTo(ref.x_index[i], 4);
        expect(p.geneIdxs[i]).toBe(genes.get(ref.feat_ID[i]));
      }
    }
  });

  // Issue #2: Hadoop-framed LZ4 with more than one frame per page
  it('decodes Hadoop LZ4 pages with several frames', () => {
    // A literal-only LZ4 block: token (n << 4), then n bytes
    const block = (s: string) => Uint8Array.from([s.length << 4, ...new TextEncoder().encode(s)]);
    const frame = (s: string) => {
      const b = block(s), out = new Uint8Array(8 + b.length), v = new DataView(out.buffer);
      v.setUint32(0, s.length, false); v.setUint32(4, b.length, false); out.set(b, 8);
      return out;
    };
    const page = Uint8Array.from([...frame('abc'), ...frame('defg')]);
    expect(new TextDecoder().decode((compressors as any).LZ4(page, 7))).toBe('abcdefg');
  });
});
