import { describe, it, expect, vi, afterEach } from 'vitest';
import { rangeBuffer, lz4BlockDecompress } from '../data/parquet.ts';
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

describe('lz4BlockDecompress', () => {
  it('expands literals and a back-reference', () => {
    // token: 3 literals, match length 4+2=6 at offset 3 → "abcabcabc"
    const src = Uint8Array.from([0x32, 97, 98, 99, 3, 0]);
    expect(new TextDecoder().decode(lz4BlockDecompress(src, 9))).toBe('abcabcabc');
  });
});
