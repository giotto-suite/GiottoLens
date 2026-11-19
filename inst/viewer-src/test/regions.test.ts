import { describe, it, expect } from 'vitest';
import {
  readRegions, nextName, compareTargets, expressionValues, compareBlocked, keepChoice, REST,
} from '../panels/regions-model.ts';
import type { CatalogSource } from '../data/catalog.ts';

const two = [{ name: 'tumor', n: 120 }, { name: 'stroma', n: 80 }];

describe('readRegions', () => {
  it('mirrors R, with none as an empty list', () => {
    expect(readRegions({ regions: [{ name: 'a', n: 3 }] })).toEqual([{ name: 'a', n: 3 }]);
    expect(readRegions({ regions: null })).toEqual([]);
  });
});

describe('nextName', () => {
  it('takes the first free default name', () => {
    expect(nextName([])).toBe('region 1');
    expect(nextName([{ name: 'region 1', n: 1 }, { name: 'region 3', n: 1 }])).toBe('region 2');
  });
});

describe('compareTargets', () => {
  it('offers the other regions, then every other cell', () => {
    expect(compareTargets(two, 'tumor')).toEqual([
      { value: 'stroma', label: 'stroma' }, { value: REST, label: 'rest of the cells' }]);
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

describe('compareBlocked', () => {
  const vals = ['normalized'];
  it('says why a comparison cannot run', () => {
    expect(compareBlocked(two, [], 'tumor', REST)).toMatch(/no expression/);
    expect(compareBlocked([], vals, '', REST)).toBe('save a region first');
    expect(compareBlocked(two, vals, 'nope', REST)).toBe('pick region A');
    expect(compareBlocked(two, vals, 'tumor', 'nope')).toBe('pick region B');
    expect(compareBlocked(two, vals, 'tumor', 'tumor')).toBe('A and B are the same region');
  });
  it('lets a region run against another or the rest', () => {
    expect(compareBlocked(two, vals, 'tumor', 'stroma')).toBeNull();
    expect(compareBlocked(two, vals, 'tumor', REST)).toBeNull();
  });
});

describe('keepChoice', () => {
  it('keeps a value still offered, else takes the first', () => {
    expect(keepChoice('b', ['a', 'b'])).toBe('b');
    expect(keepChoice('z', ['a', 'b'])).toBe('a');
    expect(keepChoice('z', [])).toBe('');
  });
});
