// The tray (adr/0027, adr/0030): the controls in a fixed-width column at the
// page's right edge, beside the dock rather than in it. A rail of icons on its
// left side, between it and the dock, lists every control this launch has;
// each button shows or hides its control (`trayShown`), and the ones shown
// stack in rail order and share the height. With every one hidden the tray
// stays open with a note; the arrow at the rail's top folds it to its rail
// (`trayCollapsed`). The dock is
// for views (the spatial view, charts, pushed panels), the tray for the
// controls that act on them.
//
// The divider right of the rail and those between controls shown drag (sash()): the
// width and the controls' shares of the height are saved with the config
// (`trayWidth`, `traySizes`), set once a drag ends.
//
// A control is one per viewer, its id is its kind, and it keeps its own
// state in the store (adr/0016). Built the first time it is shown, it keeps
// its DOM while hidden, and catches up in show() when shown again.
import { createIcons, icons } from 'lucide';
import { state } from '../core/state.js';
import { store, actions } from '../core/store.ts';
// @ts-ignore: plain JS module
import { reportError } from '../core/comms.js';
import type { PanelCtx, PanelHandle } from './dock.ts';
import { createRegisterPanel } from './register.ts';
import { createAnnotationsPanel } from './annotations.ts';
import { createLayersPanel } from './layers.ts';
import { createSelectionPanel } from './selection.ts';
import { activeModule, moduleControls, moduleOnly, setModule, moduleList } from './modules.ts';
import { showData } from './tools.ts';

// `icon`: lucide's name. `available`: whether this launch has what the
// control shows. A control a module offers (panels/modules.ts) is on the rail
// only while that module is on.
interface Control {
  create(body: HTMLElement, ctx: PanelCtx): PanelHandle;
  icon: string;
  available?(): boolean;
}
const hasImages = () => !!state.images?.size;
// A giotto object shown: R has a catalog to pull from
const hasCatalog = () => !!state.cells && !!state.manifest?.catalog;
// In rail order; the first one this launch has is shown until one is picked
const CONTROLS = {
  // How each layer is drawn: cells, transcripts, images, annotations
  layers:      { create: createLayersPanel, icon: 'layers' },
  // and/or, invert, clear; the rules; saved selections
  selection:   { create: createSelectionPanel, icon: 'square-dashed-mouse-pointer' },
  register:    { create: createRegisterPanel, icon: 'crosshair', available: hasImages },
  annotations: { create: createAnnotationsPanel, icon: 'pen-tool' },
} satisfies Record<string, Control>;
export type ControlKind = keyof typeof CONTROLS;
const KINDS = Object.keys(CONTROLS) as ControlKind[];
const controlOf = (kind: string): Control | undefined => (CONTROLS as Record<string, Control>)[kind];
export const isControl = (kind: string): kind is ControlKind => !!controlOf(kind);
const available = (kind: ControlKind) => controlOf(kind)!.available?.() ?? true;
export const TRAY_WIDTH = 260;   // px, the section's column by default; the rail is beside it
const MIN_WIDTH = 200;           // px, the narrowest the column drags to
const MAX_WIDTH = 0.6;           // of the window, the widest
const MIN_SECTION = 60;          // px, the shortest a control drags to

interface Section {
  el: HTMLElement;
  sash: HTMLElement;   // its divider with the control shown above it
  body: HTMLElement;
  title: HTMLElement;
  handle: PanelHandle | null;
}
const sections = new Map<ControlKind, Section>();   // built so far, the ones shown displayed
let host: HTMLElement | null = null;
let column: HTMLElement | null = null;
let rail: HTMLElement | null = null;
let fold: HTMLElement | null = null;
let leave: HTMLElement | null = null;   // leaves the module on
let empty: HTMLElement | null = null;   // the note while no control is shown
let hidden = false;   // the bottom bar's panels toggle
const collapsed = () => store.getState().trayCollapsed;
const trayOpen = () => !hidden && !collapsed();

const el = (tag: string, className = '', text = '') =>
  Object.assign(document.createElement(tag), { className, textContent: text });

// The controls on the rail: the module's while one is on, else those no
// module offers
const offered = (): ControlKind[] => {
  const on = activeModule();
  return on ? moduleControls(on) : KINDS.filter(k => !moduleOnly(k));
};
// The controls shown, in rail order, as picked with the module on (or none):
// those this launch has, or none when every one was hidden. Before any is
// picked, a module's are all shown, and without one the first.
export function shownControls(): ControlKind[] {
  const on = activeModule();
  const pool = offered().filter(available);
  const want = store.getState().trayShown[on ?? ''];
  if (want) return KINDS.filter(k => want.includes(k) && pool.includes(k));
  return on ? KINDS.filter(k => pool.includes(k)) : pool.slice(0, 1);
}
const isShown = (kind: ControlKind) => shownControls().includes(kind);
const setShown = (kinds: ControlKind[]) =>
  actions.setTrayShown(activeModule() ?? '', KINDS.filter(k => kinds.includes(k)));
// Open, as entering a module asks
export function showTray(): void {
  setTrayHidden(false);
  actions.setTrayCollapsed(false);
}

// A divider: `begin()` on a press takes the sizes it starts from and returns
// what follows the pointer (its travel in px from the press, along `dir`) and
// what runs on release
export function sash(dir: 'col' | 'row', begin: () => { move(d: number): void; end(): void } | null): HTMLElement {
  const s = el('div', `lens-sash lens-sash-${dir}`);
  s.addEventListener('pointerdown', e => {
    if (e.button !== 0) return;
    const drag = begin();
    if (!drag) return;
    e.preventDefault();
    s.setPointerCapture(e.pointerId);
    s.classList.add('dragging');
    const at = (p: PointerEvent) => dir === 'col' ? p.clientX : p.clientY;
    const start = at(e);
    const move = (m: PointerEvent) => drag.move(at(m) - start);
    const up = () => {
      s.classList.remove('dragging');
      s.removeEventListener('pointermove', move);
      s.removeEventListener('pointerup', up);
      s.removeEventListener('pointercancel', up);
      drag.end();
    };
    s.addEventListener('pointermove', move);
    s.addEventListener('pointerup', up);
    s.addEventListener('pointercancel', up);
  });
  return s;
}

const setWidth = (w: number) => host?.style.setProperty('--tray-width', `${w}px`);

// The divider between the rail and the column: dragged left, the column widens
function edgeSash(): HTMLElement {
  return sash('col', () => {
    if (!column || !trayOpen()) return null;
    const w0 = column.getBoundingClientRect().width;
    let w = w0;
    return {
      move: d => { w = Math.round(Math.min(Math.max(w0 - d, MIN_WIDTH), MAX_WIDTH * window.innerWidth)); setWidth(w); },
      end: () => actions.setTrayWidth(w),
    };
  });
}

// The divider above `kind`: dragged, it moves height between `kind` and the
// control shown above it; every control shown keeps its share, as px
function sectionSash(kind: ControlKind): HTMLElement {
  return sash('row', () => {
    const shown = shownControls();
    const i = shown.indexOf(kind);
    if (i < 1) return null;
    const h = new Map(shown.map(k => [k, sections.get(k)!.el.getBoundingClientRect().height]));
    const above = shown[i - 1], a0 = h.get(above)!, b0 = h.get(kind)!;
    const apply = () => { for (const k of shown) sections.get(k)!.el.style.flexGrow = String(h.get(k)); };
    return {
      move: d => {
        const a = Math.min(Math.max(a0 + d, MIN_SECTION), a0 + b0 - MIN_SECTION);
        h.set(above, a);
        h.set(kind, a0 + b0 - a);
        apply();
      },
      end: () => actions.setTraySizes({ ...store.getState().traySizes, ...Object.fromEntries(h) }),
    };
  });
}

export function initTray(el0: HTMLElement): void {
  host = el0;
  setWidth(store.getState().trayWidth ?? TRAY_WIDTH);
  store.subscribe(s => s.trayWidth, w => setWidth(w ?? TRAY_WIDTH));
  column = el('div', 'tray-sections');
  rail = el('div', 'tray-rail');
  fold = el('button', 'tool-btn tray-fold', '');
  fold.addEventListener('click', () => actions.setTrayCollapsed(!collapsed()));
  leave = el('button', 'tool-btn tray-leave', '');
  leave.innerHTML = '<i data-lucide="log-out"></i>';
  leave.addEventListener('click', () => setModule(null));
  rail.append(fold, leave, el('span', 'tray-rail-sep'));
  for (const kind of KINDS) {
    const b = el('button', 'tool-btn', '') as HTMLButtonElement;
    b.dataset.tray = kind;
    b.title = kind;
    b.innerHTML = `<i data-lucide="${controlOf(kind)!.icon}"></i>`;
    // The tray folded or hidden: it opens with this control shown. Open: the
    // control is shown or hidden
    b.addEventListener('click', () => {
      if (!trayOpen()) { showControl(kind); return; }
      const shown = shownControls();
      setShown(shown.includes(kind) ? shown.filter(k => k !== kind) : [...shown, kind]);
    });
    rail.append(b);
  }
  createIcons({ icons, root: rail });
  empty = el('div', 'panel-note tray-empty', 'No controls shown: pick one on the rail');
  column.append(empty);
  host.append(edgeSash(), rail, column);
  store.subscribe(s => s.trayShown, placeControls);
  store.subscribe(s => s.traySizes, placeControls);
  store.subscribe(s => s.trayCollapsed, setOpen);
  placeControls();
}

// The column shown or not; the arrow points the way a click moves it
function setOpen(): void {
  if (!host || !fold) return;
  const was = host.classList.contains('open');
  host.classList.toggle('open', trayOpen());
  fold.title = collapsed() ? 'expand the tray' : 'collapse the tray';
  fold.innerHTML = `<i data-lucide="${collapsed() ? 'chevrons-left' : 'chevrons-right'}"></i>`;
  createIcons({ icons, root: fold });
  if (!was && trayOpen()) for (const kind of shownControls()) sections.get(kind)?.handle?.show?.();
}

// The controls shown displayed, the others hidden; also after something a
// control shows arrives (images open after the tray). Sections are built in
// rail order, so the column stacks them in it.
export function placeControls(): void {
  if (!column || !rail || !leave) return;
  const on = moduleList().find(m => m.on);
  leave.style.display = on ? '' : 'none';
  leave.title = on ? `leave ${on.label}: the tray and the panes as they were` : '';
  const shown = shownControls();
  for (const kind of KINDS) {
    const b = rail.querySelector(`[data-tray=${kind}]`) as HTMLElement;
    b.style.display = offered().includes(kind) && available(kind) ? '' : 'none';
    b.classList.toggle('active', shown.includes(kind));
    const s = sections.get(kind);
    if (s && !shown.includes(kind)) s.el.style.display = 'none';
  }
  if (empty) empty.style.display = shown.length ? 'none' : '';
  const sizes = store.getState().traySizes;
  for (const kind of shown) {
    let s = sections.get(kind);
    const fresh = !s;
    s ??= build(kind);
    const was = s.el.style.display === 'none';
    s.el.style.display = '';
    s.el.style.flexGrow = String(sizes[kind] ?? 1);
    s.sash.style.display = kind === shown[0] ? 'none' : '';
    if (was && !fresh && trayOpen()) s.handle?.show?.();
  }
  setOpen();
}

function build(kind: ControlKind): Section {
  const s: Section = {
    el: el('section', 'tray-section'),
    sash: sectionSash(kind),
    title: el('span', 'tray-title', kind),
    body: el('div', 'tray-body'),
    handle: null,
  };
  s.el.dataset.control = kind;
  s.body.dataset.panel = kind;   // a hook for tests, as in the dock
  const head = el('div', 'tray-head');
  head.append(s.title);
  s.el.append(s.sash, head, s.body);
  // Before the first one built that comes after it in the rail
  const next = KINDS.slice(KINDS.indexOf(kind) + 1).map(k => sections.get(k)?.el).find(e => !!e);
  column!.insertBefore(s.el, next ?? null);
  sections.set(kind, s);
  fill(kind, s);
  return s;
}

function fill(kind: ControlKind, s: Section): void {
  s.handle?.destroy();
  s.handle = null;
  s.body.replaceChildren();
  const ctx: PanelCtx = {
    id: kind,
    setTitle: t => { s.title.textContent = t; },
    visible: () => trayOpen() && isShown(kind),
  };
  try {
    s.handle = controlOf(kind)!.create(s.body, ctx);
  } catch (e) {
    reportError(e, `panel '${kind}'`);
  }
}

// A control shown beside the others shown, the tray opened, as R asks when it
// gives the control something new (a saved selection)
export function showControl(kind: ControlKind): void {
  if (!available(kind)) return;
  // A module's control: that module is entered
  if (!offered().includes(kind)) {
    const m = moduleList().find(x => moduleControls(x.id).includes(kind));
    if (m) setModule(m.id);
  }
  setTrayHidden(false);
  actions.setTrayCollapsed(false);
  if (!isShown(kind)) setShown([...shownControls(), kind]);
}

// The note a panel shows until there is metadata, saying what it is for
// (`use`): with a giotto object shown, pulled from the object in the Data
// panel, which the note opens; otherwise only pushed from R
export function metadataNote(use: string): HTMLElement {
  const note = el('div', 'panel-note');
  const push = 'viewer$push_metadata(g)';
  if (!hasCatalog()) {
    note.textContent = `Push metadata from R ${use}: ${push}`;
    return note;
  }
  const link = el('button', 'note-link', 'Data panel');
  link.title = 'open the Data panel';
  link.addEventListener('click', showData);
  note.append('Pull metadata from the object in the ', link, ` ${use}, or push it from R: ${push}`);
  return note;
}

// Hidden by R (remove_panel()). False for an id that is not a control.
export function hideControl(id: string): boolean {
  if (!isControl(id)) return false;
  const shown = shownControls();
  if (shown.includes(id)) setShown(shown.filter(k => k !== id));
  return true;
}

// Controls rebuilt from what they show (the images' section after an image
// is added); one not built yet is built from scratch when shown
export function refreshControls(kinds: string[]): void {
  for (const [kind, s] of sections) if (kinds.includes(kind)) fill(kind, s);
}

// The bottom bar's panels toggle hides the column, the rail stays
export const trayHidden = (): boolean => hidden;
export function setTrayHidden(on: boolean): void {
  if (hidden === on) return;
  hidden = on;
  setOpen();
}

// For R's state(): the controls shown, after the dock's panels; none while
// the tray is folded or hidden
export function listControls(): { id: string; kind: string; title: string; group: string; visible: boolean }[] {
  if (!trayOpen()) return [];
  return shownControls().map(kind =>
    ({ id: kind, kind, title: sections.get(kind)?.title.textContent ?? kind, group: 'tray', visible: true }));
}
