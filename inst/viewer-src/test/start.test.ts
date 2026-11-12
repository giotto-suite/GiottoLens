import { describe, it, expect } from 'vitest';
import { isAuto, listed, when, type Snapshot } from '../ui/start.ts';

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
