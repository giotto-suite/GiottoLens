// Jobs R runs for the page (adr/0025): the tools bar's jobs button and its
// popover. R sends a `job` message as each job starts, reports progress and
// ends, and one for every running job when a page connects. The page keeps
// the running jobs and the last FINISHED_KEPT finished ones, in memory (a
// reload starts with only the running ones), and cancels a job with the
// `cancel_job` ask. viewer$jobs() and viewer$cancel_job() are the same in R.
// @ts-ignore: plain JS module
import { onMessage, askR } from '../core/comms.js';
// @ts-ignore: plain JS module
import { escapeHtml } from './dom.js';

export type JobState = 'running' | 'done' | 'error' | 'cancelled';
export interface Job {
  id: number;
  label: string;
  ref?: string;                 // the page's name for a job it started
  state: JobState;
  message?: string;
  progress?: { done: number; total: number; what?: string };
  started: number;              // ms since the epoch
  ended?: number;
}

export const FINISHED_KEPT = 5;
const running = new Map<number, Job>();
let finished: Job[] = [];
const listeners = new Set<() => void>();

export const runningJobs = (): Job[] => [...running.values()];
export const finishedJobs = (): Job[] => finished;
export function onJobs(fn: () => void): () => void {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

// One `job` message: R's `started` is in seconds
export function noteJob(m: Omit<Job, 'started'> & { started?: number }) {
  const prev = running.get(m.id);
  const job: Job = { ...prev, ...m, started: m.started != null ? m.started * 1000 : prev?.started ?? Date.now() };
  if (m.state === 'running') running.set(m.id, job);
  else {
    running.delete(m.id);
    finished = [{ ...job, ended: Date.now() }, ...finished.filter(j => j.id !== m.id)].slice(0, FINISHED_KEPT);
  }
  listeners.forEach(fn => fn());
}

// For tests
export function resetJobs() { running.clear(); finished = []; }

// Before initComms(), like every handler
export function initJobs() { onMessage('job', noteJob); }

export function elapsed(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000));
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${String(s % 60).padStart(2, '0')}s`;
}

// The tools bar's button: a badge with the number of running jobs, a pulse
// while any runs, and the popover. Returns what removes it.
export function jobsButton(button: HTMLElement): () => void {
  const badge = Object.assign(document.createElement('span'), { className: 'rail-badge jobs-badge' });
  button.append(badge);
  const pop = Object.assign(document.createElement('div'), { className: 'jobs-popover' });
  let ticker: ReturnType<typeof setInterval> | undefined;

  const sync = () => {
    const n = running.size;
    badge.textContent = n ? String(n) : '';
    button.classList.toggle('busy', n > 0);
    button.title = n ? `${n} job${n === 1 ? '' : 's'} running` : 'jobs';
    if (pop.isConnected) render();
  };

  function render() {
    const row = (j: Job) => {
      const p = j.progress;
      const pct = p && p.total > 0 ? Math.min(100, Math.round(100 * p.done / p.total)) : null;
      const when = j.state === 'running' ? elapsed(Date.now() - j.started) : j.state;
      return `<div class="job-row state-${j.state}" data-id="${j.id}">` +
        `<div class="job-head"><span class="job-label" title="${escapeHtml(j.label)}">${escapeHtml(j.label)}</span>` +
        (j.ref ? `<span class="job-ref">${escapeHtml(j.ref)}</span>` : '') +
        `<span class="job-when">${escapeHtml(when)}</span>` +
        (j.state === 'running' ? `<button class="annot-row-btn job-cancel" title="cancel">×</button>` : '') + `</div>` +
        (pct != null && j.state === 'running'
          ? `<div class="job-bar"><span style="width:${pct}%"></span></div>` +
            (p!.what ? `<div class="job-what">${escapeHtml(p!.what)} · ${p!.done}/${p!.total}</div>` : '')
          : '') +
        (j.message && j.state !== 'running' && j.state !== 'done' ? `<div class="job-msg">${escapeHtml(j.message)}</div>` : '') +
        `</div>`;
    };
    const run = runningJobs(), done = finishedJobs();
    pop.innerHTML =
      `<div class="jobs-head">running</div>` +
      (run.length ? run.map(row).join('') : `<div class="jobs-none">no jobs running</div>`) +
      (done.length ? `<div class="jobs-head">finished</div>` + done.map(row).join('') : '');
  }

  pop.addEventListener('click', e => {
    const b = (e.target as HTMLElement).closest('.job-cancel');
    if (!b) return;
    const id = Number((b.closest('.job-row') as HTMLElement).dataset.id);
    (b as HTMLButtonElement).disabled = true;
    askR('cancel_job', { id }).catch(() => { (b as HTMLButtonElement).disabled = false; });
  });

  const close = () => {
    pop.remove();
    button.classList.remove('active');
    clearInterval(ticker);
    document.removeEventListener('pointerdown', outside, true);
    document.removeEventListener('keydown', keys);
  };
  const outside = (e: PointerEvent) => {
    const t = e.target as Node;
    if (!pop.contains(t) && !button.contains(t)) close();
  };
  const keys = (e: KeyboardEvent) => { if (e.key === 'Escape') close(); };
  button.addEventListener('click', () => {
    if (pop.isConnected) { close(); return; }
    document.body.append(pop);
    button.classList.add('active');
    render();
    const r = button.getBoundingClientRect();
    Object.assign(pop.style, { left: `${r.right + 6}px`, top: `${Math.max(4, Math.min(r.top, innerHeight - pop.offsetHeight - 4))}px` });
    ticker = setInterval(() => { if (running.size) render(); }, 1000);
    document.addEventListener('pointerdown', outside, true);
    document.addEventListener('keydown', keys);
  });

  const off = onJobs(sync);
  sync();
  return () => { off(); close(); badge.remove(); };
}
