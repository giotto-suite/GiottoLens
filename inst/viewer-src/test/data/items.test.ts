import { describe, it, expect, beforeEach } from 'vitest';
import { itemKey, parseItemKey, isItemKey, refOf, fieldLabel, scaleKey, evict, putItem, cachedItems,
  resetItems, setItemPins } from '../../data/items.ts';
import type { MetaColumn } from '../../data/meta.ts';

// The same key is checked in tests/testthat/test-catalog.R (.item_key())
const KEY = '@expression/rna/normalized//CD3E%2F%CE%B1%20b';

describe('item keys', () => {
  it('encode every byte but letters, digits and _.~- (as R does)', () => {
    expect(itemKey({ slot: 'expression', feat_type: 'rna', name: 'normalized', item: 'CD3E/α b' })).toBe(KEY);
  });

  it('round trip', () => {
    const refs = [
      { slot: 'expression' as const, feat_type: 'rna', name: 'normalized', item: 'CD3E/α b' },
      { slot: 'dimension_reduction' as const, feat_type: 'rna', name: 'umap', method: 'umap', item: 'Dim.1' },
      { slot: 'cell_metadata' as const, feat_type: 'rna', item: 'leiden_clus' },
    ];
    for (const r of refs) expect(parseItemKey(itemKey(r))).toEqual(r);
  });

  it('refuse what is not a key', () => {
    expect(parseItemKey('leiden_clus')).toBeNull();
    expect(parseItemKey('@expression/rna/raw/CD3E')).toBeNull();          // four parts
    expect(parseItemKey('@counts/rna/raw//CD3E')).toBeNull();             // no such slot
    expect(parseItemKey('@expression/rna/raw//')).toBeNull();             // no item
    expect(parseItemKey('@expression/rna/raw//%E0%A4')).toBeNull();       // bad UTF-8
    expect(isItemKey('leiden_clus')).toBe(false);
    expect(isItemKey(null)).toBe(false);
  });

  it('come from a catalog source', () => {
    const s = { id: 2, slot: 'expression' as const, feat_type: 'rna', name: 'normalized', items: ['CD3E/α b'] };
    expect(itemKey(refOf(s, 'CD3E/α b'))).toBe(KEY);
  });

  it('label as item · source, and expression items share a scale', () => {
    expect(fieldLabel(KEY)).toBe('CD3E/α b · normalized');
    expect(fieldLabel('leiden_clus')).toBe('leiden_clus');
    expect(fieldLabel(itemKey({ slot: 'expression', feat_type: 'rna', name: 'normalized',
      method: 'analysis:0f3a', item: 'EPCAM' }))).toBe('EPCAM · analysis, normalized');
    expect(fieldLabel(itemKey({ slot: 'cell_metadata', feat_type: 'rna', item: 'x' }))).toBe('x · object metadata');
    expect(scaleKey(KEY)).toBe('@expression');
    expect(scaleKey('leiden_clus')).toBe('leiden_clus');
    const umap = itemKey({ slot: 'dimension_reduction', feat_type: 'rna', name: 'umap', method: 'umap', item: 'Dim.1' });
    expect(scaleKey(umap)).toBe(umap);
  });
});

describe('item cache', () => {
  const col = (n: number): MetaColumn =>
    ({ name: 'x', kind: 'continuous', values: new Float64Array(n), min: 0, max: 1 });

  beforeEach(() => { resetItems(); setItemPins(() => []); });

  it('drops the least recently used until the rest fit', () => {
    putItem('@a', col(10));   // 80 bytes each
    putItem('@b', col(10));
    putItem('@c', col(10));
    evict(200);
    expect(cachedItems()).toEqual(['@b', '@c']);
  });

  it('never drops a pinned item', () => {
    putItem('@a', col(10));
    putItem('@b', col(10));
    putItem('@c', col(10));
    setItemPins(() => ['@a']);
    evict(100);
    expect(cachedItems()).toEqual(['@a']);
  });
});
