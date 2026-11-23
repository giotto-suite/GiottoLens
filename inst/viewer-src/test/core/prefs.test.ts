import { describe, it, expect, afterEach } from 'vitest';
import { applyPrefs, prefs, prefIsSet, onPrefs, BUILTIN } from '../../core/prefs.ts';
import { prefOutline, prefTxPalette, prefSelection } from '../../core/store.ts';

afterEach(() => applyPrefs({ defaults: BUILTIN, set: {} }));

// Preferences as the colour code reads them: render/colors.test.ts
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

  it('give the outline and transcript palette their starting values', () => {
    expect(prefOutline(BUILTIN)).toEqual({ color: [0, 0, 0], width: 1, alpha: 0.8 });
    expect(prefOutline({ ...BUILTIN, outline_color: '#ff8000', outline_width: 2 }).color).toEqual([255, 128, 0]);
    expect(prefSelection(BUILTIN)).toEqual([255, 220, 50]);
    expect(prefSelection({ ...BUILTIN, selection_color: '#00e5ff' })).toEqual([0, 229, 255]);
    expect(prefTxPalette({ ...BUILTIN, tx_palette: 'vivid' })).toBe(1);
  });
});
