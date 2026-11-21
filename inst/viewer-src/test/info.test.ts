import { describe, it, expect } from 'vitest';
import { renderInfo, type ObjectInfo } from '../ui/info.ts';

const info = (over: Partial<ObjectInfo> = {}): ObjectInfo => ({
  project: '/data/proj',
  snapshot: {
    name: 'clustered', tag: 'clustered.ab12cd34', created: '2026-11-18T20:55:46Z', creator: 'user',
    owner: 'ana', keep: true, description: 'leiden <0.5>', labels: ['qc'], parents: ['normalized'],
    object: 'g-1', extra: { tissue: 'lung' },
  },
  object: { class: 'giotto', uid: 'g-1', written_by: 'GiottoClass 0.8.0', history_steps: 3 },
  counts: { cells: { cell: 169418 }, features: { rna: 18028 } },
  contents: {
    images: [{ on: '', items: [{ name: 'dapi', detail: 'giottoLargeImage' }] }],
    expression: [{ on: 'cell / rna', items: [{ name: 'raw', detail: 'parquetExprStore' }, { name: 'normalized' }] }],
    custom_slot: [{ on: '', items: [{ name: 'x' }] }],
  },
  ...over,
});

// The text of every element with class `cls`, in order
const texts = (html: string, cls: string) =>
  [...html.matchAll(new RegExp(`class="${cls}"[^>]*>([^<]*)`, 'g'))].map(m => m[1]);

describe('the info popover', () => {
  it('shows the save tags: owner, description, labels, parents and extra fields, escaped', () => {
    const h = renderInfo(info());
    expect(texts(h, 'info-title')).toEqual(['clustered']);
    expect(texts(h, 'info-desc')).toEqual(['leiden &lt;0.5&gt;']);
    expect(texts(h, 'info-tag')).toEqual(['qc']);
    const keys = texts(h, 'info-key'), vals = texts(h, 'info-val ');
    const rows = Object.fromEntries(keys.map((k, i) => [k, vals[i]]));
    expect(rows).toMatchObject({ owner: 'ana', 'saved by': 'user', from: 'normalized', tissue: 'lung' });
    expect(h).toContain((169418).toLocaleString());
  });

  it('lists the slots in reading order, an unknown one last, with item counts', () => {
    const h = renderInfo(info());
    expect([...h.matchAll(/<summary><span>([^<]*)/g)].map(m => m[1])).toEqual(['expression', 'images', 'custom slot']);
    expect(texts(h, 'info-count')[0]).toBe('2');
    expect(texts(h, 'info-on')).toEqual(['cell / rna']);
  });

  it('marks a snapshot not kept, skips empty fields, and says when there is no manifest', () => {
    const s = { ...info().snapshot, keep: false, owner: null, description: '', labels: [], extra: [] as [] };
    const h = renderInfo(info({ snapshot: s, contents: null, object: null, counts: null }));
    expect(h).toContain('info-temp');
    expect(h).not.toContain('info-desc');
    expect(texts(h, 'info-key')).not.toContain('owner');
    expect(texts(h, 'info-none')[0]).toMatch(/no manifest\.json/);
    expect(h).not.toContain('info-slot');
  });

  it('shows the Lens save open', () => {
    const h = renderInfo(info({ save: { name: 'tumor', updated: null, description: 'regions', labels: [] } }));
    expect(texts(h, 'info-head')).toContain('Lens save');
  });
});
