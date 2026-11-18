import { describe, it, expect, beforeEach } from 'vitest';
import { noteJob, runningJobs, finishedJobs, resetJobs, elapsed, FINISHED_KEPT } from '../ui/jobs.ts';

describe('jobs the page keeps', () => {
  beforeEach(resetJobs);

  it('keep a running job with its progress and start, and move it to finished when it ends', () => {
    noteJob({ id: 1, label: 'pull', state: 'running', started: 1000 });
    noteJob({ id: 1, label: 'pull', state: 'running', progress: { done: 2, total: 4 } });
    expect(runningJobs()).toHaveLength(1);
    expect(runningJobs()[0].started).toBe(1_000_000);
    expect(runningJobs()[0].progress).toEqual({ done: 2, total: 4 });
    noteJob({ id: 1, label: 'pull', state: 'error', message: 'boom' });
    expect(runningJobs()).toHaveLength(0);
    expect(finishedJobs()[0]).toMatchObject({ id: 1, state: 'error', message: 'boom', started: 1_000_000 });
  });

  it(`keep the last ${FINISHED_KEPT} finished, newest first`, () => {
    for (let i = 1; i <= FINISHED_KEPT + 2; i++) noteJob({ id: i, label: `j${i}`, state: 'done' });
    expect(finishedJobs().map(j => j.id)).toEqual([7, 6, 5, 4, 3]);
  });

  it('show elapsed time in seconds, then minutes', () => {
    expect(elapsed(4_400)).toBe('4s');
    expect(elapsed(125_000)).toBe('2m 05s');
  });
});
