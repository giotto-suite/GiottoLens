// The viewer's state store. Config (layers, colouring, selection rules,
// annotations, tool settings) can be saved as JSON; runtime fields (masks,
// loaded tables) are rebuilt from config and data. Change state only through
// the actions below; renders follow from subscriptions (render/schedule.js).
import { createStore } from 'zustand/vanilla';
import { subscribeWithSelector } from 'zustand/middleware';
import type { Rule } from '../selection/rules.ts';

export type LayerName = 'poly' | 'tx' | 'annotations';
export interface LayerVis { show: boolean; alpha: number }
export type Mode = 'pan' | 'ruler' | 'txlasso' | 'poly' | 'rect' | 'freehand' | 'lasso' | 'brush';
export type Combine = 'or' | 'and';

export interface Annotation {
  id: string;
  type: 'polygon' | 'rectangle' | 'freehand';
  name: string;
  coords: [number, number][];
}

export interface Config {
  layers: Record<LayerName, LayerVis>;
  txPalette: number;
  colorAll: boolean;
  genes: number[];              // selected gene indices into manifest genes
  colorBy: string | null;       // metadata column colouring the cells
  rules: Record<string, Rule>;  // selection rule per source
  combine: Combine;             // 'and' = crossfilter
  annotations: Annotation[];
  mode: Mode;
  brushRadius: number;          // screen pixels
  showRules: boolean;           // the rules strip under the HUD
}

export interface Runtime {
  selectedAnnotId: string | null;
  // Combined selection over cells; bumped `version` on every change
  selection: { mask: Uint8Array | null; count: number; version: number };
  metaVersion: number;          // bumped when metadata or colouring changes
}

export type LensState = Config & Runtime;

export const initialConfig = (): Config => ({
  layers: {
    poly:        { show: true,  alpha: 0.6 },
    tx:          { show: false, alpha: 0.7 },
    annotations: { show: true,  alpha: 0.6 },
  },
  txPalette: 0,
  colorAll: false,
  genes: [],
  colorBy: null,
  rules: {},
  combine: 'or',
  annotations: [],
  mode: 'pan',
  brushRadius: 30,
  showRules: true,
});

export const store = createStore<LensState>()(subscribeWithSelector((): LensState => ({
  ...initialConfig(),
  selectedAnnotId: null,
  selection: { mask: null, count: 0, version: 0 },
  metaVersion: 0,
})));

const set = store.setState;
const get = store.getState;

export const actions = {
  setLayer(name: LayerName, patch: Partial<LayerVis>) {
    set(s => ({ layers: { ...s.layers, [name]: { ...s.layers[name], ...patch } } }));
  },
  setTxPalette(i: number) { set({ txPalette: i }); },
  setColorAll(on: boolean) { set({ colorAll: on }); },
  toggleGene(i: number) {
    const g = get().genes;
    set({ genes: g.includes(i) ? g.filter(x => x !== i) : [...g, i] });
  },
  addGenes(idx: number[]) { set(s => ({ genes: [...new Set([...s.genes, ...idx])] })); },
  clearGenes() { set({ genes: [] }); },
  setColorBy(col: string | null) { set({ colorBy: col }); },
  bumpMeta() { set(s => ({ metaVersion: s.metaVersion + 1 })); },

  setRule(source: string, rule: Rule | null) {
    const rules = { ...get().rules };
    if (rule) rules[source] = rule; else delete rules[source];
    set({ rules });
  },
  setRules(rules: Record<string, Rule>) { set({ rules }); },
  clearSelection() { set({ rules: {} }); },
  setCombine(c: Combine) { set({ combine: c }); },
  setSelection(mask: Uint8Array | null, count: number) {
    set(s => ({ selection: { mask, count, version: s.selection.version + 1 } }));
  },

  addAnnotation(a: Annotation) { set(s => ({ annotations: [...s.annotations, a] })); },
  addAnnotations(list: Annotation[]) { set(s => ({ annotations: [...s.annotations, ...list] })); },
  removeAnnotation(id: string) {
    set(s => ({
      annotations: s.annotations.filter(a => a.id !== id),
      selectedAnnotId: s.selectedAnnotId === id ? null : s.selectedAnnotId,
    }));
  },
  renameAnnotation(id: string, name: string) {
    set(s => ({ annotations: s.annotations.map(a => a.id === id ? { ...a, name } : a) }));
  },
  selectAnnotation(id: string | null) { set({ selectedAnnotId: id }); },

  setMode(m: Mode) { set({ mode: m }); },
  setShowRules(on: boolean) { set({ showRules: on }); },
  setBrushRadius(px: number) { set({ brushRadius: Math.min(300, Math.max(8, px)) }); },
};

// The savable part of the state
export function getConfig(): Config {
  const s = get();
  const out = {} as Record<string, unknown>;
  for (const k of Object.keys(initialConfig())) out[k] = s[k as keyof Config];
  return out as unknown as Config;
}
