// The tray (adr/0027): the controls in a fixed-width column at the page's
// right edge, beside the dock rather than in it. A rail of icons at the edge
// lists every control this launch has, and the tray shows one at a time: the
// last picked (`trayActive`). A click on the active one, or the arrow at the
// rail's top, folds the tray to its rail (`trayCollapsed`). The dock is for
// views (the spatial view, charts, pushed panels), the tray for the controls
// that act on them.
//
// A control is one per viewer, its id is its kind, and it keeps its own
// state in the store (adr/0016). Built the first time it is shown, it keeps
// its DOM when another is picked, and catches up in show() when picked again.
import { createIcons, icons } from 'lucide';
import { state } from '../core/state.js';
import { store, actions } from '../core/store.ts';
// @ts-ignore: plain JS module
import { reportError } from '../core/comms.js';
import type { PanelCtx, PanelHandle } from './dock.ts';
import { createDataPanel } from './data.ts';
import { createRegisterPanel } from './register.ts';
import { createAnnotationsPanel } from './annotations.ts';
import { createLayersPanel } from './layers.ts';
import { createSelectionPanel } from './selection.ts';

// `icon`: lucide's name. `available`: whether this launch has what the
// control shows.
interface Control {
  create(body: HTMLElement, ctx: PanelCtx): PanelHandle;
  icon: string;
  available?(): boolean;
}
const hasImages = () => !!state.images?.size;
// A giotto object shown: R has a catalog to pull from
const hasCatalog = () => !!state.cells && !!state.manifest?.catalog;
// In rail order; the first one this launch has is shown until another is picked
const CONTROLS = {
  // How each layer is drawn: cells, transcripts, images, annotations
  layers:      { create: createLayersPanel, icon: 'layers' },
  // and/or, invert, clear; the rules; saved selections
  selection:   { create: createSelectionPanel, icon: 'square-dashed-mouse-pointer' },
  data:        { create: createDataPanel, icon: 'database', available: hasCatalog },
  register:    { create: createRegisterPanel, icon: 'crosshair', available: hasImages },
  annotations: { create: createAnnotationsPanel, icon: 'pen-tool' },
} satisfies Record<string, Control>;
export type ControlKind = keyof typeof CONTROLS;
const KINDS = Object.keys(CONTROLS) as ControlKind[];
const controlOf = (kind: string): Control | undefined => (CONTROLS as Record<string, Control>)[kind];
export const isControl = (kind: string): kind is ControlKind => !!controlOf(kind);
const available = (kind: ControlKind) => controlOf(kind)!.available?.() ?? true;
export const TRAY_WIDTH = 260;   // px, the section's column; the rail is beside it

interface Section {
  el: HTMLElement;
  body: HTMLElement;
  title: HTMLElement;
  handle: PanelHandle | null;
}
const sections = new Map<ControlKind, Section>();   // built so far, the active one shown
let host: HTMLElement | null = null;
let column: HTMLElement | null = null;
let rail: HTMLElement | null = null;
let fold: HTMLElement | null = null;
let hidden = false;   // the tools bar's panels toggle
const collapsed = () => store.getState().trayCollapsed;
const trayOpen = () => !hidden && !collapsed();

const el = (tag: string, className = '', text = '') =>
  Object.assign(document.createElement(tag), { className, textContent: text });

// The control shown: the one picked last, while this launch has it, else the
// first it has
export function activeControl(): ControlKind | null {
  const want = store.getState().trayActive;
  if (want && isControl(want) && available(want)) return want;
  return KINDS.find(available) ?? null;
}

export function initTray(el0: HTMLElement): void {
  host = el0;
  host.style.setProperty('--tray-width', `${TRAY_WIDTH}px`);
  column = el('div', 'tray-sections');
  rail = el('div', 'tray-rail');
  fold = el('button', 'tool-btn tray-fold', '');
  fold.addEventListener('click', () => actions.setTrayCollapsed(!collapsed()));
  rail.append(fold, el('span', 'tray-rail-sep'));
  for (const kind of KINDS) {
    const b = el('button', 'tool-btn', '') as HTMLButtonElement;
    b.dataset.tray = kind;
    b.title = kind;
    b.innerHTML = `<i data-lucide="${controlOf(kind)!.icon}"></i>`;
    // Another control: shown, the tray opened if folded. The one shown:
    // the tray folds, or opens again
    b.addEventListener('click', () => {
      if (kind === activeControl() && !hidden) { actions.setTrayCollapsed(!collapsed()); return; }
      setTrayHidden(false);
      actions.setTrayCollapsed(false);
      actions.setTrayActive(kind);
    });
    rail.append(b);
  }
  createIcons({ icons, root: rail });
  host.append(column, rail);
  store.subscribe(s => s.trayActive, placeControls);
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
  const kind = activeControl();
  if (!was && trayOpen() && kind) sections.get(kind)?.handle?.show?.();
}

// The active control shown, the others hidden; also after something a control
// shows arrives (images open after the tray)
export function placeControls(): void {
  if (!column || !rail) return;
  const active = activeControl();
  for (const kind of KINDS) {
    const b = rail.querySelector(`[data-tray=${kind}]`) as HTMLElement;
    b.style.display = available(kind) ? '' : 'none';
    b.classList.toggle('active', kind === active);
    const s = sections.get(kind);
    if (s && (kind !== active || !available(kind))) s.el.style.display = 'none';
  }
  if (active) {
    let s = sections.get(active);
    const fresh = !s;
    s ??= build(active);
    const was = s.el.style.display === 'none';
    s.el.style.display = '';
    if (was && !fresh && trayOpen()) s.handle?.show?.();
  }
  setOpen();
}

function build(kind: ControlKind): Section {
  const s: Section = {
    el: el('section', 'tray-section'),
    title: el('span', 'tray-title', kind),
    body: el('div', 'tray-body'),
    handle: null,
  };
  s.el.dataset.control = kind;
  s.body.dataset.panel = kind;   // a hook for tests, as in the dock
  const head = el('div', 'tray-head');
  head.append(s.title);
  s.el.append(head, s.body);
  column!.append(s.el);
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
    visible: () => trayOpen() && activeControl() === kind,
  };
  try {
    s.handle = controlOf(kind)!.create(s.body, ctx);
  } catch (e) {
    reportError(e, `panel '${kind}'`);
  }
}

// A control brought forward, the tray opened, as R asks when it gives the
// control something new (a saved selection)
export function showControl(kind: ControlKind): void {
  if (!available(kind)) return;
  setTrayHidden(false);
  actions.setTrayCollapsed(false);
  actions.setTrayActive(kind);
}

// Hidden by R (remove_panel()): the tray folds when it is the one shown;
// false for an id that is not a control
export function hideControl(id: string): boolean {
  if (!isControl(id)) return false;
  if (activeControl() === id) actions.setTrayCollapsed(true);
  return true;
}

// Controls rebuilt from what they show (the images' section after an image
// is added); one not built yet is built from scratch when shown
export function refreshControls(kinds: string[]): void {
  for (const [kind, s] of sections) if (kinds.includes(kind)) fill(kind, s);
}

// The tools bar's panels toggle hides the column, the rail stays
export const trayHidden = (): boolean => hidden;
export function setTrayHidden(on: boolean): void {
  if (hidden === on) return;
  hidden = on;
  setOpen();
}

// For R's state(): the control shown, after the dock's panels; none while the
// tray is folded or hidden
export function listControls(): { id: string; kind: string; title: string; group: string; visible: boolean }[] {
  const kind = activeControl();
  if (!kind || !trayOpen()) return [];
  const s = sections.get(kind);
  return [{ id: kind, kind, title: s?.title.textContent ?? kind, group: 'tray', visible: true }];
}
