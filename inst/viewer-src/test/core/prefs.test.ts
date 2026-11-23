import { describe, it, expect, afterEach } from 'vitest';
import { applyPrefs, prefs, prefIsSet, onPrefs, BUILTIN } from '../../core/prefs.ts';
import { scaleStyle, scalePreset, scaleStops, columnScale, categoryPalette, cellColorBuffer,
  SCALE_PRESETS } from '../../render/colors.ts';
import { prefOutline, prefTxPalette, prefSelection } from '../../core/store.ts';
import { PALETTE, PALETTE_OKABE_ITO } from '../../core/constants.js';

afterEach(() => applyPrefs({ defaults: BUILTIN, set: {} }));

describe('preferences', () => {
  it('take the default unless set, and follow new defaults', () => {
    applyPrefs({ defaults: BUILTIN, set: { seq_palette: 'magma' } });
    expect(prefs().seq_palette).toBe('magma');
    expect(prefIsSet('seq_palette')).toBe(true);
    expect(prefIsSet('div_palette')).toBe(false);
    applyPrefs({ defaults: { ...BUILTIN, seq_palette: 'cividis', div_palette: 'RdBu' },
      set: { seq_palette: 'magma' } });
    expect(prefs().seq_palette).toBe('magma');
    expect(prefs().div_palette).toBe('RdBu');
  });

  it('tell listeners the old and new values', () => {
    let seen: [string, string] | null = null;
    const off = onPrefs((next, prev) => { seen = [prev.background, next.background]; });
    applyPrefs({ defaults: BUILTIN, set: { background: '#000000' } });
    off();
    expect(seen).toEqual(['#0d1117', '#000000']);
  });

  it('set the default scale style and palettes', () => {
    expect(scaleStyle({})).toBe('divergent');
    expect(scalePreset({})).toBe('blue-white-red');
    applyPrefs({ defaults: BUILTIN, set: { scale_style: 'sequential', seq_palette: 'magma' } });
    expect(scaleStyle({})).toBe('sequential');
    expect(scalePreset({})).toBe('magma');
    expect(scaleStops({})).toEqual(SCALE_PRESETS.magma);
    expect(scalePreset({ preset: 'turbo' })).toBe('turbo');
    expect(scaleStyle({ style: 'divergent' })).toBe('divergent');
  });

  it('give expression items their own style', () => {
    expect(columnScale('@expression', {})).toBeUndefined();
    applyPrefs({ defaults: BUILTIN, set: { gene_style: 'sequential' } });
    expect(columnScale('@expression', {})).toEqual({ style: 'sequential' });
    expect(columnScale('@expression', { '@expression': { style: 'divergent' } })).toEqual({ style: 'divergent' });
    expect(columnScale('score', {})).toBeUndefined();
  });

  it('color categories by palette, under per-column styles', () => {
    expect(categoryPalette()).toBe(PALETTE);
    applyPrefs({ defaults: BUILTIN, set: { cat_palette: 'okabe_ito', fill_opacity: 0.5 } });
    const col = { name: 'cell_type', kind: 'categorical', values: new Int32Array([0, 1]),
      levels: ['B', 'T/NK'] } as never;
    const { legend } = cellColorBuffer(2, col, {});
    const items = (legend as { items: { color: number[]; alpha: number }[] }).items;
    expect(items[0].color).toEqual(PALETTE_OKABE_ITO[0]);
    expect(items[1].color).toEqual(PALETTE_OKABE_ITO[1]);
    expect(items[0].alpha).toBe(0.5);
    const styled = cellColorBuffer(2, col, { 'T/NK': { color: [0, 0, 255] } });
    expect((styled.legend as { items: { color: number[] }[] }).items[1].color).toEqual([0, 0, 255]);
  });

  it('give the outline and transcript palette their starting values', () => {
    expect(prefOutline(BUILTIN)).toEqual({ color: [0, 0, 0], width: 1, alpha: 0.8 });
    expect(prefOutline({ ...BUILTIN, outline_color: '#ff8000', outline_width: 2 }).color).toEqual([255, 128, 0]);
    expect(prefSelection(BUILTIN)).toEqual([255, 220, 50]);
    expect(prefSelection({ ...BUILTIN, selection_color: '#00e5ff' })).toEqual([0, 229, 255]);
    expect(prefTxPalette({ ...BUILTIN, tx_palette: 'vivid' })).toBe(1);
  });
});
