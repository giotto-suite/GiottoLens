import { describe, it, expect } from 'vitest';
import { readSaved, nextName, expressionValues } from '../panels/saved-model.ts';
import type { CatalogSource } from '../data/catalog.ts';

describe('readSaved', () => {
  it('mirrors R, with none as an empty list', () => {
    const rule = { source: 'meta', kind: 'compare', space: 'score', params: { op: '>', value: '5' } } as const;
    expect(readSaved({ selections: [{ name: 'a', n: 3, combine: 'or', rules: [rule] }] }))
      .toEqual([{ name: 'a', n: 3, combine: 'or', rules: [rule] }]);
    expect(readSaved({ selections: [{ name: 'b', n: 1, combine: 'x' as never, rules: null as never }] }))
      .toEqual([{ name: 'b', n: 1, combine: 'and', rules: [] }]);
    expect(readSaved({ selections: null })).toEqual([]);
  });
});

describe('nextName', () => {
  it('takes the first free default name', () => {
    const one = (name: string) => ({ name, n: 1, combine: 'and' as const, rules: [] });
    expect(nextName([])).toBe('selection 1');
    expect(nextName([one('selection 1'), one('selection 3')])).toBe('selection 2');
  });
});

describe('expressionValues', () => {
  it('lists the expression sources, normalized first', () => {
    const src = (slot: CatalogSource['slot'], name?: string): CatalogSource =>
      ({ id: 0, slot, feat_type: 'rna', name, items: [] });
    expect(expressionValues([src('cell_metadata'), src('expression', 'raw'),
      src('expression', 'normalized'), src('expression', 'raw')])).toEqual(['normalized', 'raw']);
    expect(expressionValues([src('expression', 'raw')])).toEqual(['raw']);
    expect(expressionValues([src('cell_metadata')])).toEqual([]);
  });
});
