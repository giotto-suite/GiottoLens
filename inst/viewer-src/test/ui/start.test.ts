import { describe, it, expect } from 'vitest';
import { deleteText, firstTab, isAuto, listed, listedSaves, when, type Save, type Snapshot } from '../../ui/start.ts';

const snap = (name: string, creator: string | null, keep: boolean | null): Snapshot => ({
  name, tag: `${name}.x`, created: '2026-11-12T19:55:13Z', creator, keep, description: null,
  spat_units: [], feat_types: [],
});

describe('start page snapshot list', () => {
  const user = snap('clustered', 'user', true);
  const auto = snap('lens_20261112_145513', 'GiottoLens', false);
  const kept = snap('lens_20261112_150000', 'GiottoLens', true);
  const old  = snap('legacy', null, null);

  it('counts only unkept viewer saves as automatic', () => {
    expect([user, auto, kept, old].map(isAuto)).toEqual([false, true, false, false]);
  });

  it('hides automatic saves unless asked, but never the one shown', () => {
    const all = [user, auto, kept, old];
    expect(listed(all, false, null).map(s => s.name)).toEqual(['clustered', kept.name, 'legacy']);
    expect(listed(all, true, null)).toHaveLength(4);
    expect(listed(all, false, auto.tag).map(s => s.name)).toContain(auto.name);
  });

  it('formats times, and passes through what it cannot read', () => {
    expect(when(null)).toBe('');
    expect(when('not a time')).toBe('not a time');
    expect(when('2026-11-12T19:55:13Z')).toMatch(/2026/);
  });
});

describe('start page save list', () => {
  const save = (name: string, kind: Save['kind'], mine?: boolean): Save => ({
    name, kind, updated: null, description: null, labels: [], snapshot: 's', mine, current: false,
  });
  const all = [save('mine', 'save', false), save('session-a', 'session', true),
    save('session-b', 'session', false), save('session-c', 'session')];

  it('hides work other users left unless asked, never saves or work of unknown owner', () => {
    expect(listedSaves(all, false).map(s => s.name)).toEqual(['mine', 'session-a', 'session-c']);
    expect(listedSaves(all, true)).toHaveLength(4);
  });

  it('opens on Saves when there are saves, else Objects, unless a tab was picked', () => {
    expect(firstTab(all, null)).toBe('saves');
    expect(firstTab(all.slice(1), null)).toBe('objects');
    expect(firstTab(all, 'recovered')).toBe('recovered');
  });

  it('says what deleting does, for one save, one left work or several', () => {
    expect(deleteText([all[0]])).toBe('Delete the save mine? It cannot be recovered; its snapshot stays.');
    expect(deleteText([all[1]])).toMatch(/^Discard the work a viewer left here\?/);
    expect(deleteText(all)).toBe('Delete 1 save and discard 3 work not saved? They cannot be recovered; snapshots stay.');
    expect(deleteText(all.slice(1))).toBe('Discard 3 work not saved? They cannot be recovered.');
  });
});
