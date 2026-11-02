// The viewer's state store. Config (layers, colouring, selection rules,
// annotations, tool settings, panel layout) can be saved as JSON; runtime
// fields (masks, loaded tables) are rebuilt from config and data. Change state
// only through the actions below; renders follow from subscriptions
// (render/schedule.js).
import { createStore } from 'zustand/vanilla';
import { subscribeWithSelector, persist } from 'zustand/middleware';
import type { Rule } from '../selection/rules.ts';
import { rStorage } from './persist.ts';

export type LayerName = 'poly' | 'tx' | 'annotations' | 'img';
export interface LayerVis { show: boolean; alpha: number }
export interface ImageVis {
  show: boolean;
  rgb?: boolean;                 // a colour image: no colour or contrast of its own
  color?: [number, number, number];
  contrast?: [number, number];   // pixel values drawn as black and as full colour
}
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
  images: Record<string, ImageVis>;   // by image name, in manifest order
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
  layout: object | null;        // the docked panels (dockview's toJSON(); panels/dock.ts)
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
    img:         { show: true,  alpha: 1 },
  },
  images: {},
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
  layout: null,
});

// Saved through R and restored after a reload (core/persist.ts). Rules and
// the combine mode are left out: R restores those itself, since it evaluates
// them. Bump CONFIG_VERSION and add a step to `migrate` when a saved field
// changes meaning.
const CONFIG_VERSION = 1;
const UNSAVED: (keyof Config)[] = ['rules', 'combine'];
type Saved = Partial<Config>;

function savedConfig(s: LensState): Saved {
  const out: Record<string, unknown> = {};
  for (const k of Object.keys(initialConfig()) as (keyof Config)[])
    if (!UNSAVED.includes(k)) out[k] = s[k];
  return out as Saved;
}

// Layers and images merge by name, and only names this page has: a saved
// image the page did not load is dropped, and RGB is the file's, not saved
function mergeConfig(saved: unknown, current: LensState): LensState {
  const s = (saved ?? {}) as Saved;
  const out = { ...current } as Record<string, unknown>;
  for (const k of Object.keys(s) as (keyof Config)[])
    if (k in current && !UNSAVED.includes(k)) out[k] = s[k];
  const layers = { ...current.layers };
  for (const k of Object.keys(layers) as LayerName[]) layers[k] = { ...layers[k], ...s.layers?.[k] };
  const images: Record<string, ImageVis> = {};
  for (const [k, v] of Object.entries(current.images))
    images[k] = { ...v, ...s.images?.[k], ...(v.rgb != null && { rgb: v.rgb }) };
  return { ...out, layers, images } as LensState;
}

export const store = createStore<LensState>()(subscribeWithSelector(persist((): LensState => ({
  ...initialConfig(),
  selectedAnnotId: null,
  selection: { mask: null, count: 0, version: 0 },
  metaVersion: 0,
}), {
  name: 'giottolens-config',
  version: CONFIG_VERSION,
  storage: rStorage as never,
  skipHydration: true,          // main.js rehydrates once images are open
  partialize: savedConfig,
  merge: mergeConfig,
  migrate: saved => saved as Saved,
})));

const set = store.setState;
const get = store.getState;

export const actions = {
  setLayer(name: LayerName, patch: Partial<LayerVis>) {
    set(s => ({ layers: { ...s.layers, [name]: { ...s.layers[name], ...patch } } }));
  },
  setImage(name: string, patch: Partial<ImageVis>) {
    set(s => ({ images: { ...s.images, [name]: { ...s.images[name], ...patch } } }));
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
  setLayout(layout: object | null) { set({ layout }); },
};

// The savable part of the state
export function getConfig(): Config {
  const s = get();
  const out = {} as Record<string, unknown>;
  for (const k of Object.keys(initialConfig())) out[k] = s[k as keyof Config];
  return out as unknown as Config;
}
