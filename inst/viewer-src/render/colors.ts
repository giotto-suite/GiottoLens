// Color scales shared by every view, so a column has the same colors in the
// spatial view, the scatter and the legend.
import type { MetaColumn } from '../data/meta.ts';
import { PALETTE } from '../core/constants.js';

export type RGBA = [number, number, number, number];
// Per-category overrides of a categorical column (store.categoryStyles)
export interface CategoryStyle {
  color?: [number, number, number];
  show?: boolean;    // false: drawn like an uncolored cell
  alpha?: number;    // polygon fill opacity, 0-1
}
// Color scale of a continuous column (store.colorScales): a preset, or
// custom colors (preset 'custom'), evenly spaced from min to max
export interface ColorScale {
  preset?: string;
  colors?: [number, number, number][];
  reverse?: boolean;
}
const h = (s: string): [number, number, number] =>
  [parseInt(s.slice(1, 3), 16), parseInt(s.slice(3, 5), 16), parseInt(s.slice(5, 7), 16)];
export const SCALE_PRESETS: Record<string, [number, number, number][]> = {
  'blue-red': [[0, 0, 255], [255, 0, 0]],
  viridis: ['#440154', '#482878', '#3e4989', '#31688e', '#26828e', '#1f9e89', '#35b779', '#6ece58', '#b5de2b', '#fde725'].map(h),
  magma:  ['#000004', '#1c1044', '#4f127b', '#812581', '#b5367a', '#e55964', '#fb8761', '#fec287', '#fcfdbf'].map(h),
  inferno: ['#000004', '#1f0c48', '#550f6d', '#88226a', '#ba3655', '#e35933', '#f98e09', '#f9cb35', '#fcffa4'].map(h),
  plasma:  ['#0d0887', '#46039f', '#7201a8', '#9c179e', '#bd3786', '#d8576b', '#ed7953', '#fb9f3a', '#fdca26', '#f0f921'].map(h),
  cividis: ['#00224e', '#123570', '#3b496c', '#575d6d', '#707173', '#8a8779', '#a69d75', '#c4b56c', '#e4cf5b', '#fee838'].map(h),
  turbo:   ['#30123b', '#4662d7', '#36aaf9', '#1ae4b6', '#72fe5e', '#c8ef34', '#faba39', '#f66b19', '#ca2a04', '#7a0403'].map(h),
  gray:    [[48, 48, 48], [255, 255, 255]],
  'blue-white-red': ['#2166ac', '#67a9cf', '#d1e5f0', '#f7f7f7', '#fddbc7', '#ef8a62', '#b2182b'].map(h),
};
export const DEFAULT_SCALE = 'blue-red';
export const MAX_SCALE_COLORS = 9;

// The colors a scale draws with, low to high
export function scaleStops(scale: ColorScale = {}): [number, number, number][] {
  const custom = scale.preset === 'custom' && scale.colors && scale.colors.length >= 2;
  const stops = custom ? scale.colors! : SCALE_PRESETS[scale.preset ?? DEFAULT_SCALE] ?? SCALE_PRESETS[DEFAULT_SCALE];
  return scale.reverse ? [...stops].reverse() : stops;
}

export interface LegendItem { label: string; color: number[]; show: boolean; alpha: number }
export type Legend =
  | { type: 'categorical'; column: string; items: LegendItem[] }
  | { type: 'continuous'; column: string; min: number; max: number;
      stops: [number, number, number][]; scale: ColorScale };

export const DEFAULT_CELL: RGBA = [255, 255, 255, 200];
const NA: RGBA = [80, 80, 80, 180];
const HIDDEN: RGBA = [160, 160, 160, 120];
// polygon fill opacity of a colored cell, and of an uncolored one
export const DEFAULT_FILL_ALPHA = 0.9;
export const UNCOLORED_FILL = 20;
const CONTINUOUS_FILL = 110;

// t in [0, 1] to a color, linearly between evenly spaced stops
export function continuousColor(t: number, stops: [number, number, number][] = SCALE_PRESETS[DEFAULT_SCALE]): RGBA {
  const m = stops.length - 1;
  const x = Math.max(0, Math.min(1, t)) * m;
  const k = Math.min(m - 1, Math.floor(x)), f = x - k;
  const a = stops[k], b = stops[k + 1];
  return [Math.round(a[0] + (b[0] - a[0]) * f), Math.round(a[1] + (b[1] - a[1]) * f),
    Math.round(a[2] + (b[2] - a[2]) * f), 220];
}

// Per-cell RGBA buffer for a column (or the default color without one), used
// for centroids and the scatter, and a per-cell polygon fill alpha (0-255).
// Categorical columns take color, visibility and fill opacity per category
// from `styles`; centroids draw at twice the fill opacity, capped at 255.
// Continuous columns use `scale`.
export function cellColorBuffer(n: number, col: MetaColumn | null,
  styles: Record<string, CategoryStyle> = {}, scale: ColorScale = {}):
  { colors: Uint8Array; fill: Uint8Array; legend: Legend | null } {
  const out = new Uint8Array(n * 4);
  const fill = new Uint8Array(n);
  if (!col) {
    for (let i = 0; i < n; i++) { out.set(DEFAULT_CELL, i * 4); fill[i] = UNCOLORED_FILL; }
    return { colors: out, fill, legend: null };
  }
  const v = col.values;
  if (col.kind === 'categorical') {
    const levels = col.levels ?? [];
    const items: LegendItem[] = levels.map((label, k) => {
      const st = styles[label] ?? {};
      return {
        label,
        color: st.color ?? [...PALETTE[k % PALETTE.length]],
        show: st.show ?? true,
        alpha: st.alpha ?? DEFAULT_FILL_ALPHA,
      };
    });
    const rgba: RGBA[] = items.map(it => it.show
      ? [it.color[0], it.color[1], it.color[2], Math.min(255, Math.round(it.alpha * 510))]
      : HIDDEN);
    const fa = items.map(it => it.show ? Math.round(it.alpha * 255) : UNCOLORED_FILL);
    for (let i = 0; i < n; i++) {
      const c = v[i];
      if (c >= 0) { out.set(rgba[c], i * 4); fill[i] = fa[c]; }
      else { out.set(NA, i * 4); fill[i] = CONTINUOUS_FILL; }
    }
    return { colors: out, fill, legend: { type: 'categorical', column: col.name, items } };
  }
  const { min, max } = col;
  const range = max - min || 1;
  const stops = scaleStops(scale);
  for (let i = 0; i < n; i++) {
    const x = v[i];
    out.set(x === x ? continuousColor((x - min) / range, stops) : NA, i * 4);
    fill[i] = CONTINUOUS_FILL;
  }
  return { colors: out, fill, legend: { type: 'continuous', column: col.name, min, max, stops, scale } };
}
