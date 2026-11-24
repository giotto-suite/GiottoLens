// The log (viewer$log()) in the page. What the page asks R to do reports
// here, not in R's console: R logs an action's errors, warnings and messages
// as one entry (`error`, `warning` or `message`, with its `items`), sends
// each entry as it is logged (`log_entry`) and the log so far to a tab on
// `ready` (`log_entries`). The latest such entry shows in place of the
// status line; the bottom bar's log button opens the whole log in a drawer
// that slides up over the panels. Text from R goes in as text, never markup.
// @ts-ignore: plain JS module
import { onMessage } from '../core/comms.js';

export type Level = 'error' | 'warning' | 'message';
export interface LogEntry { time: number; action: string; detail: unknown }
interface Item { level: Level; text: string }
interface Notice { where?: string; message?: string; items?: Item[]; more?: number }

const KEPT = 200;
// How long a notice shows; an error stays until it is read
const SHOW_MS: Record<Level, number> = { message: 4000, warning: 8000, error: Infinity };
const RANK: Record<Level, number> = { message: 0, warning: 1, error: 2 };

let entries: LogEntry[] = [];
let unread = 0;              // warnings and errors not yet seen in the log
let unreadError = false;
const listeners = new Set<() => void>();

export const logEntries = (): LogEntry[] => entries;
export const levelOf = (e: LogEntry): Level | null =>
  e.action === 'error' || e.action === 'warning' || e.action === 'message' ? e.action : null;
const noticeOf = (e: LogEntry): Notice =>
  e.detail && typeof e.detail === 'object' ? e.detail as Notice : { message: String(e.detail ?? '') };
const label = (s: string | undefined) => (s ?? '').replace(/_/g, ' ');

// An entry that is not a notice, in a line: `pull` "a, b"; `open` {path, name}
export function describe(detail: unknown): string {
  if (detail == null) return '';
  if (typeof detail !== 'object') return String(detail);
  return Object.entries(detail as Record<string, unknown>)
    .map(([k, v]) => `${k}: ${v != null && typeof v === 'object' ? JSON.stringify(v) : String(v)}`).join(', ');
}

// Entries in a row that say the same thing, as one with a count
export function collapse(list: LogEntry[]): { entry: LogEntry; count: number }[] {
  const out: { entry: LogEntry; count: number; key: string }[] = [];
  for (const entry of list) {
    const key = entry.action + '\u0000' + JSON.stringify(entry.detail);
    const last = out[out.length - 1];
    if (last && last.key === key) { last.entry = entry; last.count++; }
    else out.push({ entry, count: 1, key });
  }
  return out.map(({ entry, count }) => ({ entry, count }));
}

function add(e: LogEntry) {
  entries = [...entries, e].slice(-KEPT);
  const lv = levelOf(e);
  if (lv && lv !== 'message') { unread++; unreadError ||= lv === 'error'; }
  listeners.forEach(fn => fn());
  if (lv) notify(e, lv);
}

// For tests
export function resetLog() { entries = []; unread = 0; unreadError = false; }

// ── The status line's notice ───────────────────────────────────────────────
let notice: HTMLButtonElement | null = null;
let shown: Level | null = null;
let timer: ReturnType<typeof setTimeout> | undefined;

function hideNotice() {
  clearTimeout(timer);
  shown = null;
  if (notice) notice.hidden = true;
}

// The newest notice takes the place unless a more severe one is showing
function notify(e: LogEntry, lv: Level) {
  if (!notice || drawer?.classList.contains('open')) return;
  if (shown && RANK[shown] > RANK[lv]) return;
  const n = noticeOf(e);
  notice.className = `lvl-${lv}`;
  notice.replaceChildren();
  const text = Object.assign(document.createElement('span'), { className: 'notice-text',
    textContent: (n.where ? `${label(n.where)}: ` : '') + (n.message ?? '') });
  notice.append(text);
  const others = (n.items?.length ?? 1) - 1 + (n.more ?? 0);
  if (others > 0) notice.append(Object.assign(document.createElement('span'),
    { className: 'notice-more', textContent: `+${others} more` }));
  notice.title = 'open the log';
  notice.hidden = false;
  shown = lv;
  clearTimeout(timer);
  if (Number.isFinite(SHOW_MS[lv])) timer = setTimeout(hideNotice, SHOW_MS[lv]);
}

// ── The drawer ─────────────────────────────────────────────────────────────
let drawer: HTMLElement | null = null;
let list: HTMLElement | null = null;
let problemsOnly = false;
const expanded = new Set<LogEntry>();

function render() {
  if (!list) return;
  const rows = collapse(entries.filter(e => !problemsOnly || (levelOf(e) && levelOf(e) !== 'message'))).reverse();
  list.replaceChildren();
  if (!rows.length) {
    list.append(Object.assign(document.createElement('div'), { className: 'log-none',
      textContent: problemsOnly ? 'no errors or warnings' : 'nothing logged yet' }));
    return;
  }
  for (const { entry, count } of rows) list.append(row(entry, count));
}

function row(e: LogEntry, count: number): HTMLElement {
  const span = (cls: string, text: string) => Object.assign(document.createElement('span'), { className: cls, textContent: text });
  const lv = levelOf(e);
  const r = document.createElement('div');
  r.className = `log-row${lv ? ` lvl-${lv}` : ''}`;
  const n = lv ? noticeOf(e) : null;
  r.append(span('log-time', new Date(e.time * 1000).toLocaleTimeString()),
    span('log-where', n ? label(n.where) || lv! : label(e.action)),
    span('log-msg', n ? n.message ?? '' : describe(e.detail)));
  const tail = span('log-tail', count > 1 ? `×${count}` : '');
  const items = n?.items ?? [];
  if (items.length > 1 || n?.more) {
    const open = expanded.has(e);
    const t = Object.assign(document.createElement('button'), { className: 'log-toggle',
      textContent: `${open ? '▾' : '▸'} ${items.length + (n?.more ?? 0)}`, title: 'all of this action’s messages' });
    t.addEventListener('click', () => { open ? expanded.delete(e) : expanded.add(e); render(); });
    tail.prepend(t);
    if (open) {
      const box = document.createElement('div');
      box.className = 'log-items';
      for (const it of items) box.append(span(`log-item lvl-${it.level}`, it.text));
      if (n?.more) box.append(span('log-item', `and ${n.more} more`));
      r.append(tail, box);
      return r;
    }
  }
  r.append(tail);
  return r;
}

let badge: HTMLElement | null = null;
let button: HTMLElement | null = null;
function sync() {
  if (!badge || !button) return;
  badge.textContent = unread ? String(unread) : '';
  badge.classList.toggle('error', unreadError);
  button.title = unread ? `log: ${unread} unread (viewer$log())` : 'log (viewer$log())';
  if (drawer?.classList.contains('open')) { markRead(); render(); }
}
function markRead() {
  if (!unread && !unreadError) return;
  unread = 0; unreadError = false;
  if (badge) { badge.textContent = ''; badge.classList.remove('error'); }
}

export function openLog() {
  if (!drawer) return;
  drawer.classList.add('open');
  button?.classList.add('active');
  hideNotice();
  markRead();
  sync();
  render();
  document.addEventListener('keydown', keys);
}
export function closeLog() {
  drawer?.classList.remove('open');
  button?.classList.remove('active');
  document.removeEventListener('keydown', keys);
}
const keys = (e: KeyboardEvent) => { if (e.key === 'Escape') closeLog(); };

function buildDrawer(el: HTMLElement) {
  const head = document.createElement('div');
  head.className = 'log-head';
  const btn = (cls: string, text: string, title: string) =>
    Object.assign(document.createElement('button'), { className: cls, textContent: text, title });
  const all = btn('log-filter active', 'all', 'everything logged');
  const problems = btn('log-filter', 'errors & warnings', 'errors and warnings only');
  const setFilter = (p: boolean) => {
    problemsOnly = p;
    all.classList.toggle('active', !p);
    problems.classList.toggle('active', p);
    render();
  };
  all.addEventListener('click', () => setFilter(false));
  problems.addEventListener('click', () => setFilter(true));
  const x = btn('flyout-close', '×', 'close');
  x.addEventListener('click', closeLog);
  head.append(Object.assign(document.createElement('span'), { className: 'log-title', textContent: 'log' }), all, problems, x);
  list = document.createElement('div');
  list.className = 'log-list';
  el.replaceChildren(head, list);
}

// Before initComms(), like every handler. The bar's markup is in index.html
// (#notice, #btn-log, #log-drawer); a page without it only keeps the entries.
export function initLog() {
  notice = document.getElementById('notice') as HTMLButtonElement | null;
  button = document.getElementById('btn-log');
  drawer = document.getElementById('log-drawer');
  if (drawer) buildDrawer(drawer);
  if (button) {
    badge = Object.assign(document.createElement('span'), { className: 'rail-badge log-badge' });
    button.append(badge);
    button.addEventListener('click', () => drawer?.classList.contains('open') ? closeLog() : openLog());
  }
  notice?.addEventListener('click', openLog);
  listeners.add(sync);
  onMessage('log_entry', (e: LogEntry) => add(e));
  // The log so far, on connecting: already seen, or for a reload, in R
  onMessage('log_entries', ({ entries: es }: { entries?: LogEntry[] }) => {
    entries = (es ?? []).slice(-KEPT);
    listeners.forEach(fn => fn());
    render();
  });
}
