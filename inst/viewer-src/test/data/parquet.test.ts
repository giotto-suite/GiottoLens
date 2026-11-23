import { describe, it, expect, vi, afterEach } from 'vitest';
import { rangeBuffer, readColumns, compressors, tileSource, readTileColumns, setTransfer, transferMode, mergedRanges } from '../../data/parquet.ts';
import { parquetMetadataAsync } from 'hyparquet';
import { decodeTranscriptTile } from '../../data/tx-decode.ts';
import { fixtureBuffer, fixtureBytes, rangeServer, tick } from '../helpers.ts';

const bytes = fixtureBytes('tile.parquet');

describe('rangeBuffer', () => {
  afterEach(() => vi.unstubAllGlobals());
  const bytes = Uint8Array.from({ length: 100 }, (_, i) => i);
  const server = ({ range = true } = {}) => rangeServer(bytes, { range }).f;

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
});

describe('codecs', () => {
  const load = fixtureBuffer;

  // arrow writes "lz4" as LZ4_RAW; GiottoDisk's zarr converter writes ZSTD.
  // decodePoints on these files: data/point-decode.test.ts
  it('reads ZSTD, GZIP and LZ4_RAW like SNAPPY', async () => {
    const ref = await readColumns(load('codec-snappy.parquet'), ['x_index', 'y_index', 'feat_ID']);
    for (const [file, codec] of [['codec-zstd.parquet', 'ZSTD'], ['codec-gzip.parquet', 'GZIP'], ['codec-lz4.parquet', 'LZ4_RAW']]) {
      const ab = load(file);
      const md: any = await parquetMetadataAsync(ab);
      expect(md.row_groups[0].columns[0].meta_data.codec).toBe(codec);
      const c = await readColumns(ab, ['x_index', 'y_index', 'feat_ID'], md);
      expect(Array.from(c.x_index)).toEqual(Array.from(ref.x_index));
      expect(Array.from(c.feat_ID)).toEqual(Array.from(ref.feat_ID));
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

describe('readColumns', () => {
  it('joins row groups in order', async () => {
    const x = (await readColumns(fixtureBuffer('rowgroups.parquet'), ['x'])).x;   // 3 row groups
    expect(Array.from(x)).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  });
});

const COLS = ['x_index', 'y_index', 'feat_ID'];

const server = () => rangeServer(bytes);

describe('tile transfer modes', () => {
  afterEach(() => { vi.unstubAllGlobals(); setTransfer('auto'); });
  const tile = { url: 'http://h/lens/data/t/part-0.parquet', file: 'http://h/lens/files/t/part-0.parquet', bytes: bytes.length };

  it('whole: one request for the file, same values', async () => {
    const { f, calls } = server(); vi.stubGlobal('fetch', f);
    setTransfer('whole');
    const cols = await readTileColumns(tile, COLS);
    expect(calls).toEqual([{ url: tile.file, range: undefined }]);
    const ref = await readColumns(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength), COLS);
    expect(Array.from(cols.x_index)).toEqual(Array.from(ref.x_index));
    expect(Array.from(cols.feat_ID)).toEqual(Array.from(ref.feat_ID));
  });

  it('columns: footer plus merged ranges, never the whole file', async () => {
    const { f, calls } = server(); vi.stubGlobal('fetch', f);
    setTransfer('columns');
    const cols = await readTileColumns(tile, COLS);
    expect(cols.x_index.length).toBe(3000);
    expect(calls.every(c => c.url === tile.url && c.range)).toBe(true);
    // 3 row groups × 3 columns = 9 blocks; merged into far fewer requests
    expect(calls.length).toBeLessThanOrEqual(1 + 3);
  });

  it('mergedRanges merges blocks closer than the gap and keeps distant ones apart', () => {
    const md = { row_groups: [{ columns: [
      { meta_data: { path_in_schema: ['a'], data_page_offset: 100, total_compressed_size: 50 } },
      { meta_data: { path_in_schema: ['skip'], data_page_offset: 150, total_compressed_size: 10_000 } },
      { meta_data: { path_in_schema: ['b'], data_page_offset: 10_150, total_compressed_size: 50, dictionary_page_offset: 10_140 } },
    ] }] };
    expect(mergedRanges(md, ['a', 'b'], 20_000)).toEqual([[100, 10_190]]);
    expect(mergedRanges(md, ['a', 'b'], 100)).toEqual([[100, 150], [10_140, 10_190]]);
  });

  it('auto uses columns off localhost', () => {
    setTransfer('auto');
    expect(transferMode()).toBe('columns');   // no localhost in the test runner
  });
});

const tile = (i: number) => ({ url: `http://h/data/t/${i}.parquet`, file: `http://h/files/t/${i}.parquet`, bytes: bytes.length });

// A fetch that never answers until aborted, as a slow link looks
const hanging = () => vi.fn((_url: string, opts: any = {}) => new Promise<Response>((_, reject) => {
  opts.signal?.throwIfAborted();
  opts.signal?.addEventListener('abort', () => reject(opts.signal.reason));
}));
const serving = () => rangeServer(bytes, { range: false }).f;

describe('aborting tile loads', () => {
  afterEach(() => { vi.unstubAllGlobals(); setTransfer('auto'); });

  it('a load aborted while queued never fetches, and aborts free every slot', async () => {
    const f = hanging(); vi.stubGlobal('fetch', f);
    setTransfer('whole');
    const ctls = Array.from({ length: 8 }, () => new AbortController());
    const loads = ctls.map((c, i) => tileSource(tile(i), ['x_index'], c.signal).catch(e => e));
    await tick();
    expect(f).toHaveBeenCalledTimes(6);            // the request limit
    ctls[7].abort(); ctls[6].abort();               // queued
    await tick();
    expect(f).toHaveBeenCalledTimes(6);
    ctls.slice(0, 6).forEach(c => c.abort());       // in flight
    const errs = await Promise.all(loads);
    expect(errs.every(e => e?.name === 'AbortError')).toBe(true);
    // Slots were released: a new load goes straight through
    vi.stubGlobal('fetch', serving());
    const cols = await readTileColumns(tile(9), ['x_index']);
    expect(cols.x_index.length).toBe(3000);
  });

  it('an aborted queued load does not take a slot handed out later', async () => {
    const f = hanging(); vi.stubGlobal('fetch', f);
    setTransfer('whole');
    const first = Array.from({ length: 6 }, () => new AbortController());
    const held = first.map((c, i) => tileSource(tile(i), ['x_index'], c.signal).catch(e => e));
    const queued = new AbortController();
    const q = tileSource(tile(6), ['x_index'], queued.signal).catch(e => e);
    const next = new AbortController();
    const n = tileSource(tile(7), ['x_index'], next.signal).catch(e => e);
    await tick();
    queued.abort();
    first[0].abort();                                // frees one slot: it goes to `next`
    await tick();
    expect(f).toHaveBeenCalledTimes(7);
    expect(f.mock.calls[6][0]).toBe(tile(7).file);
    [...first, next].forEach(c => c.abort());
    await Promise.all([...held, q, n]);
  });

  it('decodeTranscriptTile with an aborted signal rejects without fetching', async () => {
    const f = serving(); vi.stubGlobal('fetch', f);
    setTransfer('whole');
    const c = new AbortController(); c.abort();
    await expect(decodeTranscriptTile(tile(0), new Map(), 1, c.signal)).rejects.toMatchObject({ name: 'AbortError' });
    expect(f).not.toHaveBeenCalled();
  });
});
