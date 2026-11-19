// Preferences (lens_preferences() in R): defaults every viewer starts from.
// R sends the built-in defaults and the preferences that were set
// ('preferences', handled in main.js); a preference that was not set takes
// the default, so it follows the defaults of the installed GiottoLens. The
// Preferences dialog (ui/preferences.ts) sends changes back ('preferences_set'). Colors read the
// preferences when they draw; config fields that start from a preference
// (the outline, the transcript palette) take a new preference while they
// still hold the old one. The background applies only when set; unset, the
// spatial view keeps the theme's.

export interface Prefs {
  seq_palette: string;
  div_palette: string;
  scale_style: 'divergent' | 'sequential';
  gene_style: 'default' | 'divergent' | 'sequential';
  cat_palette: 'default' | 'vivid' | 'okabe_ito';
  tx_palette: 'default' | 'vivid';
  background: string;
  outline_color: string;
  selection_color: string;
  outline_width: number;
  outline_opacity: number;
  fill_opacity: number;
  expr_values: string;
  de_values: string;
  color_by: string;
  threads: number;
  history: number;
  network_dir: string;
}
export type PrefName = keyof Prefs;

// Used until R sends its defaults; the same as R's .lens_pref_spec()
export const BUILTIN: Prefs = {
  seq_palette: 'viridis', div_palette: 'blue-white-red', scale_style: 'divergent',
  gene_style: 'default', cat_palette: 'default',
  tx_palette: 'default', background: '#0d1117', outline_color: '#000000', selection_color: '#ffdc32', outline_width: 1,
  outline_opacity: 0.8, fill_opacity: 0.9, expr_values: 'normalized', de_values: 'normalized',
  color_by: '', threads: 4, history: 10, network_dir: '',
};

let defaults: Prefs = { ...BUILTIN };
let set: Partial<Prefs> = {};
let current: Prefs = { ...BUILTIN };
const listeners = new Set<(next: Prefs, prev: Prefs) => void>();

/** The value of every preference: the one set, else the default */
export const prefs = (): Prefs => current;
/** The built-in defaults R sent */
export const prefDefaults = (): Prefs => defaults;
/** Whether preference `k` was set */
export const prefIsSet = (k: PrefName): boolean => k in set;

/** Calls `fn(next, prev)` after the preferences change */
export function onPrefs(fn: (next: Prefs, prev: Prefs) => void): () => void {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

/** Applies preferences as R sends them */
export function applyPrefs(msg: { defaults?: Partial<Prefs>; set?: Partial<Prefs> }): void {
  const prev = current;
  defaults = { ...BUILTIN, ...(msg.defaults ?? {}) };
  set = { ...(msg.set ?? {}) };
  current = { ...defaults, ...set } as Prefs;
  for (const fn of listeners) fn(current, prev);
}

// "#rrggbb" as [r, g, b]
export const hexRgb = (s: string): [number, number, number] =>
  [parseInt(s.slice(1, 3), 16), parseInt(s.slice(3, 5), 16), parseInt(s.slice(5, 7), 16)];
export const rgbHex = (c: number[]): string =>
  '#' + c.slice(0, 3).map(v => Math.round(v).toString(16).padStart(2, '0')).join('');
