// Cell metadata pushed from R: one file per column, in cell order, so a column
// is one typed array indexed by cell. Categorical columns arrive as 0-based
// codes (-1 = NA) plus levels.
//
// state.metaInfo lists every column (what exists and its type, from the
// payload); state.meta holds the columns loaded so far. A column loads when
// something needs it (metaColumn(), needColumns()); after a payload, the rest
// load in the background while all columns fit META_CACHE_BYTES, so typical
// datasets end up fully loaded. Above that, loaded columns are dropped least
// recently used first until they fit, except those pinned: what something
// shows (colour-by, rules, chart axes, the table's columns in view), each
// consumer naming its own with pinColumns().
import { dataUrl } from '../core/base.ts';
import { state } from '../core/state.js';
import { readColumns } from './parquet.ts';

export interface MetaInfo {
  name: string;
  kind: 'categorical' | 'continuous';
  levels?: string[];
  numeric?: boolean;                   // a numeric column in R (type can change)
  numberText?: boolean;                // text whose values are all numbers (can go continuous)
  url: string;                         // its file, named by its content
}

export interface MetaColumn extends Omit<MetaInfo, 'url'> {
  url?: string;
  values: Int32Array | Float64Array;   // codes or numbers (NaN = NA)
  min: number;
  max: number;
}

export type Meta = Map<string, MetaColumn>;

export const META_CACHE_BYTES = 256 * 2 ** 20;
const PREFETCH_CONCURRENCY = 3;

const loading = new Map<string, Promise<void>>();   // url → load in flight
const loadedHooks = new Set<() => void>();
const pinSources = new Set<() => Iterable<string>>();
const used = new Map<string, number>();              // column → last use, for eviction
let clock = 0;
let prefetch: 'idle' | 'loading' | 'done' | 'over' = 'idle';
let payloadGen = 0;

// Adopt a load_metadata payload. Loaded columns whose file is unchanged are
// kept. Returns false for the payload already adopted (a reconnect re-sends it).
let payloadKey: string | null = null;
export function setMetaInfo(columns: (MetaInfo & { number_text?: boolean })[]): boolean {
  const key = JSON.stringify(columns);
  if (key === payloadKey) return false;
  payloadKey = key;
  payloadGen++;
  const old: Meta = state.meta ?? new Map();
  const info = new Map<string, MetaInfo>();
  const meta: Meta = new Map();
  for (const c of columns) {
    const m: MetaInfo = { name: c.name, kind: c.kind, levels: c.levels, numeric: !!c.numeric,
      numberText: !!c.number_text, url: c.url };
    info.set(c.name, m);
    const prev = [...old.values()].find(o => o.url === c.url);
    if (prev) meta.set(c.name, sameInfo(prev, m) ? prev : { ...prev, ...m });
  }
  state.metaInfo = info;
  state.meta = meta;
  for (const k of used.keys()) if (!meta.has(k)) used.delete(k);
  prefetch = 'idle';
  return true;
}

const sameInfo = (a: Omit<MetaInfo, 'url'>, b: MetaInfo) => a.name === b.name && a.kind === b.kind &&
  !!a.numeric === !!b.numeric && JSON.stringify(a.levels ?? null) === JSON.stringify(b.levels ?? null);

// A loaded column, or undefined while it loads (the load starts here)
export function metaColumn(name: string): MetaColumn | undefined {
  const c = state.meta?.get(name);
  if (c) used.set(name, ++clock);
  else if (state.metaInfo?.has(name)) void needColumns([name]);   // never rejects
  return c;
}

// Resolves once the columns that exist are loaded
export function needColumns(names: string[]): Promise<void> {
  const want = names.map(n => state.metaInfo?.get(n)).filter((m): m is MetaInfo => !!m && !state.meta?.has(m.name));
  return Promise.allSettled(want.map(load)).then(() => undefined);
}

// Run `fn` whenever a column finishes loading (the tooltip); returns an unsubscribe
export function onColumnsLoaded(fn: () => void): () => void {
  loadedHooks.add(fn);
  return () => loadedHooks.delete(fn);
}

// Columns `fn` returns are never dropped; returns an unpin. `fn` is read at
// each eviction, so it names what the consumer shows then.
export function pinColumns(fn: () => Iterable<string>): () => void {
  pinSources.add(fn);
  return () => pinSources.delete(fn);
}

// Least recently used first, never a pinned column nor `fresh` (the one just
// loaded, which its caller is about to read), until the rest fit
export function evictColumns(cap = META_CACHE_BYTES, fresh?: string): void {
  const meta = state.meta;
  if (!meta) return;
  let total = 0;
  for (const c of meta.values()) total += c.values.byteLength;
  if (total <= cap) return;
  const keep = new Set<string>(fresh == null ? [] : [fresh]);
  for (const fn of pinSources) for (const k of fn()) keep.add(k);
  const order = [...meta.keys()].filter(k => !keep.has(k))
    .sort((a, b) => (used.get(a) ?? 0) - (used.get(b) ?? 0));
  for (const k of order) {
    if (total <= cap) break;
    total -= meta.get(k)!.values.byteLength;
    meta.delete(k);
    used.delete(k);
  }
}

// Whether columns not loaded yet are on their way: 'loading' while the
// background load runs, 'over' when all columns do not fit the budget
export function prefetchState() { return prefetch; }

// After a payload, once the columns asked for have loaded: the rest, while
// all columns fit the budget
export async function prefetchColumns(): Promise<void> {
  const info = [...(state.metaInfo?.values() ?? [])] as MetaInfo[];
  const n = state.cells?.n ?? 0;
  const bytes = info.reduce((s, c) => s + n * (c.kind === 'categorical' ? 4 : 8), 0);
  if (bytes > META_CACHE_BYTES) { prefetch = 'over'; return; }
  const gen = payloadGen;
  prefetch = 'loading';
  await Promise.allSettled([...loading.values()]);
  const queue = info.filter(c => !state.meta?.has(c.name));
  const worker = async () => {
    for (let c = queue.shift(); c && gen === payloadGen; c = queue.shift()) await load(c).catch(() => {});
  };
  await Promise.all(Array.from({ length: PREFETCH_CONCURRENCY }, worker));
  if (gen === payloadGen) { prefetch = 'done'; loadedHooks.forEach(fn => fn()); }
}

function load(m: MetaInfo): Promise<void> {
  let p = loading.get(m.url);
  if (!p) {
    p = readColumn(m)
      .then(col => {
        // Kept only if the payload still has this file for the column
        if (state.metaInfo?.get(m.name)?.url !== m.url) return;
        state.meta.set(m.name, { ...state.metaInfo.get(m.name), ...col });
        used.set(m.name, ++clock);
        evictColumns(META_CACHE_BYTES, m.name);
        loadedHooks.forEach(fn => fn());
      })
      .catch(e => { console.warn('GiottoLens: could not load metadata column', m.name, e); throw e; })
      .finally(() => loading.delete(m.url));
    loading.set(m.url, p);
  }
  return p;
}

// One column file, whole: the files are small and served without R. Item
// files (data/items.ts) are read the same way.
export async function readColumn(m: Pick<MetaInfo, 'kind' | 'url'>): Promise<Pick<MetaColumn, 'values' | 'min' | 'max'>> {
  const r = await fetch(dataUrl(m.url));
  if (!r.ok) throw new Error(`${m.url}: HTTP ${r.status}`);
  const raw = (await readColumns(await r.arrayBuffer(), ['value'])).value ?? [];
  const cat = m.kind === 'categorical';
  const values = cat ? new Int32Array(raw.length) : new Float64Array(raw.length);
  let min = Infinity, max = -Infinity;
  for (let i = 0; i < raw.length; i++) {
    const v = raw[i];
    const x = v == null ? (cat ? -1 : NaN) : Number(v);
    values[i] = x;
    if (!cat && x === x) { if (x < min) min = x; if (x > max) max = x; }
  }
  return { values, min, max };
}

// Display value of one cell
export function metaValue(col: MetaColumn, i: number): string | number | null {
  const v = col.values[i];
  if (col.kind === 'categorical') return v < 0 ? null : col.levels?.[v] ?? String(v);
  return v === v ? v : null;
}
