import { describe, it, expect, vi, afterEach } from 'vitest';
import fs from 'node:fs';
import { readTileColumns, setTransfer, transferMode, mergedRanges, readColumns } from '../data/parquet.ts';

const buf = fs.readFileSync(new URL('./fixtures/tile.parquet', import.meta.url));
const bytes = new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
const COLS = ['x_index', 'y_index', 'feat_ID'];

function server() {
  const calls: { url: string; range?: string }[] = [];
  const f = vi.fn(async (url: string, opts: any = {}) => {
    const range = opts.headers?.Range;
    calls.push({ url, range });
    if (!range) return new Response(bytes.slice(), { status: 200 });
    const [, a, b] = range.match(/bytes=(\d+)-(\d+)/);
    return new Response(bytes.slice(+a, +b + 1), { status: 206,
      headers: { 'content-range': `bytes ${a}-${b}/${bytes.length}` } });
  });
  return { f, calls };
}

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
