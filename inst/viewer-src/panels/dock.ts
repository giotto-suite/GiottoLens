// The stats panels, docked beside the spatial view (dockview-core): tabs and
// splits, placed from R by push_panel() and movable by dragging a tab. The
// spatial view is not a panel; it stays where it is.
//
// Each panel has a stable id: R's selection rules, push_panel(id =) and the
// saved layout all refer to it, so moving a panel changes nothing else. The
// layout is config (store `layout`): it is saved through R and restored after
// a reload. Built-in panels (scatter, histogram) are rebuilt from metadata;
// pushed panels from the payload R keeps and sends again on reconnect.
// Why dockview-core 4, and why R holds the saved config: adr/0009.
import {
  createDockview, themeDark,
  type DockviewApi, type IContentRenderer, type GroupPanelPartInitParameters,
  type IHeaderActionsRenderer, type IGroupHeaderProps, type IWatermarkRenderer,
  type AddPanelOptions, type SerializedDockview, type IDockviewPanel,
} from 'dockview-core';
import 'dockview-core/dist/styles/dockview.css';
import { state } from '../core/state.js';
import { store, actions } from '../core/store.ts';
import { heldPanels } from '../core/persist.ts';
// @ts-ignore: plain JS module
import { sendToR, reportError } from '../core/comms.js';
// @ts-ignore: plain JS module
import { createScatterPanel } from './scatter.js';
// @ts-ignore: plain JS module
import { createHistogramPanel } from './histogram.js';
// @ts-ignore: plain JS module
import { createSpecPanel } from './spec.js';
import { createDensityPanel } from './density.ts';

export type PanelKind = 'scatter' | 'histogram' | 'density' | 'spec';
const BUILTIN: Record<string, string> = { scatter: 'scatter', histogram: 'histogram', density: 'density' };

// What a panel gets from its dock slot
export interface PanelCtx {
  id: string;
  setTitle(title: string): void;
  visible(): boolean;
}
// What a panel gives back. `show()` runs when a hidden panel (a background
// tab) comes into view: panels skip work while hidden and catch up there.
export interface PanelHandle {
  destroy(): void;
  show?(): void;
  view?: unknown;
}

export interface PanelPayload {
  id: string;
  title?: string | null;
  where?: 'tab' | 'right' | 'below';
  ref?: string | null;
  spec: Record<string, unknown>;
  data_url?: string;
  restore?: boolean;
}

let dock: DockviewApi | null = null;
const views = new Map<string, PanelView>();
const payloads = new Map<string, PanelPayload>();   // pushed panels by id
const byR = new Set<string>();                       // removals R asked for
let restoring = false;                               // inside fromJSON()
let ownLayout: object | null = null;                 // last layout this module saved

const el = (tag: string, className = '', text = '') =>
  Object.assign(document.createElement(tag), { className, textContent: text });

class PanelView implements IContentRenderer {
  readonly element: HTMLElement = el('div', 'stats-pane-body');
  private id = '';
  private api!: GroupPanelPartInitParameters['api'];
  private handle: PanelHandle | null = null;
  private gen = 0;
  constructor(readonly kind: PanelKind) {}

  init({ api }: GroupPanelPartInitParameters): void {
    this.id = api.id;
    this.api = api;
    this.element.dataset.panel = this.id;   // a hook for tests
    views.set(this.id, this);
    api.onDidVisibilityChange(e => { if (e.isVisible) this.handle?.show?.(); });
    // After addPanel() has finished, so a title the panel sets is not
    // overwritten by the one it was added with
    queueMicrotask(() => { if (views.get(this.id) === this) this.fill(); });
  }

  get panel(): PanelHandle | null { return this.handle; }

  private ctx(): PanelCtx {
    return { id: this.id, setTitle: t => this.api.setTitle(t), visible: () => this.api.isVisible };
  }

  // (Re)build the contents: a built-in panel from the loaded metadata, a
  // pushed one from its payload
  async fill(): Promise<void> {
    const my = ++this.gen;
    this.handle?.destroy();
    this.handle = null;
    this.element.replaceChildren();
    try {
      if (this.kind === 'spec') {
        const p = payloads.get(this.id);
        if (!p) { this.element.append(el('div', 'panel-note', 'waiting for R…')); return; }
        const h: PanelHandle = await createSpecPanel(this.element, p, this.ctx());
        if (my !== this.gen) { h.destroy(); return; }
        this.handle = h;
      } else if (!state.meta?.size) {
        this.element.append(el('div', 'panel-note', 'Push metadata from R to fill this panel: viewer$push_metadata(g)'));
      } else {
        const create = { scatter: createScatterPanel, histogram: createHistogramPanel, density: createDensityPanel }[this.kind];
        this.handle = create(this.element, this.ctx());
      }
    } catch (e) {
      reportError(e, `panel '${this.id}'`);
    }
  }

  dispose(): void {
    this.gen++;
    this.handle?.destroy();
    this.handle = null;
    if (views.get(this.id) === this) views.delete(this.id);
  }
}

// "+" in each group's tab bar: add a built-in panel there
class AddMenu implements IHeaderActionsRenderer {
  readonly element = el('div', 'dock-actions');
  private off = new AbortController();
  init({ group }: IGroupHeaderProps): void {
    const btn = el('button', 'dock-add', '+') as HTMLButtonElement;
    btn.title = 'add a panel';
    const menu = el('div', 'dock-menu');
    for (const kind of Object.keys(BUILTIN)) {
      const item = el('button', '', kind) as HTMLButtonElement;
      item.addEventListener('click', () => {
        menu.classList.remove('open');
        addBuiltin(kind as PanelKind, { referenceGroup: group.id, direction: 'within' });
      });
      menu.append(item);
    }
    btn.addEventListener('click', e => { e.stopPropagation(); menu.classList.toggle('open'); });
    document.addEventListener('click', () => menu.classList.remove('open'), { signal: this.off.signal });
    this.element.append(btn, menu);
  }
  dispose(): void { this.off.abort(); this.element.remove(); }
}

// With every panel closed
class Empty implements IWatermarkRenderer {
  readonly element = el('div', 'dock-empty');
  init(): void {
    this.element.append(el('div', '', 'No panels. Add one:'));
    for (const kind of Object.keys(BUILTIN)) {
      const b = el('button', '', kind);
      b.addEventListener('click', () => addBuiltin(kind as PanelKind));
      this.element.append(b);
    }
  }
}

function newId(kind: string): string {
  if (!dock?.getPanel(kind)) return kind;
  for (let i = 2; ; i++) if (!dock.getPanel(`${kind}-${i}`)) return `${kind}-${i}`;
}

function addBuiltin(kind: PanelKind, position?: AddPanelOptions['position']): void {
  if (!dock) return;
  dock.addPanel({ id: newId(kind), component: kind, title: kind, ...(position && { position }) });
}

// The default: scatter above histogram, or as tabs when the dock is short
function defaultLayout(host: HTMLElement): void {
  if (!dock) return;
  dock.addPanel({ id: 'scatter', component: 'scatter', title: 'scatter' });
  const tabs = host.clientHeight > 0 && host.clientHeight < 420;
  dock.addPanel({ id: 'histogram', component: 'histogram', title: 'histogram',
    position: { referencePanel: 'scatter', direction: tabs ? 'within' : 'below' }, inactive: tabs });
}

function save(): void {
  if (!dock) return;
  ownLayout = dock.toJSON();
  actions.setLayout(ownLayout);
}

// A layout from the store that this module did not write: a restore
function applyLayout(layout: object | null): void {
  if (!dock || !layout || layout === ownLayout) return;
  restoring = true;
  try {
    dock.fromJSON(layout as SerializedDockview);
  } catch (e) {
    reportError(e, 'restoring the panel layout');
  } finally {
    restoring = false;
  }
  // Pushed panels R no longer holds cannot be filled; ones the layout lacks
  // (pushed before this page saved one) are placed again
  const held = heldPanels();
  if (held) for (const p of [...dock.panels])
    if (views.get(p.id)?.kind === 'spec' && !held.has(p.id)) { byR.add(p.id); dock.removePanel(p); }
  for (const p of payloads.values()) if (!dock.getPanel(p.id)) pushPanel({ ...p, restore: true });
  save();
}

export function initDock(host: HTMLElement): void {
  const theme = { ...themeDark, name: 'lens', className: `${themeDark.className} lens-dock` };
  dock = createDockview(host, {
    theme,
    disableFloatingGroups: true,
    // Hidden tabs keep their DOM, so a moved or hidden deck.gl canvas and
    // Vega view survive; panels skip work while hidden (PanelHandle.show)
    defaultRenderer: 'always',
    createComponent: ({ name }) => new PanelView(name as PanelKind),
    createRightHeaderActionComponent: () => new AddMenu(),
    createWatermarkComponent: () => new Empty(),
  });
  dock.onDidRemovePanel((p: IDockviewPanel) => {
    // A restore replaces panels, it does not close them
    if (restoring) return;
    // Closed in the viewer: R stops keeping (and restoring) a pushed panel
    if (!byR.delete(p.id) && payloads.has(p.id)) sendToR('panel_closed', { id: p.id });
    payloads.delete(p.id);
  });
  defaultLayout(host);
  dock.onDidLayoutChange(save);
  save();
  store.subscribe(s => s.layout, applyLayout);
}

// Built-in panels follow the metadata: rebuilt when a new table arrives
export function refreshBuiltins(): void {
  for (const v of views.values()) if (v.kind !== 'spec') v.fill();
}

// A panel pushed from R. An existing id is refilled where it is; a new one is
// placed by `where` next to `ref` (default: the active panel), or at the dock's
// edge without a ref.
export function pushPanel(p: PanelPayload): void {
  if (!dock) return;
  payloads.set(p.id, p);
  const existing = dock.getPanel(p.id);
  if (existing) {
    const v = views.get(p.id);
    if (v?.kind !== 'spec') { reportError(new Error(`'${p.id}' is a built-in panel`), 'push_panel'); return; }
    if (p.title) existing.api.setTitle(p.title);
    v.fill();
    if (!p.restore) existing.api.setActive();
    return;
  }
  let ref = p.ref ? dock.getPanel(p.ref) : undefined;
  if (p.ref && !ref) reportError(new Error(`no panel '${p.ref}'; placed next to the active one`), 'push_panel');
  ref ??= dock.activePanel;
  const where = p.where ?? 'tab';
  const position: AddPanelOptions['position'] =
    where === 'tab' ? (ref ? { referencePanel: ref, direction: 'within' } : undefined)
    : ref && p.ref ? { referencePanel: ref, direction: where }
    : { direction: where };
  const title = p.title ?? (typeof p.spec?.title === 'string' ? p.spec.title : null) ?? p.id;
  dock.addPanel({ id: p.id, component: 'spec', title, ...(position && { position }) });
}

export function removePanel(id: string): boolean {
  const p = dock?.getPanel(id);
  if (!dock || !p) return false;
  byR.add(id);
  dock.removePanel(p);
  return true;
}

// For R's state(): what is docked, and where
export function listPanels(): { id: string; kind: string; title: string; group: string; visible: boolean }[] {
  return (dock?.panels ?? []).map(p => ({
    id: p.id, kind: views.get(p.id)?.kind ?? '', title: p.title ?? p.id,
    group: p.group.id, visible: p.api.isVisible,
  }));
}

// For tests and the browser console: a panel's handle (its Vega view, ...)
export const panelHandle = (id: string): PanelHandle | null => views.get(id)?.panel ?? null;
