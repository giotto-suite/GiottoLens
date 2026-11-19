// Items of the object shown that are not metadata: one gene of an expression
// matrix, one column of an enrichment or dim reduction, one cell metadata
// column of the object. A field that shows one (color-by) holds its item key,
// never a column name; R reads the values on request (the `item` ask) into a
// file under session/items/, and the page keeps the last ones used while
// they fit ITEM_CACHE_BYTES. Items never enter the metadata: pulling them
// into it is the Data panel's job (adr/0024).
//
// An item key is `@` and five parts joined by `/`: slot, feature type, the
// source's name, its method (dim reductions) and the item, each percent-
// encoded (every byte but letters, digits and `_.~-`). `.item_key()` in
// R/catalog.R writes the same; change both together. A metadata column name
// never starts with `@` (`.meta_name()`), so the two never collide.
// @ts-ignore: plain JS module
import { askR } from '../core/comms.js';
import { state } from '../core/state.js';
import { metaColumn, needColumns, readColumn, type MetaColumn, type MetaInfo } from './meta.ts';
import type { CatalogSource } from './catalog.ts';

export interface ItemRef {
  slot: CatalogSource['slot'];
  feat_type: string;
  name?: string;
  method?: string;
  item: string;
}

const enc = (s: string) => Array.from(new TextEncoder().encode(s), b =>
  /[A-Za-z0-9_.~-]/.test(String.fromCharCode(b)) && b < 128
    ? String.fromCharCode(b) : '%' + b.toString(16).toUpperCase().padStart(2, '0')).join('');

export const isItemKey = (s: unknown): s is string => typeof s === 'string' && s.startsWith('@');

export function itemKey(r: ItemRef): string {
  return '@' + [r.slot, r.feat_type, r.name ?? '', r.method ?? '', r.item].map(enc).join('/');
}

export function parseItemKey(key: string): ItemRef | null {
  if (!isItemKey(key)) return null;
  const p = key.slice(1).split('/');
  if (p.length !== 5) return null;
  let d: string[];
  try { d = p.map(decodeURIComponent); } catch (_) { return null; }
  const [slot, feat_type, name, method, item] = d;
  if (!['cell_metadata', 'expression', 'spatial_enrichment', 'dimension_reduction'].includes(slot) || !item)
    return null;
  return { slot: slot as ItemRef['slot'], feat_type, ...(name && { name }), ...(method && { method }), item };
}

export const refOf = (s: CatalogSource, item: string): ItemRef =>
  ({ slot: s.slot, feat_type: s.feat_type, ...(s.name && { name: s.name }), ...(s.method && { method: s.method }), item });

// How a field shows: a metadata column by its name, an item as `item · source`
export function fieldLabel(name: string): string {
  const r = parseItemKey(name);
  if (!r) return name;
  const from = r.slot === 'cell_metadata' ? 'object metadata' : r.name ?? r.slot;
  // An analysis's item names its step result by a hash (R/analysis.R)
  return `${r.item} · ${r.method?.startsWith('analysis:') ? `analysis, ${from}` : from}`;
}

// Expression items share one color scale, so a scale set for one gene stays
// for the next; other items and columns have their own
export const scaleKey = (name: string): string =>
  parseItemKey(name)?.slot === 'expression' ? '@expression' : name;

// ── The cache ────────────────────────────────────────────────────────────────

export const ITEM_CACHE_BYTES = 128 * 2 ** 20;

interface Entry { col: MetaColumn; bytes: number; used: number }
const cache = new Map<string, Entry>();
const loading = new Map<string, Promise<void>>();
const loadedHooks = new Set<() => void>();
let pins: () => Iterable<string> = () => [];
let clock = 0;

// Items never evicted: those a field shows (main.js: the color-by item)
export function setItemPins(fn: () => Iterable<string>) { pins = fn; }

// A loaded item, or undefined while it loads (the load starts here)
export function itemColumn(key: string): MetaColumn | undefined {
  const e = cache.get(key);
  if (e) { e.used = ++clock; return e.col; }
  void needItems([key]).catch(() => {});
  return undefined;
}

// Resolves once the items are loaded; rejects with R's error for one that is not
export function needItems(keys: string[]): Promise<void> {
  return Promise.all(keys.filter(k => !cache.has(k)).map(load)).then(() => undefined);
}

export function onItemsLoaded(fn: () => void): () => void {
  loadedHooks.add(fn);
  return () => loadedHooks.delete(fn);
}

export const cachedItems = (): string[] => [...cache.keys()];

type ItemInfo = MetaInfo & { number_text?: boolean };

function load(key: string): Promise<void> {
  let p = loading.get(key);
  if (!p) {
    p = (askR('item', { key }) as Promise<ItemInfo>)
      .then(info => adopt(key, info))
      .finally(() => loading.delete(key));
    loading.set(key, p);
  }
  return p;
}

// An item whose file R has already written and sent (color_by() from R)
export function primeItem(key: string, info: ItemInfo): Promise<void> {
  if (cache.has(key)) return Promise.resolve();
  let p = loading.get(key);
  if (!p) {
    p = adopt(key, info).finally(() => loading.delete(key));
    loading.set(key, p);
  }
  return p;
}

async function adopt(key: string, info: ItemInfo): Promise<void> {
  const col = await readColumn(info);
  cache.set(key, { col: { ...col, name: key, kind: info.kind, levels: info.levels,
    numeric: !!info.numeric, numberText: !!info.number_text }, bytes: col.values.byteLength, used: ++clock });
  evict();
  loadedHooks.forEach(fn => fn());
}

// Least recently used first, never a pinned item, until the rest fit
export function evict(cap = ITEM_CACHE_BYTES) {
  let total = 0;
  for (const e of cache.values()) total += e.bytes;
  if (total <= cap) return;
  const keep = new Set(pins());
  const order = [...cache.entries()].filter(([k]) => !keep.has(k)).sort((a, b) => a[1].used - b[1].used);
  for (const [k, e] of order) {
    if (total <= cap) break;
    cache.delete(k);
    total -= e.bytes;
  }
}

// For tests
export function resetItems() { cache.clear(); loading.clear(); clock = 0; }
export function putItem(key: string, col: MetaColumn) {
  cache.set(key, { col, bytes: col.values.byteLength, used: ++clock });
}

// ── Fields: a metadata column or an item ─────────────────────────────────────

// A field's values, or undefined while they load (the load starts here)
export const fieldColumn = (name: string): MetaColumn | undefined =>
  isItemKey(name) ? itemColumn(name) : metaColumn(name);

// Whether the field can be shown: a metadata column the payload lists, or an
// item (R checks it when asked)
export const fieldExists = (name: string): boolean =>
  isItemKey(name) ? !!parseItemKey(name) : !!state.metaInfo?.has(name);

export function needFields(names: string[]): Promise<void> {
  const items = names.filter(isItemKey);
  return Promise.all([needColumns(names.filter(n => !isItemKey(n))), needItems(items)]).then(() => undefined);
}
