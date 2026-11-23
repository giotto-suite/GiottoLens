import { describe, it, expect, vi } from 'vitest';
import { grid, gridMeta } from '../helpers.ts';
import type { Ring } from '../../selection/geometry.ts';
import type { Rule } from '../../selection/rules.ts';

// What the page sends R, without a socket
const sent: any[] = [];
vi.mock('../../core/comms.js', () => ({ sendToR: (type: string, data: any) => sent.push({ type, data }) }));

const { state } = await import('../../core/state.js');
const { recompute, sendSelection, noteRuleSeq, syncRuleSeq,
  strokeOp, strokeRule, lassoSpatial, lassoScatter, brushStart, brushMove, brushEnd } = await import('../../selection/selection.ts');
const { store, actions } = await import('../../core/store.ts');
const { evaluate, countMask } = await import('../../selection/rules.ts');

describe('selections report the R rules they reflect', () => {
  it('reports a set_rule only once the selection is recomputed with it', () => {
    state.cells = { n: 4, x: new Float32Array(4), y: new Float32Array(4), url: '', tiles: [] };
    recompute();
    sendSelection();
    expect(sent.at(-1).data.r_seq).toBe(0);
    noteRuleSeq(3);                 // arrived; the selection does not reflect it yet
    sendSelection();
    expect(sent.at(-1).data.r_seq).toBe(0);
    recompute();
    sendSelection();
    expect(sent.at(-1).data.r_seq).toBe(3);
    syncRuleSeq(7);                 // a tab connecting while R has no rules
    sendSelection();
    expect(sent.at(-1).data.r_seq).toBe(7);
    state.cells = null;
  });
});

describe('stroke modifiers', () => {
  const cells = grid();
  const ctx = { cells, meta: gridMeta(cells) };
  const box = (x0: number, x1: number, y0: number, y1: number): Ring => [[x0, y0], [x1, y0], [x1, y1], [x0, y1]];
  const n = (r: Rule | undefined) => r ? countMask(evaluate(r, ctx)) : 0;

  it('Shift adds, Alt or Ctrl/Cmd subtracts, plain replaces', () => {
    expect(strokeOp({})).toBe('replace');
    expect(strokeOp({ shiftKey: true })).toBe('add');
    for (const k of ['altKey', 'ctrlKey', 'metaKey']) expect(strokeOp({ [k]: true })).toBe('subtract');
    const a: Rule = { source: 's', kind: 'range', space: 'score', params: { min: 0, max: 5 } };
    expect(strokeRule(undefined, a, 'subtract', 's')).toBeNull();
    expect(strokeRule(undefined, a, 'add', 's')).toBe(a);
  });

  for (const combine of ['or', 'and'] as const) {
    it(`spatial lasso replaces, adds and subtracts the same way in '${combine}' mode`, () => {
      actions.clearSelection(); actions.setCombine(combine);
      lassoSpatial(box(0, 4, 0, 10));                        // 40 cells
      expect(n(store.getState().rules.spatial)).toBe(40);
      lassoSpatial(box(0, 2, 0, 10));                        // replaces
      expect(n(store.getState().rules.spatial)).toBe(20);
      lassoSpatial(box(6, 8, 0, 10), 'add');                 // + 20
      expect(n(store.getState().rules.spatial)).toBe(40);
      lassoSpatial(box(0, 10, 0, 5), 'subtract');            // drops the lower half
      const r = store.getState().rules.spatial!;
      expect(r.kind).toBe('intersect');
      expect(n(r)).toBe(20);
      lassoSpatial(box(0, 10, 9, 10), 'subtract');           // extends the intersection
      expect((store.getState().rules.spatial as any).params.parts.length).toBe(3);
      expect(n(store.getState().rules.spatial)).toBe(16);
    });
  }

  it('the scatter keeps lassos in different axes as one union', () => {
    actions.clearSelection();
    lassoScatter(box(0, 2, 0, 10), 'score', 'score');
    lassoScatter(box(8, 10, 0, 10), 'x', 'y', 'add');
    const r = store.getState().rules.scatter!;
    expect(r.kind).toBe('union');
  });

  it('a subtracting brush removes what it covers', () => {
    actions.clearSelection();
    state.cells = cells;
    lassoSpatial(box(0, 10, 0, 10));                         // all 100
    brushStart([0.5, 0.5], 0.6, 'subtract');
    brushMove([0.5, 9.5]);                                   // column x = 0.5
    brushEnd();
    const r = store.getState().rules.spatial!;
    expect(r.kind).toBe('intersect');
    expect(n(r)).toBe(90);
    state.cells = null;
  });
});
