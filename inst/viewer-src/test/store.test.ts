import { describe, it, expect } from 'vitest';
import { store, actions, getConfig, initialConfig } from '../core/store.ts';

describe('store', () => {
  it('changes only through actions and notifies subscribers once per change', () => {
    const seen: string[][] = [];
    const off = store.subscribe(s => s.rules, r => seen.push(Object.keys(r)));
    actions.setRule('spatial', { source: 'spatial', kind: 'ids', params: { mask: '' } });
    actions.setRule('hist:x', { source: 'hist:x', kind: 'range', space: 'x', params: { min: 0, max: 1 } });
    actions.setRule('spatial', null);
    off();
    expect(seen).toEqual([['spatial'], ['spatial', 'hist:x'], ['hist:x']]);
    actions.clearSelection();
    expect(store.getState().rules).toEqual({});
  });

  it('keeps layer patches, genes and brush radius consistent', () => {
    actions.setLayer('tx', { alpha: 0.2 });
    expect(store.getState().layers.tx).toEqual({ show: false, alpha: 0.2 });
    actions.toggleGene(3); actions.toggleGene(5); actions.toggleGene(3);
    expect(store.getState().genes).toEqual([5]);
    actions.setBrushRadius(1000);
    expect(store.getState().brushRadius).toBe(300);
  });

  it('getConfig returns only the savable part as JSON', () => {
    actions.setSelection(new Uint8Array(3), 0);
    const cfg = getConfig();
    expect(Object.keys(cfg).sort()).toEqual(Object.keys(initialConfig()).sort());
    expect(() => JSON.stringify(cfg)).not.toThrow();
  });
});
