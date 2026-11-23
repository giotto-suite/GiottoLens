// The left tray (adr/0032): a workbench panel beside the tools rail, outside
// the dock, as the controls' tray is at the right edge. One panel at a time,
// opened and closed by its rail button (panels/tools.ts) or by R; the Analysis
// panel today. Its right edge drags its width. Which panel is open and the
// width are saved with the config (store `drawer`, `drawerWidth`). The panels
// toggle hides it with the right tray; a module leaves it as it is.
//
// The panel is built the first time it opens and keeps its DOM while closed,
// catching up in show() when opened again.
import { state } from '../core/state.js';
import { store, actions } from '../core/store.ts';
// @ts-ignore: plain JS module
import { reportError } from '../core/comms.js';
import type { PanelCtx, PanelHandle } from './dock.ts';
import { sash } from './tray.ts';
// @ts-ignore: plain JS module
import { createAnalysisPanel } from './analysis.js';

interface DrawerPanel {
  create(body: HTMLElement, ctx: PanelCtx): PanelHandle;
  title: string;
  available(): boolean;
}
// A giotto object shown: R has a catalog, and an analysis can run on it
const DRAWERS = {
  analysis: { create: createAnalysisPanel, title: 'analysis',
              available: () => !!state.cells && !!state.manifest?.catalog },
} satisfies Record<string, DrawerPanel>;
export type DrawerId = keyof typeof DRAWERS;
const drawerOf = (id: string | null | undefined): DrawerPanel | undefined =>
  id ? (DRAWERS as Record<string, DrawerPanel>)[id] : undefined;
export const isDrawer = (id: string): id is DrawerId => !!drawerOf(id);
export const drawerAvailable = (id: DrawerId): boolean => drawerOf(id)!.available();

export const DRAWER_WIDTH = 360;   // px, until dragged
const MIN_WIDTH = 260;
const MAX_WIDTH = 0.5;             // of the window

let host: HTMLElement | null = null;
let titleEl: HTMLElement | null = null;
let bodyHost: HTMLElement | null = null;
let hidden = false;                // the panels toggle
const built = new Map<DrawerId, { el: HTMLElement; title: string; handle: PanelHandle | null }>();

const el = (tag: string, className = '', text = '') =>
  Object.assign(document.createElement(tag), { className, textContent: text });

// The panel open, while this launch can show it
export function openDrawer(): DrawerId | null {
  const id = store.getState().drawer;
  return id && isDrawer(id) && drawerAvailable(id) ? id : null;
}
const shownNow = () => !hidden && !!openDrawer();

export function showDrawer(id: DrawerId): void {
  if (!drawerAvailable(id)) return;
  hidden = false;
  actions.setDrawer(id);
  place();
}
export function toggleDrawer(id: DrawerId): void {
  if (openDrawer() === id && !hidden) actions.setDrawer(null);
  else showDrawer(id);
}
// R's remove_panel(): false for an id that is not a drawer panel
export function closeDrawer(id: string): boolean {
  if (!isDrawer(id)) return false;
  if (openDrawer() === id) actions.setDrawer(null);
  return true;
}
export const drawerHidden = (): boolean => hidden;
export function setDrawerHidden(on: boolean): void {
  if (hidden === on) return;
  hidden = on;
  place();
}

// For R's state(): the panel open, after the trays' controls
export function listDrawer(): { id: string; kind: string; title: string; group: string; visible: boolean }[] {
  const id = openDrawer();
  if (!id || hidden) return [];
  return [{ id, kind: id, title: built.get(id)?.title ?? id, group: 'drawer', visible: true }];
}

const setWidth = (w: number) => host?.style.setProperty('--drawer-width', `${w}px`);

// The open panel shown, built the first time; the others kept, hidden
function place(): void {
  if (!host || !bodyHost || !titleEl) return;
  const id = openDrawer();
  const on = shownNow();
  host.classList.toggle('open', on);
  for (const [k, b] of built) b.el.style.display = k === id ? '' : 'none';
  if (!on || !id) return;
  let b = built.get(id);
  if (!b) {
    const body = el('div', 'drawer-panel');
    body.dataset.panel = id;   // a hook for tests, as in the dock and the tray
    bodyHost.append(body);
    b = { el: body, title: drawerOf(id)!.title, handle: null };
    built.set(id, b);
    const entry = b;
    const ctx: PanelCtx = {
      id,
      setTitle: t => { entry.title = t; if (openDrawer() === id) titleEl!.textContent = t; },
      visible: () => shownNow() && openDrawer() === id,
    };
    try { b.handle = drawerOf(id)!.create(body, ctx); } catch (e) { reportError(e, `panel '${id}'`); }
  } else b.handle?.show?.();
  titleEl.textContent = b.title;
}

export function initDrawer(el0: HTMLElement): void {
  host = el0;
  setWidth(store.getState().drawerWidth ?? DRAWER_WIDTH);
  store.subscribe(s => s.drawerWidth, w => setWidth(w ?? DRAWER_WIDTH));
  const head = el('div', 'tray-head drawer-head');
  titleEl = el('span', 'tray-title', '');
  const x = el('button', 'flyout-close', '×') as HTMLButtonElement;
  x.title = 'close';
  x.addEventListener('click', () => actions.setDrawer(null));
  head.append(titleEl, x);
  bodyHost = el('div', 'drawer-body');
  // Its right edge: dragged right, it widens
  const edge = sash('col', () => {
    if (!shownNow() || !host) return null;
    const w0 = host.getBoundingClientRect().width;
    let w = w0;
    return {
      move: d => {
        w = Math.round(Math.min(Math.max(w0 + d, MIN_WIDTH), MAX_WIDTH * window.innerWidth));
        setWidth(w);
      },
      end: () => actions.setDrawerWidth(w),
    };
  });
  edge.classList.add('drawer-sash');
  host.append(head, bodyHost, edge);
  store.subscribe(s => s.drawer, place);
  place();
}
