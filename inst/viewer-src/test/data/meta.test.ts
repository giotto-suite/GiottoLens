import { describe, it, expect, beforeEach, vi } from 'vitest';
import { fixtureBuffer } from '../helpers.ts';

// Column files by URL, served by a stubbed fetch that counts requests
const files: Record<string, string> = {
  'session/metadata/score-a.parquet': 'meta_dbl.parquet',
  'session/metadata/lab-b.parquet': 'meta_codes.parquet',
  'session/metadata/score-c.parquet': 'meta_dbl.parquet',
};
const fetched: string[] = [];
vi.stubGlobal('document', { baseURI: 'http://lens/' });
vi.stubGlobal('fetch', async (url: string) => {
  const path = url.replace('http://lens/', '');
  fetched.push(path);
  if (!files[path]) return { ok: false, status: 404 };
  return { ok: true, status: 200, arrayBuffer: async () => fixtureBuffer(files[path]) };
});

const { state } = await import('../../core/state.js');
const meta = await import('../../data/meta.ts');
const score = { name: 'score', kind: 'continuous' as const, numeric: true, url: 'session/metadata/score-a.parquet' };
const lab = { name: 'lab', kind: 'categorical' as const, levels: ['x', 'y'], url: 'session/metadata/lab-b.parquet' };

describe('metadata columns load on demand', () => {
  beforeEach(() => {
    fetched.length = 0;
    state.cells = { n: 4 };
    state.meta = null; state.metaInfo = null;
    meta.setMetaInfo([]);
  });

  it('lists every column and loads none until asked', async () => {
    expect(meta.setMetaInfo([score, lab])).toBe(true);
    expect(meta.setMetaInfo([score, lab])).toBe(false);          // a reconnect re-sends it
    expect([...state.metaInfo.keys()]).toEqual(['score', 'lab']);
    expect(state.meta.size).toBe(0);
    expect(meta.metaColumn('score')).toBeUndefined();            // starts the load
    await meta.needColumns(['score', 'score']);
    const c = state.meta.get('score');
    expect([...c.values]).toEqual([1.5, NaN, -2, 4]);
    expect([c.min, c.max]).toEqual([-2, 4]);
    expect(fetched).toEqual(['session/metadata/score-a.parquet']);   // one request
    await meta.needColumns(['lab', 'nope']);
    expect([...state.meta.get('lab').values]).toEqual([0, 1, -1, 0]);
    expect(meta.metaValue(state.meta.get('lab'), 1)).toBe('y');
  });

  it('keeps loaded columns whose file is unchanged across payloads', async () => {
    meta.setMetaInfo([score, lab]);
    await meta.needColumns(['score', 'lab']);
    const before = state.meta.get('lab');
    meta.setMetaInfo([score, { ...lab, levels: ['p', 'q'] }]);
    expect(state.meta.get('score')).toBeDefined();
    expect(state.meta.get('lab')).not.toBe(before);              // new levels, same values
    expect(state.meta.get('lab').values).toBe(before.values);
    expect(meta.metaValue(state.meta.get('lab'), 1)).toBe('q');
    meta.setMetaInfo([{ ...score, url: 'session/metadata/score-c.parquet' }, lab]);
    expect(state.meta.has('score')).toBe(false);                 // a new file loads again
  });

  it('prefetches the rest only within the budget', async () => {
    meta.setMetaInfo([score, lab]);
    await meta.prefetchColumns();
    expect(meta.prefetchState()).toBe('done');
    expect(state.meta.size).toBe(2);

    state.cells = { n: meta.META_CACHE_BYTES };                    // 8 bytes a cell for score alone
    meta.setMetaInfo([score, { ...lab, url: 'session/metadata/score-c.parquet' }]);
    fetched.length = 0;
    await meta.prefetchColumns();
    expect(meta.prefetchState()).toBe('over');
    expect(fetched).toEqual([]);
  });

  it('tells loaded columns when one arrives', async () => {
    meta.setMetaInfo([score]);
    const seen = vi.fn();
    const off = meta.onColumnsLoaded(seen);
    await meta.needColumns(['score']);
    off();
    expect(seen).toHaveBeenCalledTimes(1);
  });
});

describe('loaded columns over the budget', () => {
  const other = { ...score, name: 'other', url: 'session/metadata/score-c.parquet' };
  beforeEach(async () => {
    state.cells = { n: 4 };
    state.meta = null; state.metaInfo = null;
    meta.setMetaInfo([]);
    meta.setMetaInfo([score, lab, other]);
    await meta.needColumns(['score']);
    await meta.needColumns(['lab']);
    await meta.needColumns(['other']);
  });

  it('drops the least recently used until the rest fit', () => {
    meta.metaColumn('score');                                    // used last: kept
    meta.evictColumns(40);                                       // 32 + 16 + 32 bytes loaded
    expect([...state.meta.keys()]).toEqual(['score']);
    expect(meta.metaColumn('lab')).toBeUndefined();              // loads again when asked
  });

  it('never drops a pinned column or the one just loaded', () => {
    const unpin = meta.pinColumns(() => ['lab']);
    meta.evictColumns(0, 'other');
    expect([...state.meta.keys()].sort()).toEqual(['lab', 'other']);
    unpin();
    meta.evictColumns(0);
    expect(state.meta.size).toBe(0);
  });

  it('reads pins at each eviction', () => {
    let shown = 'score';
    const unpin = meta.pinColumns(() => [shown]);
    shown = 'other';
    meta.evictColumns(0);
    unpin();
    expect([...state.meta.keys()]).toEqual(['other']);
  });
});
