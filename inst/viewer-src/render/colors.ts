// Color scales shared by every view, so a column has the same colors in the
// spatial view, the scatter and the legend.
import type { MetaColumn } from '../data/meta.ts';
import { PALETTE, CATEGORY_PALETTES } from '../core/constants.js';
import { prefs } from '../core/prefs.ts';

export type RGBA = [number, number, number, number];
// Per-category overrides of a categorical column (store.categoryStyles)
export interface CategoryStyle {
  color?: [number, number, number];
  show?: boolean;    // false: drawn like an uncolored cell
  alpha?: number;    // polygon fill opacity, 0-1
}
// Color scale of a continuous column (store.colorScales), with Giotto's two
// gradient styles (GiottoVisuals `gradient_style`): 'divergent' centers the
// colors on a midpoint (default the median), stretched by the larger side as
// ggplot2's scale_*_gradient2 does; 'sequential' runs them from the low limit
// to the high one. Colors are a preset or custom ones (preset 'custom'),
// evenly spaced; `limits` clamps values outside them to the end colors.
export type ScaleStyle = 'divergent' | 'sequential';
export interface ColorScale {
  style?: ScaleStyle;
  preset?: string;
  colors?: [number, number, number][];
  reverse?: boolean;
  midpoint?: number | null;           // null: the median
  limits?: [number, number] | null;   // null: the data range
}
const h = (s: string): [number, number, number] =>
  [parseInt(s.slice(1, 3), 16), parseInt(s.slice(3, 5), 16), parseInt(s.slice(5, 7), 16)];
export const SCALE_PRESETS: Record<string, [number, number, number][]> = {
  // divergent
  'blue-white-red': [[0, 0, 255], [255, 255, 255], [255, 0, 0]],
  RdBu:    ['#2166ac', '#67a9cf', '#d1e5f0', '#f7f7f7', '#fddbc7', '#ef8a62', '#b2182b'].map(h),
  PuOr:    ['#542788', '#998ec3', '#d8daeb', '#f7f7f7', '#fee0b6', '#f1a340', '#b35806'].map(h),
  PRGn:    ['#1b7837', '#7fbf7b', '#d9f0d3', '#f7f7f7', '#e7d4e8', '#af8dc3', '#762a83'].map(h),
  // sequential
  viridis: ['#440154', '#482878', '#3e4989', '#31688e', '#26828e', '#1f9e89', '#35b779', '#6ece58', '#b5de2b', '#fde725'].map(h),
  magma:   ['#000004', '#1c1044', '#4f127b', '#812581', '#b5367a', '#e55964', '#fb8761', '#fec287', '#fcfdbf'].map(h),
  inferno: ['#000004', '#1f0c48', '#550f6d', '#88226a', '#ba3655', '#e35933', '#f98e09', '#f9cb35', '#fcffa4'].map(h),
  plasma:  ['#0d0887', '#46039f', '#7201a8', '#9c179e', '#bd3786', '#d8576b', '#ed7953', '#fb9f3a', '#fdca26', '#f0f921'].map(h),
  cividis: ['#00224e', '#123570', '#3b496c', '#575d6d', '#707173', '#8a8779', '#a69d75', '#c4b56c', '#e4cf5b', '#fee838'].map(h),
  turbo:   ['#30123b', '#4662d7', '#36aaf9', '#1ae4b6', '#72fe5e', '#c8ef34', '#faba39', '#f66b19', '#ca2a04', '#7a0403'].map(h),
  gray:    [[48, 48, 48], [255, 255, 255]],
  'blue-red': [[0, 0, 255], [255, 0, 0]],
};
export const DIVERGENT_PRESETS = ['blue-white-red', 'RdBu', 'PuOr', 'PRGn'];
export const SEQUENTIAL_PRESETS = ['viridis', 'magma', 'inferno', 'plasma', 'cividis', 'turbo', 'gray', 'blue-red'];
// Giotto's defaults: divergent blue, white, red; sequential viridis. The
// preferences (core/prefs.ts) can change them.
export const DEFAULT_STYLE: ScaleStyle = 'divergent';
export const DEFAULT_PRESET: Record<ScaleStyle, string> = { divergent: 'blue-white-red', sequential: 'viridis' };
export const DEFAULT_SCALE = DEFAULT_PRESET[DEFAULT_STYLE];
export const MAX_SCALE_COLORS = 9;

// The preset a scale of `style` takes when it names none: the preference,
// else Giotto's default
export function defaultPreset(style: ScaleStyle): string {
  const p = style === 'sequential' ? prefs().seq_palette : prefs().div_palette;
  return p in SCALE_PRESETS ? p : DEFAULT_PRESET[style];
}

export const scaleStyle = (scale: ColorScale = {}): ScaleStyle =>
  (scale.style ?? prefs().scale_style) === 'sequential' ? 'sequential' : 'divergent';
export const scalePreset = (scale: ColorScale = {}): string =>
  scale.preset ?? defaultPreset(scaleStyle(scale));

// The scale under key `name` in `scales` (a column's name, or scaleKey() of
// a field); the one expression items share takes the gene style preference
// when it sets no style
export function columnScale(name: string | null, scales: Record<string, ColorScale>): ColorScale | undefined {
  if (name == null) return undefined;
  const s = scales[name];
  const g = prefs().gene_style;
  if (name === '@expression' && g !== 'default' && !s?.style) return { ...(s ?? {}), style: g };
  return s;
}

// The colors of categories: the palette preference
export const categoryPalette = (): number[][] =>
  (CATEGORY_PALETTES as Record<string, number[][]>)[prefs().cat_palette] ?? PALETTE;

// The colors a scale draws with, low to high
export function scaleStops(scale: ColorScale = {}): [number, number, number][] {
  const custom = scale.preset === 'custom' && scale.colors && scale.colors.length >= 2;
  const fallback = SCALE_PRESETS[defaultPreset(scaleStyle(scale))];
  const stops = custom ? scale.colors! : SCALE_PRESETS[scalePreset(scale)] ?? fallback;
  return scale.reverse ? [...stops].reverse() : stops;
}

// Median of the non-NA values, kept per array
const medians = new WeakMap<ArrayLike<number>, number>();
export function medianOf(v: Float64Array | Float32Array): number {
  const hit = medians.get(v);
  if (hit !== undefined) return hit;
  const x = Float64Array.from(v).filter(z => z === z).sort();
  const n = x.length;
  const m = !n ? NaN : n % 2 ? x[(n - 1) / 2] : (x[n / 2 - 1] + x[n / 2]) / 2;
  medians.set(v, m);
  return m;
}

// Where a value falls on the scale, 0 to 1: `lo`/`hi` are the limits,
// `mid` the divergent midpoint (values beyond the limits clamp)
export function scalePosition(x: number, lo: number, hi: number, style: ScaleStyle, mid: number): number {
  const c = Math.max(lo, Math.min(hi, x));
  if (style === 'sequential') return (c - lo) / (hi - lo || 1);
  const half = Math.max(Math.abs(hi - mid), Math.abs(mid - lo)) || 1;
  return 0.5 + (c - mid) / (2 * half);
}

// The limits and midpoint a scale uses on a column
export function scaleRange(col: { values: Float64Array | Float32Array; min: number; max: number },
  scale: ColorScale = {}): { lo: number; hi: number; mid: number; style: ScaleStyle } {
  const style = scaleStyle(scale);
  const [lo, hi] = scale.limits && scale.limits.length === 2 ? scale.limits : [col.min, col.max];
  let mid = scale.midpoint ?? medianOf(col.values);
  if (!(mid === mid)) mid = (lo + hi) / 2;
  return { lo, hi, mid, style };
}

export interface LegendItem { label: string; color: number[]; show: boolean; alpha: number }
export type Legend =
  | { type: 'categorical'; column: string; items: LegendItem[] }
  | { type: 'continuous'; column: string; min: number; max: number;
      lo: number; hi: number; mid: number; style: ScaleStyle;
      stops: [number, number, number][]; scale: ColorScale };

export const DEFAULT_CELL: RGBA = [255, 255, 255, 200];
const NA: RGBA = [80, 80, 80, 180];
const HIDDEN: RGBA = [160, 160, 160, 120];
// polygon fill opacity of a colored cell, and of an uncolored one
export const DEFAULT_FILL_ALPHA = 0.9;
export const UNCOLORED_FILL = 20;
const NA_FILL = 110;   // a cell with no value: fainter than any colored one

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
    const pal = categoryPalette();
    const fillAlpha = prefs().fill_opacity;
    const items: LegendItem[] = levels.map((label, k) => {
      const st = styles[label] ?? {};
      return {
        label,
        color: st.color ?? [...pal[k % pal.length]],
        show: st.show ?? true,
        alpha: st.alpha ?? fillAlpha,
      };
    });
    const rgba: RGBA[] = items.map(it => it.show
      ? [it.color[0], it.color[1], it.color[2], Math.min(255, Math.round(it.alpha * 510))]
      : HIDDEN);
    const fa = items.map(it => it.show ? Math.round(it.alpha * 255) : UNCOLORED_FILL);
    for (let i = 0; i < n; i++) {
      const c = v[i];
      if (c >= 0) { out.set(rgba[c], i * 4); fill[i] = fa[c]; }
      else { out.set(NA, i * 4); fill[i] = NA_FILL; }
    }
    return { colors: out, fill, legend: { type: 'categorical', column: col.name, items } };
  }
  const { min, max } = col;
  const { lo, hi, mid, style } = scaleRange(col as { values: Float64Array; min: number; max: number }, scale);
  const stops = scaleStops(scale);
  // The fill opacity preference, as for categories: polygons at it, centroids
  // at twice it
  const fa = Math.round(prefs().fill_opacity * 255);
  const dot = Math.min(255, Math.round(prefs().fill_opacity * 510));
  for (let i = 0; i < n; i++) {
    const x = v[i];
    if (x === x) {
      const c = continuousColor(scalePosition(x, lo, hi, style, mid), stops);
      c[3] = dot;
      out.set(c, i * 4);
      fill[i] = fa;
    } else { out.set(NA, i * 4); fill[i] = NA_FILL; }
  }
  return { colors: out, fill, legend: { type: 'continuous', column: col.name, min, max, lo, hi, mid, style,
    stops, scale } };
}

// ── Low / mid / high handles on the legend bar (ui/legend.js) ──
// The bar spans the data range, in SLIDER_STEPS steps
export const SLIDER_STEPS = 1000;
export type ScaleHandle = 'lo' | 'mid' | 'hi';
interface HandleRange { lo: number; hi: number; min: number; max: number }

export function sliderToValue(pos: number, min: number, max: number): number {
  if (!(max > min)) return min;
  const step = (max - min) / SLIDER_STEPS;
  return Number((min + Math.round(pos) * step).toPrecision(6));
}

export function valueToSlider(v: number, min: number, max: number): number {
  if (!(max > min) || !Number.isFinite(v)) return 0;
  return Math.round(Math.max(0, Math.min(1, (v - min) / (max - min))) * SLIDER_STEPS);
}

/** The scale change for dragging one handle to `v`; low stays below high */
export function dragHandle(which: ScaleHandle, v: number, r: HandleRange): Partial<ColorScale> {
  if (which === 'mid') return { midpoint: v };
  const gap = (r.max - r.min) / SLIDER_STEPS || 1e-9;
  const lim: [number, number] = which === 'lo'
    ? [Math.min(v, r.hi - gap), r.hi] : [r.lo, Math.max(v, r.lo + gap)];
  return { limits: lim[0] <= r.min && lim[1] >= r.max ? null : lim };
}

/** The color of each of `n` values evenly spread over the data range, as
 *  drawn: flat beyond the limits, a divergent scale's middle at the midpoint */
export function barColors(lg: { min: number; max: number; lo: number; hi: number; mid: number;
  style: ScaleStyle; stops: [number, number, number][] }, n = 48): [number, number, number][] {
  const span = lg.max - lg.min;
  return Array.from({ length: n }, (_, i) => {
    const x = span > 0 ? lg.min + span * i / (n - 1) : lg.min;
    return continuousColor(scalePosition(x, lg.lo, lg.hi, lg.style, lg.mid), lg.stops).slice(0, 3) as
      [number, number, number];
  });
}

/** The scale change that returns one handle to automatic */
export function autoHandle(which: ScaleHandle, r: HandleRange): Partial<ColorScale> {
  if (which === 'mid') return { midpoint: null };
  const lim: [number, number] = which === 'lo' ? [r.min, r.hi] : [r.lo, r.max];
  return { limits: lim[0] <= r.min && lim[1] >= r.max ? null : lim };
}
