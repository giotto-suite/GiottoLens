// The catalog: what the object shown holds, by source (cell metadata of a
// feature type, an expression matrix, a spatial enrichment, a dim reduction),
// listed by R from the object at load (R/catalog.R). The Data panel pulls
// items from it into the metadata; the picker (panels/picker.ts) takes single
// items into the item cache (data/items.ts). Fetched once per page: a load
// of another object reloads the page.
// @ts-ignore: plain JS module
import { askR } from '../core/comms.js';

export interface CatalogSource {
  id: number;
  slot: 'cell_metadata' | 'expression' | 'spatial_enrichment' | 'dimension_reduction';
  feat_type: string;
  name?: string;
  method?: string;
  items: string[];
}
export interface CatalogPayload {
  spat_unit: string;
  sources: (Omit<CatalogSource, 'items'> & { items?: string[]; same_as?: number })[];
}
export type ItemType = 'auto' | 'categorical' | 'continuous';
export interface Queued { source: number; item: string; type: ItemType }

// R sends a list of names once when sources share it (`same_as`)
export function expandCatalog(p: CatalogPayload): CatalogSource[] {
  const byId = new Map<number, string[]>();
  return p.sources.map(s => {
    const items = s.items ?? byId.get(s.same_as!) ?? [];
    byId.set(s.id, items);
    const { same_as: _, ...rest } = s;
    return { ...rest, items };
  });
}

let catalog: Promise<CatalogSource[]> | null = null;

// The object's sources, asked of R once; a failed ask is asked again next time
export function loadCatalog(): Promise<CatalogSource[]> {
  catalog ??= (askR('catalog') as Promise<CatalogPayload>).then(expandCatalog);
  catalog.catch(() => { catalog = null; });
  return catalog;
}

const SLOT_LABELS: Record<CatalogSource['slot'], string> = {
  cell_metadata: 'cell metadata', expression: 'expression',
  spatial_enrichment: 'enrichment', dimension_reduction: 'dim reduction',
};
// The feature type only when there is more than one
export function sourceLabel(s: CatalogSource, all: CatalogSource[]): string {
  const ft = new Set(all.map(o => o.feat_type)).size > 1 ? ` (${s.feat_type})` : '';
  return SLOT_LABELS[s.slot] + (s.name ? ` · ${s.name}` : '') + ft;
}

// The column an item becomes when pulled on its own, as R names it: dim
// reduction axes <reduction>_<axis>, other names with characters other than
// letters, digits and _ replaced
export function columnFor(s: CatalogSource, item: string): string {
  const name = s.slot === 'dimension_reduction' ? `${s.name}_${s.items.indexOf(item) + 1}` : item;
  return name.replace(/[^A-Za-z0-9_]/g, '_');
}

// The `pull` ask's keys: one per source, a type per item
export function pullKeys(queue: Queued[]): { source: number; items: string[]; types: ItemType[] }[] {
  const keys = new Map<number, { source: number; items: string[]; types: ItemType[] }>();
  for (const q of queue) {
    const k = keys.get(q.source) ?? { source: q.source, items: [], types: [] };
    k.items.push(q.item);
    k.types.push(q.type);
    keys.set(q.source, k);
  }
  return [...keys.values()];
}
