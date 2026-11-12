// The start page (adr/0019): open a GiottoDisk project, from the recent ones,
// a path or the IDE's folder dialog, and open one of its snapshots. R does
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

interface Recent { path: string; opened: string; exists: boolean }
interface Projects { current: string | null; recent: Recent[]; browse: boolean }
interface ProjectSnapshots { path: string; current: string | null; snapshots: Snapshot[] }

// A save the viewer made on its own (a hand-over, adr/0018) and nobody kept
export const isAuto = (s: Snapshot) => s.creator === 'GiottoLens' && s.keep === false;

// The snapshots listed: automatic ones only when asked for, or when shown now
export function listed(snaps: Snapshot[], showAuto: boolean, current: string | null): Snapshot[] {
  return snaps.filter(s => showAuto || !isAuto(s) || s.tag === current);
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

// Asks R to open snapshot `s` of `path`. R refuses to drop Lens work on the
// object shown without `discard`: the page asks first, then sends it. On
// success R reloads the page.
async function open(root: HTMLElement, path: string, s: Snapshot, keys: { spat_unit?: string; feat_type?: string }) {
  const status = root.querySelector('.start-status') as HTMLElement;
  const send = async (discard: boolean) => {
    status.textContent = `opening ${s.name}…`;
    status.classList.remove('error');
    root.classList.add('busy');
    try {
      await askR('open', { path, name: s.name, ...keys, discard });
    } catch (e: any) {
      root.classList.remove('busy');
      if (e.code === 'work' && !discard) {
        status.textContent = '';
        confirmDiscard(root, `Opening ${s.name} drops Lens work: ${e.message}.`, () => send(true));
        return;
      }
      status.textContent = e.message;
      status.classList.add('error');
    }
  };
  await send(false);
}

function confirmDiscard(root: HTMLElement, text: string, ok: () => void) {
  const box = el('div', 'start-confirm');
  box.append(el('div', 'start-confirm-text', text));
  const row = el('div', 'start-confirm-row');
  row.append(
    button('Discard and open', () => { box.remove(); ok(); }, 'start-btn danger'),
    button('Cancel', () => box.remove()),
  );
  box.append(row);
  root.querySelector('.start-confirm')?.remove();
  root.append(box);
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
  act.append(button('Open', () => open(root, path, s, {
    ...(unit ? { spat_unit: unit.value } : {}), ...(feat ? { feat_type: feat.value } : {}),
  })));
  row.append(act);
  return row;
}

let showAuto = false;

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

  const nAuto = res.snapshots.filter(isAuto).length;
  const list = el('div', 'start-list');
  const draw = () => {
    const shown = listed(res.snapshots, showAuto, res.current);
    list.replaceChildren(...shown.map(s => snapshotRow(root, res.path, s, res.current)));
    if (!shown.length) list.append(el('div', 'start-sub', res.snapshots.length
      ? 'Only automatic saves: show them below.' : 'No snapshots in this project.'));
  };
  draw();

  body.replaceChildren(head, list);
  if (nAuto) {
    const lab = el('label', 'start-toggle');
    const cb = el('input');
    cb.type = 'checkbox';
    cb.checked = showAuto;
    cb.addEventListener('change', () => { showAuto = cb.checked; draw(); });
    lab.append(cb, ` show automatic saves (${nAuto})`);
    body.append(lab);
  }
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

// The toolbar's project button: the start page as a dialog over the view
export function initProjectButton(btn: HTMLElement) {
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
  window.addEventListener('keydown', ev => { if (ev.key === 'Escape' && overlay) close(); });
}
