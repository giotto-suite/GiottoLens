import { describe, it, expect, vi, afterEach } from 'vitest';
import { fixtureBytes } from '../helpers.ts';

const bytes = fixtureBytes('tile.parquet');
const tile = (i: number) => ({ url: `http://h/data/t/${i}.parquet`, file: `http://h/files/t/${i}.parquet`, bytes: bytes.length });

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
    const { fetchTranscriptTile } = await import('../../data/tx-pool.js');
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
