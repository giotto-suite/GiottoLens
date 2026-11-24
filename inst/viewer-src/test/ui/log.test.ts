import { describe, it, expect } from 'vitest';
import { collapse, describe as describeDetail, levelOf, type LogEntry } from '../../ui/log.ts';

const entry = (action: string, detail: unknown, time = 1): LogEntry => ({ time, action, detail });

describe('the log the page shows', () => {
  it('takes error, warning and message entries as notices, other actions as plain rows', () => {
    expect(['error', 'warning', 'message', 'pull', 'save'].map(a => levelOf(entry(a, null))))
      .toEqual(['error', 'warning', 'message', null, null]);
  });

  it('shows a plain row\'s detail in a line', () => {
    expect(describeDetail(null)).toBe('');
    expect(describeDetail('a, b')).toBe('a, b');
    expect(describeDetail({ path: '/p', n: 2, rules: ['x'] })).toBe('path: /p, n: 2, rules: ["x"]');
  });

  it('shows entries in a row that say the same thing once, with a count', () => {
    const w = { where: 'autosave', message: 'disk full' };
    const rows = collapse([entry('error', w, 1), entry('error', w, 2), entry('save', 'a', 3), entry('error', w, 4)]);
    expect(rows.map(r => [r.entry.action, r.count])).toEqual([['error', 2], ['save', 1], ['error', 1]]);
    // The newest of a run, for its time
    expect(rows[0].entry.time).toBe(2);
  });
});
