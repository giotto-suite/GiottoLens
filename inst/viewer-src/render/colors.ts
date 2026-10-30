// Colour scales shared by every view, so a column has the same colours in the
// spatial view, the scatter and the legend.
import type { MetaColumn } from '../data/meta.ts';
import { PALETTE } from '../core/constants.js';

export type RGBA = [number, number, number, number];
export type Legend =
  | { type: 'categorical'; items: { label: string; color: number[] }[] }
  | { type: 'continuous'; min: number; max: number };

export const DEFAULT_CELL: RGBA = [255, 255, 255, 200];
const NA: RGBA = [80, 80, 80, 180];

export function continuousColor(t: number): RGBA {
  return [Math.round(t * 255), 0, Math.round((1 - t) * 255), 220];
}

// Per-cell RGBA buffer for a column (or the default colour without one)
export function cellColorBuffer(n: number, col: MetaColumn | null): { colors: Uint8Array; legend: Legend | null } {
  const out = new Uint8Array(n * 4);
  if (!col) {
    for (let i = 0; i < n; i++) out.set(DEFAULT_CELL, i * 4);
    return { colors: out, legend: null };
  }
  const v = col.values;
  if (col.kind === 'categorical') {
    const levels = col.levels ?? [];
    const pal = levels.map((_, k) => [...PALETTE[k % PALETTE.length], 220]);
    for (let i = 0; i < n; i++) out.set(v[i] >= 0 ? pal[v[i]] : NA, i * 4);
    return { colors: out, legend: { type: 'categorical', items: levels.map((label, k) => ({ label, color: pal[k] })) } };
  }
  const { min, max } = col;
  const range = max - min || 1;
  for (let i = 0; i < n; i++) {
    const x = v[i];
    out.set(x === x ? continuousColor(Math.max(0, Math.min(1, (x - min) / range))) : NA, i * 4);
  }
  return { colors: out, legend: { type: 'continuous', min, max } };
}
