// The saved selections' helpers. R holds them (adr/0029), each a set of rules
// and how they combine, and sends them as `selections` with the cells each
// selects now; the selection panel only mirrors them.
import type { CatalogSource } from '../data/catalog.ts';
import type { Rule } from '../selection/rules.ts';

export interface Saved { name: string; n: number; combine: 'and' | 'or'; rules: Rule[] }
export interface SavedMsg { selections?: Saved[] | null; open?: boolean }

export const readSaved = (msg: SavedMsg): Saved[] =>
  (msg.selections ?? []).map(s => ({ name: String(s.name), n: Number(s.n),
    combine: s.combine === 'or' ? 'or' : 'and', rules: Array.isArray(s.rules) ? s.rules : [] }));

// The first free default name: "selection 1", "selection 2", ...
export function nextName(saved: Saved[]): string {
  const taken = new Set(saved.map(s => s.name));
  for (let i = 1; ; i++) if (!taken.has(`selection ${i}`)) return `selection ${i}`;
}

// The expression values the object has, from the catalog: normalized first,
// as R defaults to it
export function expressionValues(sources: CatalogSource[]): string[] {
  const names = [...new Set(sources.filter(s => s.slot === 'expression' && s.name).map(s => s.name!))];
  return names.includes('normalized') ? ['normalized', ...names.filter(n => n !== 'normalized')] : names;
}
