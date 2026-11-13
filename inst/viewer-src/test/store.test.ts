import { describe, it, expect } from 'vitest';
import { store, actions, getConfig, initialConfig, mergeConfig, migrateConfig } from '../core/store.ts';
import { state } from '../core/state.js';

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
    actions.toggleGene('Cd3e'); actions.toggleGene('Actb'); actions.toggleGene('Cd3e');
    expect(store.getState().genes).toEqual(['Actb']);
    actions.addGenes(['Epcam', 'Actb']);
    expect(store.getState().genes).toEqual(['Actb', 'Epcam']);
    actions.clearGenes();
    actions.setBrushRadius(1000);
    expect(store.getState().brushRadius).toBe(300);
  });

  it('patches and resets the outline style', () => {
    expect(store.getState().outline).toEqual({ color: [0, 0, 0], width: 1, alpha: 0.8 });
    actions.setOutline({ width: 2.5 });
    expect(store.getState().outline).toEqual({ color: [0, 0, 0], width: 2.5, alpha: 0.8 });
    actions.setOutline({ color: [10, 20, 30], alpha: 0.5 });
    expect(store.getState().outline).toEqual({ color: [10, 20, 30], width: 2.5, alpha: 0.5 });
    expect(getConfig().outline).toEqual({ color: [10, 20, 30], width: 2.5, alpha: 0.5 });
    actions.resetOutline();
    expect(store.getState().outline).toEqual({ color: [0, 0, 0], width: 1, alpha: 0.8 });
  });

  it('sets and resets the selection color', () => {
    expect(store.getState().selectionColor).toEqual([255, 220, 50]);
    actions.setSelectionColor([0, 229, 255]);
    expect(getConfig().selectionColor).toEqual([0, 229, 255]);
    actions.setSelectionColor(null);
    expect(store.getState().selectionColor).toEqual([255, 220, 50]);
  });

  it('patches and resets category styles per column', () => {
    actions.setCategoryStyles('ct', { A: { color: [1, 2, 3] }, B: { show: false } });
    actions.setCategoryStyles('ct', { A: { alpha: 0.5 } });
    actions.setCategoryStyles('other', { X: { alpha: 1 } });
    expect(store.getState().categoryStyles.ct).toEqual({ A: { color: [1, 2, 3], alpha: 0.5 }, B: { show: false } });
    actions.resetCategoryStyles('ct');
    expect(store.getState().categoryStyles).toEqual({ other: { X: { alpha: 1 } } });
    actions.resetCategoryStyles('other');
  });

  it('patches and resets color scales per column', () => {
    actions.setColorScale('v', { preset: 'magma' });
    actions.setColorScale('v', { reverse: true });
    expect(store.getState().colorScales.v).toEqual({ preset: 'magma', reverse: true });
    actions.resetColorScale('v');
    expect(store.getState().colorScales).toEqual({});
  });

  it('restores genes this object has, by name, and the camera', () => {
    state.geneIndex = new Map([['Actb', 0], ['Cd3e', 1]]);
    const saved = { ...getConfig(), genes: ['Cd3e', 'Gone'], view: { target: [5, -5], zoom: 3 } };
    const s = mergeConfig(saved, store.getState());
    expect(s.genes).toEqual(['Cd3e']);
    expect(s.view).toEqual({ target: [5, -5], zoom: 3 });
    // a config from before genes were names drops its indices
    expect(migrateConfig({ genes: [0, 1], txPalette: 2 }, 1)).toEqual({ genes: [], txPalette: 2 });
    actions.setView({ target: [1, 2], zoom: 4 });
    expect(getConfig().view).toEqual({ target: [1, 2], zoom: 4 });
    actions.setView(null);
  });

  it('getConfig returns only the savable part as JSON', () => {
    actions.setSelection(new Uint8Array(3), 0);
    const cfg = getConfig();
    expect(Object.keys(cfg).sort()).toEqual(Object.keys(initialConfig()).sort());
    expect(() => JSON.stringify(cfg)).not.toThrow();
  });
});
