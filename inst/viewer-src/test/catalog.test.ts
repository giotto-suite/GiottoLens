import { describe, it, expect } from 'vitest';
import { expandCatalog, sourceLabel, columnFor, pullKeys } from '../panels/catalog.ts';
import type { CatalogSource } from '../panels/catalog.ts';

const payload = {
  spat_unit: 'cell',
  sources: [
    { id: 1, slot: 'cell_metadata' as const, feat_type: 'rna', items: ['leiden.clus', 'nr_feats'] },
    { id: 2, slot: 'expression' as const, feat_type: 'rna', name: 'raw', items: ['Cd3e', 'Ms4a1'] },
    { id: 3, slot: 'expression' as const, feat_type: 'rna', name: 'normalized', same_as: 2 },
    { id: 4, slot: 'dimension_reduction' as const, feat_type: 'rna', name: 'umap', method: 'umap',
      items: ['Dim.1', 'Dim.2'] },
  ],
};

describe('catalog', () => {
  it('fills in a source that shares an earlier one\'s names', () => {
    const s = expandCatalog(payload);
    expect(s[2].items).toEqual(['Cd3e', 'Ms4a1']);
    expect(s[2]).not.toHaveProperty('same_as');
    expect(s.map(o => o.id)).toEqual([1, 2, 3, 4]);
  });

  it('labels sources, with the feature type only when there are several', () => {
    const s = expandCatalog(payload);
    expect(sourceLabel(s[1], s)).toBe('expression · raw');
    expect(sourceLabel(s[0], s)).toBe('cell metadata');
    const prot: CatalogSource = { id: 5, slot: 'expression', feat_type: 'protein', name: 'raw', items: [] };
    expect(sourceLabel(prot, [...s, prot])).toBe('expression · raw (protein)');
  });

  it('names columns as R does', () => {
    const s = expandCatalog(payload);
    expect(columnFor(s[0], 'leiden.clus')).toBe('leiden_clus');
    expect(columnFor(s[3], 'Dim.2')).toBe('umap_2');
    expect(columnFor(s[1], 'Cd3e')).toBe('Cd3e');
  });

  it('groups the queue into one key per source, a type per item', () => {
    expect(pullKeys([
      { source: 2, item: 'Cd3e', type: 'auto' },
      { source: 1, item: 'nr_feats', type: 'categorical' },
      { source: 2, item: 'Ms4a1', type: 'continuous' },
    ])).toEqual([
      { source: 2, items: ['Cd3e', 'Ms4a1'], types: ['auto', 'continuous'] },
      { source: 1, items: ['nr_feats'], types: ['categorical'] },
    ]);
  });
});
