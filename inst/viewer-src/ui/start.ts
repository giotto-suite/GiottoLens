// The start page (adr/0019): open a GiottoDisk project, from the recent ones,
// a path or the IDE's folder dialog, and open one of its snapshots (the
// Objects tab), saves (adr/0026) or work viewers left (Recovered). R does
// all of it (askR()); the page only lists and asks. Shown in place of the
// view when no object is loaded, and as a dialog from the toolbar's project
// button when one is.
import { askR, onConnect } from '../core/comms.js';

export interface Snapshot {
  name: string;
  tag: string;
  created: string | null;
  creator: string | null;
  keep: boolean | null;
  description: string | null;
  spat_units: string[];
  feat_types: string[];
}

// A save of the viewer's work, or the work a viewer that ended left in the
// project (`kind` session). `snapshot`: null when it was deleted. `user`,
// `host`: who wrote it, where (`host` for a session only); `mine`: not
// written by another user, a label for browsing, not access control.
export interface Save {
  name: string;
  kind: 'save' | 'session';
  updated: string | null;
  description: string | null;
  labels: string[];
  snapshot: string | null;
  user?: string | null;
  host?: string | null;
  mine?: boolean;
  current: boolean;
}

interface Recent { path: string; opened: string; exists: boolean }
interface Projects { current: string | null; recent: Recent[]; browse: boolean }
interface ProjectSnapshots { path: string; current: string | null; snapshots: Snapshot[]; saves?: Save[] }

// A save the viewer made on its own (a hand-over, adr/0018) and nobody kept
export const isAuto = (s: Snapshot) => s.creator === 'GiottoLens' && s.keep === false;

// The snapshots listed: automatic ones only when asked for, or when shown now
export function listed(snaps: Snapshot[], showAuto: boolean, current: string | null): Snapshot[] {
  return snaps.filter(s => showAuto || !isAuto(s) || s.tag === current);
}

// The saves listed: work other users' viewers left only when asked for
export function listedSaves(saves: Save[], showOthers: boolean): Save[] {
  return saves.filter(s => s.kind === 'save' || showOthers || s.mine !== false);
}

export function when(iso: string | null): string {
  if (!iso) return '';
  const d = new Date(iso);
  return isNaN(d.getTime()) ? iso : d.toLocaleString(undefined,
    { year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

const basename = (p: string) => p.replace(/[\\/]+$/, '').split(/[\\/]/).pop() || p;

function el<K extends keyof HTMLElementTagNameMap>(tag: K, cls?: string, text?: string): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}

function button(text: string, onClick: () => void, cls = 'start-btn'): HTMLButtonElement {
  const b = el('button', cls, text);
  b.addEventListener('click', onClick);
  return b;
}

// Asks R to open (`op`, with `args`) `name` of `path`. R refuses to drop Lens
// work not saved on the object shown without `discard`: the page asks first,
// then sends it. On success R reloads the page.
async function open(root: HTMLElement, anchor: HTMLElement, op: 'open' | 'open_save', name: string,
  args: Record<string, unknown>) {
  const status = root.querySelector('.start-status') as HTMLElement;
  const send = async (discard: boolean) => {
    status.textContent = `opening ${name}…`;
    status.classList.remove('error');
    root.classList.add('busy');
    try {
      await askR(op, { ...args, name, discard });
    } catch (e: any) {
      root.classList.remove('busy');
      if (e.code === 'work' && !discard) {
        status.textContent = '';
        confirmBox(anchor, `Opening ${name} drops Lens work: ${e.message}.`, 'Discard and open', () => send(true));
        return;
      }
      status.textContent = e.message;
      status.classList.add('error');
    }
  };
  await send(false);
}

// A confirm box right under `anchor`, scrolled into view: on a long list the
// end of the page is out of sight. One at a time; an `ok` that fails leaves
// its message in the box.
function confirmBox(anchor: HTMLElement, text: string, okText: string, ok: () => unknown) {
  anchor.closest('.start')?.querySelector('.start-confirm')?.remove();
  const box = el('div', 'start-confirm');
  const msg = el('div', 'start-confirm-text', text);
  const row = el('div', 'start-confirm-row');
  const go = button(okText, async () => {
    go.disabled = true;
    try {
      await ok();
      box.remove();
    } catch (e: any) {
      msg.textContent = e.message;
      msg.classList.add('error');
      go.remove();
    }
  }, 'start-btn danger');
  row.append(go, button('Cancel', () => box.remove()));
  box.append(msg, row);
  anchor.after(box);
  box.scrollIntoView?.({ block: 'nearest' });
}

// A spatial unit / feature type picker; none when there is no choice (R picks)
function picker(values: string[], title: string): HTMLSelectElement | null {
  if (values.length < 2) return null;
  const sel = el('select', 'start-select');
  sel.title = title;
  for (const v of values) sel.append(new Option(v, v));
  return sel;
}

function snapshotRow(root: HTMLElement, path: string, s: Snapshot, current: string | null): HTMLElement {
  const row = el('div', 'start-row' + (s.tag === current ? ' current' : ''));
  const main = el('div', 'start-main');
  const title = el('div', 'start-name', s.name);
  if (s.tag === current) title.append(el('span', 'start-badge', 'shown'));
  if (isAuto(s)) title.append(el('span', 'start-badge auto', 'automatic'));
  main.append(title);
  const meta = [when(s.created), s.creator].filter(Boolean).join(' · ');
  if (meta) main.append(el('div', 'start-sub', meta));
  if (s.description) main.append(el('div', 'start-desc', s.description));
  row.append(main);

  const unit = picker(s.spat_units, 'spatial unit');
  const feat = picker(s.feat_types, 'feature type');
  const act = el('div', 'start-actions');
  if (unit) act.append(unit);
  if (feat) act.append(feat);
  act.append(button('Open', () => open(root, row, 'open', s.name, {
    path, ...(unit ? { spat_unit: unit.value } : {}), ...(feat ? { feat_type: feat.value } : {}),
  })));
  row.append(act);
  return row;
}

// What deleting `saves` does, for the confirm box
export function deleteText(saves: Save[]): string {
  const n = saves.filter(s => s.kind === 'save').length;
  const m = saves.length - n;
  if (saves.length === 1) {
    const s = saves[0];
    return m ? `Discard the work ${s.mine === false && s.user ? s.user + "'s" : 'a'} viewer left here${s.updated ? ' (' + when(s.updated) + ')' : ''}? It cannot be recovered.`
      : `Delete the save ${s.name}? It cannot be recovered; its snapshot stays.`;
  }
  const parts = [n && `delete ${n} save${n > 1 ? 's' : ''}`, m && `discard ${m} work not saved`].filter(Boolean);
  const text = parts.join(' and ');
  return `${text[0].toUpperCase()}${text.slice(1)}? They cannot be recovered${n ? '; snapshots stay' : ''}.`;
}

// Asks R to delete `saves` of `path` together, once confirmed in a box under
// `anchor`. R deletes none if it refuses one (the work of a viewer still
// running). `done` lists the project again.
function remove(anchor: HTMLElement, path: string, saves: Save[], done: () => void) {
  const left = saves.every(s => s.kind === 'session');
  confirmBox(anchor, deleteText(saves), left ? 'Discard' : 'Delete', async () => {
    await askR('delete_save', { path, name: saves.map(s => s.name) });
    done();
  });
}

function saveRow(root: HTMLElement, path: string, s: Save, done: () => void,
  ticked: Set<string>, onTick: () => void): HTMLElement {
  const row = el('div', 'start-row' + (s.current ? ' current' : ''));
  const left = s.kind === 'session';
  const tick = el('input', 'start-check');
  tick.type = 'checkbox';
  tick.checked = ticked.has(s.name);
  tick.title = 'select, to delete several together';
  tick.setAttribute('aria-label', `select ${left ? 'work not saved' : s.name}`);
  tick.addEventListener('change', () => {
    if (tick.checked) ticked.add(s.name); else ticked.delete(s.name);
    onTick();
  });
  const main = el('div', 'start-main');
  const title = el('div', 'start-name', left ? 'Work not saved' : s.name);
  if (s.current) title.append(el('span', 'start-badge', 'shown'));
  if (left) title.append(el('span', 'start-badge auto', s.mine === false
    ? `left by ${s.user}${s.host ? ' on ' + s.host : ''}` : 'left by a viewer that ended'));
  for (const l of s.labels) title.append(el('span', 'start-badge auto', l));
  main.append(title);
  const on = s.snapshot ? `on ${s.snapshot}` : 'its snapshot was deleted';
  main.append(el('div', 'start-sub', [when(s.updated), on].filter(Boolean).join(' · ')));
  if (s.description) main.append(el('div', 'start-desc', s.description));
  row.append(tick, main);
  const act = el('div', 'start-actions');
  if (s.snapshot) act.append(button('Open', () => open(root, row, 'open_save', s.name, { path })));
  act.append(button(left ? 'Discard' : 'Delete', () => remove(row, path, [s], done), 'start-btn danger'));
  row.append(act);
  return row;
}

let showAuto = false;
let showOthers = false;

// The project page's three tabs: the object's snapshots, the saves of Lens
// work, and work viewers that ended left (adr/0026)
export type Tab = 'objects' | 'saves' | 'recovered';
const TABS: [Tab, string][] = [['objects', 'Objects'], ['saves', 'Saves'], ['recovered', 'Recovered']];
// The tab picked while the page is open; until then, Saves when there are any
let picked: Tab | null = null;
export const firstTab = (saves: Save[], pick: Tab | null): Tab =>
  pick ?? (saves.some(s => s.kind === 'save') ? 'saves' : 'objects');

function toggle(text: string, on: boolean, change: (on: boolean) => void): HTMLLabelElement {
  const lab = el('label', 'start-toggle');
  const cb = el('input');
  cb.type = 'checkbox';
  cb.checked = on;
  cb.addEventListener('change', () => change(cb.checked));
  lab.append(cb, ' ' + text);
  return lab;
}

// A list of saves (or work left) with a bar to delete ticked ones together.
// `shown()`: the rows listed now; `empty`: the note when there are none.
function saveList(root: HTMLElement, path: string, shown: () => Save[], verb: string,
  empty: string, done: () => void): { el: HTMLElement; draw: () => void } {
  const wrap = el('div', 'start-pane');
  // Ticked for deleting together; only the rows listed count
  const ticked = new Set<string>();
  const bar = el('div', 'start-bulk');
  const tickAll = el('input', 'start-check');
  tickAll.type = 'checkbox';
  tickAll.setAttribute('aria-label', 'select all');
  const delSel = button(`${verb} selected`, () => {
    const sel = shown().filter(s => ticked.has(s.name));
    if (sel.length) remove(bar, path, sel, done);
  }, 'start-btn danger');
  const tickAllLab = el('label', 'start-toggle');
  tickAllLab.append(tickAll, ' select all');
  bar.append(tickAllLab, delSel);
  const list = el('div', 'start-list');
  const updateBar = () => {
    const rows = shown();
    const n = rows.filter(s => ticked.has(s.name)).length;
    delSel.disabled = !n;
    delSel.textContent = n ? `${verb} selected (${n})` : `${verb} selected`;
    tickAll.checked = n > 0 && n === rows.length;
    tickAll.indeterminate = n > 0 && n < rows.length;
  };
  const draw = () => {
    const rows = shown();
    list.replaceChildren(...rows.map(s => saveRow(root, path, s, done, ticked, updateBar)));
    if (!rows.length) list.append(el('div', 'start-sub', empty));
    bar.style.display = rows.length > 1 ? '' : 'none';
    updateBar();
  };
  tickAll.addEventListener('change', () => {
    for (const s of shown()) if (tickAll.checked) ticked.add(s.name); else ticked.delete(s.name);
    draw();
  });
  wrap.append(bar, list);
  return { el: wrap, draw };
}

async function showProject(root: HTMLElement, body: HTMLElement, path: string, back: () => void) {
  body.replaceChildren(el('div', 'start-sub', 'reading the project…'));
  let res: ProjectSnapshots;
  try {
    res = await askR('snapshots', { path });
  } catch (e: any) {
    body.replaceChildren(el('div', 'start-status error', e.message));
    body.append(button('← Projects', back, 'start-link'));
    return;
  }
  const head = el('div', 'start-head');
  head.append(button('← Projects', back, 'start-link'));
  const where = el('div', 'start-path');
  where.append(el('b', '', basename(res.path)), el('span', 'start-sub', ' ' + res.path));
  head.append(where);

  const again = () => showProject(root, body, path, back);
  const all = res.saves ?? [];
  const saves = all.filter(s => s.kind === 'save');
  const left = all.filter(s => s.kind === 'session');
  const objects = () => listed(res.snapshots, showAuto, res.current);
  const recovered = () => listedSaves(left, showOthers);
  const nAuto = res.snapshots.filter(isAuto).length;
  const nOthers = left.length - listedSaves(left, false).length;

  const tabs = el('div', 'start-tabs');
  tabs.setAttribute('role', 'tablist');
  const pane = el('div', 'start-pane');
  const count = (t: Tab) => t === 'objects' ? objects().length : t === 'saves' ? saves.length : recovered().length;
  let tab = firstTab(all, picked);

  const drawTab = () => {
    for (const b of tabs.children as HTMLCollectionOf<HTMLElement>) {
      const t = b.dataset.tab as Tab;
      b.classList.toggle('active', t === tab);
      b.setAttribute('aria-selected', String(t === tab));
      (b.querySelector('.start-tab-n') as HTMLElement).textContent = String(count(t));
    }
    if (tab === 'objects') {
      const list = el('div', 'start-list');
      const rows = objects();
      list.replaceChildren(...rows.map(s => snapshotRow(root, res.path, s, res.current)));
      if (!rows.length) list.append(el('div', 'start-sub', res.snapshots.length
        ? 'Only automatic objects: show them below.' : 'No objects in this project.'));
      pane.replaceChildren(list);
      if (nAuto) pane.append(toggle(`show automatic objects (${nAuto})`, showAuto,
        on => { showAuto = on; drawTab(); }));
    } else if (tab === 'saves') {
      const l = saveList(root, res.path, () => saves, 'Delete',
        'No saves yet: save from the tools bar, or viewer$save(name) in R.', again);
      l.draw();
      pane.replaceChildren(l.el);
    } else {
      const l = saveList(root, res.path, recovered, 'Discard', nOthers
        ? 'Only work left by others: show it below.' : 'Nothing to recover: no viewer left work not saved.', again);
      l.draw();
      pane.replaceChildren(l.el);
      if (nOthers) pane.append(toggle(`show work left by others (${nOthers})`, showOthers,
        on => { showOthers = on; drawTab(); }));
    }
  };
  for (const [t, label] of TABS) {
    const b = el('button', 'start-tab');
    b.type = 'button';
    b.dataset.tab = t;
    b.setAttribute('role', 'tab');
    b.append(label, el('span', 'start-tab-n'));
    b.addEventListener('click', () => { tab = picked = t; drawTab(); });
    tabs.append(b);
  }
  drawTab();
  body.replaceChildren(head, tabs, pane);
}

async function showProjects(root: HTMLElement, body: HTMLElement, pick: (path: string) => void) {
  body.replaceChildren(el('div', 'start-sub', 'asking R…'));
  let res: Projects;
  try {
    res = await askR('projects');
  } catch (e: any) {
    body.replaceChildren(el('div', 'start-status error', e.message));
    return;
  }
  const form = el('form', 'start-open');
  const input = el('input', 'start-input');
  input.placeholder = 'project directory…';
  input.spellcheck = false;
  input.autocomplete = 'off';
  form.append(input, el('button', 'start-btn', 'Open'));
  form.addEventListener('submit', ev => {
    ev.preventDefault();
    if (input.value.trim()) pick(input.value.trim());
  });
  if (res.browse) form.append(button('Browse…', async () => {
    try {
      const { path } = await askR('browse');
      if (path) pick(path);
    } catch (e: any) {
      const status = root.querySelector('.start-status') as HTMLElement;
      status.textContent = e.message;
      status.classList.add('error');
    }
  }));

  body.replaceChildren(el('div', 'start-label', 'Open a project'), form);
  if (res.recent.length) {
    body.append(el('div', 'start-label', 'Recent'));
    const list = el('div', 'start-list');
    for (const r of res.recent) {
      const row = el('div', 'start-row recent' + (r.exists ? '' : ' missing'));
      const main = el('div', 'start-main');
      main.append(el('div', 'start-name', basename(r.path)),
        el('div', 'start-sub', r.path + (r.exists ? '' : ' (not found)')));
      row.append(main);
      if (r.exists) row.addEventListener('click', () => pick(r.path));
      list.append(row);
    }
    body.append(list);
  }
  body.append(el('div', 'start-hint', 'Or in R: viewer$set_object(g)'));
}

// Builds the start page into `host`. `project`: the project to list first
// (the manifest's, on a viewer with a project and no object); else R's
// current project, else the projects list.
export function initStart(host: HTMLElement, project: string | null = null) {
  const root = el('div', 'start');
  const body = el('div', 'start-body');
  root.append(el('div', 'start-title', 'GiottoLens'), body, el('div', 'start-status'));
  host.append(root);

  const projects = () => showProjects(root, body, path => showProject(root, body, path, projects));
  const first = async () => {
    let path = project;
    if (!path) {
      try { path = (await askR('projects') as Projects).current; } catch { path = null; }
    }
    if (path) showProject(root, body, path, projects);
    else projects();
  };
  return { root, first };
}

// The start page on a viewer without an object: once R is connected, and
// again on a reconnect
export function showStartPage(host: HTMLElement, project: string | null) {
  const { first } = initStart(host, project);
  let shown = false;
  onConnect(() => { if (!shown) { shown = true; first(); } });
}

// The tools bar's project button: the start page as a dialog over the page.
// `signal` removes the listener it adds to the window.
export function initProjectButton(btn: HTMLElement, signal?: AbortSignal) {
  let overlay: HTMLElement | null = null;
  const close = () => { overlay?.remove(); overlay = null; };
  btn.addEventListener('click', () => {
    if (overlay) { close(); return; }
    overlay = el('div', 'start-overlay');
    overlay.addEventListener('mousedown', ev => { if (ev.target === overlay) close(); });
    const { root, first } = initStart(overlay);
    root.prepend(button('×', close, 'start-close'));
    document.body.append(overlay);
    first();
  });
  window.addEventListener('keydown', ev => { if (ev.key === 'Escape' && overlay) close(); }, { signal });
  signal?.addEventListener('abort', close);
}
