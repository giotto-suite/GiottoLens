// The Regions panel's helpers. R holds the regions (names and cell counts)
// and sends them as `regions`; the panel only mirrors them.
import type { CatalogSource } from '../data/catalog.ts';

export interface Region { name: string; n: number }
export interface RegionsMsg { regions?: Region[] | null; open?: boolean }

// The value of the "vs" menu entry for every cell not in A
export const REST = '';

export const readRegions = (msg: RegionsMsg): Region[] =>
  (msg.regions ?? []).map(r => ({ name: String(r.name), n: Number(r.n) }));

// The first free default name: "region 1", "region 2", ...
export function nextName(regions: Region[]): string {
  const taken = new Set(regions.map(r => r.name));
  for (let i = 1; ; i++) if (!taken.has(`region ${i}`)) return `region ${i}`;
}

// Choices for B given A: the other regions, then every other cell
export function compareTargets(regions: Region[], a: string): { value: string; label: string }[] {
  return [
    ...regions.filter(r => r.name !== a).map(r => ({ value: r.name, label: r.name })),
    { value: REST, label: 'rest of the cells' },
  ];
}

// The expression values a comparison can read, from the catalog: normalized
// first, as R defaults to it
export function expressionValues(sources: CatalogSource[]): string[] {
  const names = [...new Set(sources.filter(s => s.slot === 'expression' && s.name).map(s => s.name!))];
  return names.includes('normalized') ? ['normalized', ...names.filter(n => n !== 'normalized')] : names;
}

// Why the comparison cannot run, or null when it can
export function compareBlocked(regions: Region[], values: string[], a: string, b: string): string | null {
  if (!values.length) return 'the object shown has no expression';
  if (!regions.length) return 'save a region first';
  if (!regions.some(r => r.name === a)) return 'pick region A';
  if (b !== REST && !regions.some(r => r.name === b)) return 'pick region B';
  if (a === b) return 'A and B are the same region';
  return null;
}

// Keep a menu's value when it is still offered, else take the first choice
export function keepChoice(current: string, values: string[]): string {
  return values.includes(current) ? current : (values[0] ?? '');
}
