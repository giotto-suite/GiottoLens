import { describe, it, expect, vi, afterEach } from 'vitest';
import fs from 'node:fs';
import { tileSource, readTileColumns, setTransfer } from '../data/parquet.ts';
import { decodeTranscriptTile } from '../data/tx-decode.ts';

const buf = fs.readFileSync(new URL('./fixtures/tile.parquet', import.meta.url));
const bytes = new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
const tile = (i: number) => ({ url: `http://h/data/t/${i}.parquet`, file: `http://h/files/t/${i}.parquet`, bytes: bytes.length });
const tick = () => new Promise(r => setTimeout(r, 0));

// A fetch that never answers until aborted, as a slow link looks
const hanging = () => vi.fn((_url: string, opts: any = {}) => new Promise<Response>((_, reject) => {
  opts.signal?.throwIfAborted();
  opts.signal?.addEventListener('abort', () => reject(opts.signal.reason));
}));
const serving = () => vi.fn(async () => new Response(bytes.slice(), { status: 200 }));

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

describe('worker pool abort', () => {
  afterEach(() => { vi.unstubAllGlobals(); vi.resetModules(); });

  it('rejects at once, tells the worker, frees its slot and ignores a late reply', async () => {
    const workers: any[] = [];
    vi.stubGlobal('navigator', { hardwareConcurrency: 2 });   // one worker
    vi.stubGlobal('Worker', class {
      sent: any[] = []; onmessage: any = null;
      constructor() { workers.push(this); }
      postMessage(m: any) { this.sent.push(m); }
    });
    const { fetchTranscriptTile } = await import('../data/tx-pool.js');
    const c = new AbortController();
    const p = fetchTranscriptTile(tile(0), 4, c.signal);
    const w = workers[0];
    const { id } = w.sent.find((m: any) => m.tile);
    expect(w.busy).toBe(1);
    c.abort();
    await expect(p).rejects.toMatchObject({ name: 'AbortError' });
    expect(w.sent).toContainEqual({ type: 'abort', id });
    expect(w.busy).toBe(0);
    w.onmessage({ data: { id, pos: new Float32Array(0), geneIdxs: new Uint16Array(0) } });   // ignored
    expect(w.busy).toBe(0);
    // A normal request still resolves
    const p2 = fetchTranscriptTile(tile(1), 1);
    const { id: id2 } = w.sent.filter((m: any) => m.tile).at(-1);
    w.onmessage({ data: { id: id2, pos: new Float32Array(2), geneIdxs: new Uint16Array(1) } });
    await expect(p2).resolves.toMatchObject({ stride: 1 });
    expect(w.busy).toBe(0);
  });
});
