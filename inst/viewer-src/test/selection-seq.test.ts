import { describe, it, expect, vi } from 'vitest';

// What the page sends R, without a socket
const sent: any[] = [];
vi.mock('../core/comms.js', () => ({ sendToR: (type: string, data: any) => sent.push({ type, data }) }));

const { state } = await import('../core/state.js');
const { recompute, sendSelection, noteRuleSeq, syncRuleSeq } = await import('../selection/selection.ts');

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
