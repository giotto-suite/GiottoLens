// The page's panels (dockview-core): tabs and splits, placed from R by
// push_panel() and movable by dragging a tab. The spatial view docks too
// (adr/0023); the tools rail at the left edge, the tray at the right
// (panels/tray.ts) and the selection bar along the bottom do not.
//
// Each panel has a stable id: R's selection rules, push_panel(id =) and the
// saved layout all refer to it, so moving a panel changes nothing else. The
// layout is config (store `layout`): it is saved through R and restored after
// a reload. Charts (scatter, histogram, density, table) are rebuilt from metadata;
// pushed panels from the payload R keeps and sends again on reconnect.
// The spatial view is one per viewer, with its kind as id, and can be closed
// and opened again from a "+" menu. The controls (cells, layers, ...) are not
// docked: they are the tray's (panels/tray.ts, adr/0027); nor is the Analysis
// panel, the left tray's (panels/drawer.ts, adr/0032). A group's tab bar splits it, leaving an empty pane beside it
// that lists what can be shown there; a pane emptied by closing or moving its
// last panel goes, as dockview does by default.
// Why dockview-core 4, and why R holds the saved config: adr/0009.
import {
  createDockview, themeDark,
  type DockviewApi, type IContentRenderer, type GroupPanelPartInitParameters,
  type IHeaderActionsRenderer, type IGroupHeaderProps, type IWatermarkRenderer,
  type AddPanelOptions, type SerializedDockview, type IDockviewPanel,
  type DockviewGroupPanel, type IDockviewGroupPanel, type WatermarkRendererInitParameters,
} from 'dockview-core';
import 'dockview-core/dist/styles/dockview.css';
import { createIcons, icons } from 'lucide';
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
import { createTablePanel } from './table.ts';
import { setTrayHidden, trayHidden, metadataNote } from './tray.ts';
import { setDrawerHidden } from './drawer.ts';
import { moduleView } from './modules.ts';
import { createSpatialPanel } from '../spatial/view.ts';
// @ts-ignore: plain JS module
import { abortAllTiles } from '../data/schedule.js';

// The built-in panels: the views, which the "+" menus offer. A chart
// (`meta`) shows a note until metadata arrives and is rebuilt when it
// changes; there can be several. A `single` panel is one per viewer, its id
// is its kind, and it follows the store itself. `available`: whether this
// launch has what the panel shows.
interface PanelType {
  create(body: HTMLElement, ctx: PanelCtx): PanelHandle;
  meta?: boolean;
  single?: boolean;
  available?(): boolean;
}
const TYPES = {
  spatial:     { create: createSpatialPanel, single: true,
                 available: () => !!(state.cells || state.manifest?.layers?.transcripts) },
  scatter:     { create: createScatterPanel, meta: true },
  histogram:   { create: createHistogramPanel, meta: true },
  density:     { create: createDensityPanel, meta: true },
  table:       { create: createTablePanel, meta: true },
} satisfies Record<string, PanelType>;
export type PanelKind = keyof typeof TYPES | 'spec';
type BuiltinKind = keyof typeof TYPES;
const typeOf = (kind: string): PanelType | undefined => (TYPES as Record<string, PanelType>)[kind];
const available = (kind: BuiltinKind) => typeOf(kind)!.available?.() ?? true;
// What the "+" menus offer
const builtins = () => (Object.keys(TYPES) as BuiltinKind[]).filter(available);
const isSingle = (kind: string | undefined) => !!kind && !!typeOf(kind)?.single;

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
let dockHost: HTMLElement | null = null;
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
    // overwritten by the one it was added with (and the panel is in its group)
    queueMicrotask(() => {
      if (views.get(this.id) !== this) return;
      this.fill();
    });
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
      } else if (typeOf(this.kind)!.meta && !state.metaInfo?.size) {
        this.element.append(metadataNote('to fill this panel'));
      } else {
        this.handle = typeOf(this.kind)!.create(this.element, this.ctx());
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

// "+" in each group's tab bar: add a built-in panel there. Beside it, the
// buttons that split the group to the right or below.
class AddMenu implements IHeaderActionsRenderer {
  readonly element = el('div', 'dock-actions');
  private off = new AbortController();
  init({ group }: IGroupHeaderProps): void {
    const split = (direction: 'right' | 'below', icon: string, title: string) => {
      const b = el('button', 'dock-split') as HTMLButtonElement;
      b.title = title;
      b.dataset.split = direction;
      const i = document.createElement('i');
      i.dataset.lucide = icon;
      b.append(i);
      b.addEventListener('click', () => splitGroup(group, direction));
      return b;
    };
    const btn = el('button', 'dock-add', '+') as HTMLButtonElement;
    btn.title = 'add a panel';
    const menu = el('div', 'dock-menu');
    // Built when opened: a control already docked is shown, not added again
    const fill = () => menu.replaceChildren(...builtins().map(kind => {
      const item = el('button', '', kind) as HTMLButtonElement;
      item.addEventListener('click', () => {
        menu.classList.remove('open');
        showIn(kind, group);
      });
      return item;
    }));
    // One menu open at a time: stopPropagation() keeps the document listener
    // from closing this one, so the others are closed here
    btn.addEventListener('click', e => {
      e.stopPropagation();
      const opening = !menu.classList.contains('open');
      document.querySelectorAll('.dock-menu.open').forEach(m => m.classList.remove('open'));
      if (opening) { fill(); menu.classList.add('open'); }
    });
    document.addEventListener('click', () => menu.classList.remove('open'), { signal: this.off.signal });
    this.element.append(split('right', 'columns-2', 'split right'), split('below', 'rows-2', 'split down'), btn, menu);
    createIcons({ icons, root: this.element });
  }
  dispose(): void { this.off.abort(); this.element.remove(); }
}

// An empty pane beside a group, half its size
function splitGroup(group: IDockviewGroupPanel, direction: 'right' | 'below'): void {
  dock?.addGroup({ referenceGroup: group.id, direction });
}

// A built-in panel shown in a group. One per viewer that is open elsewhere
// moves into an empty pane, which it was picked to fill; into a pane with
// panels, the "+" menu's rule holds: it is brought forward where it is.
function showIn(kind: BuiltinKind, group: IDockviewGroupPanel): void {
  const open = isSingle(kind) ? dock?.getPanel(kind) : undefined;
  const to = dock?.groups.find(g => g.id === group.id);
  if (open && to && group.panels.length === 0) open.api.moveTo({ group: to, position: 'center' });
  else addBuiltin(kind, { referenceGroup: group.id, direction: 'within' });
}

// The empty space: with every panel closed, or a pane a split left empty
// (`group`), which offers the "+" menu's panels in place and can be closed
class Empty implements IWatermarkRenderer {
  readonly element = el('div', 'dock-empty');
  init({ group: g }: WatermarkRendererInitParameters): void {
    this.element.append(el('div', '', g ? 'Show here:' : 'No panels. Add one:'));
    for (const kind of builtins()) {
      const b = el('button', '', kind);
      b.addEventListener('click', () => g ? showIn(kind, g) : addBuiltin(kind));
      this.element.append(b);
    }
    if (g) {
      const close = el('button', 'dock-empty-close', 'close pane');
      close.addEventListener('click', () => dock?.removeGroup(g));
      this.element.append(close);
    }
  }
}

// The view's width in a layout of its own: 65% of the dock (the tools rail
// and the tray are outside it), as it had beside the charts before it docked
const viewWidth = () => Math.round(0.65 * (dockHost?.clientWidth ?? 0));

function newId(kind: string): string {
  if (!dock?.getPanel(kind)) return kind;
  for (let i = 2; ; i++) if (!dock.getPanel(`${kind}-${i}`)) return `${kind}-${i}`;
}

// A built-in panel brought forward (opened if closed), as a module's view is
function showBuiltin(kind: BuiltinKind): void {
  if (!dock || !available(kind)) return;
  if (!dock.getPanel(kind)) {
    actions.setPanelClosed(kind, false);
    addBuiltin(kind);
  }
  dock.getPanel(kind)?.api.setActive();
}

function addBuiltin(kind: BuiltinKind, position?: AddPanelOptions['position']): void {
  if (!dock) return;
  if (isSingle(kind)) {
    actions.setPanelClosed(kind, false);
    const open = dock.getPanel(kind);
    if (open) { open.api.setActive(); return; }
  }
  const p = dock.addPanel({ id: isSingle(kind) ? kind : newId(kind), component: kind, title: kind,
    ...(position && { position }) });
  // A view opened again in a group of its own gets its usual width; in a pane
  // it fills, the pane's
  const into = !!position && 'direction' in position && position.direction === 'within';
  if (kind === 'spatial' && !into && p.group.panels.length === 1 && viewWidth() > 0)
    queueMicrotask(() => p.group.api.setSize({ width: viewWidth() }));
}

// The spatial view at the left, the scatter beside it and the table below
// that; other charts are added from a pane's +
function defaultLayout(host: HTMLElement): void {
  if (!dock) return;
  const view = available('spatial');
  if (view) dock.addPanel({ id: 'spatial', component: 'spatial', title: 'spatial' });
  dock.addPanel({ id: 'scatter', component: 'scatter', title: 'scatter',
    ...(view && { position: { referencePanel: 'spatial', direction: 'right' } }) });
  // Tabs when the dock is short
  const tabs = host.clientHeight > 0 && host.clientHeight < 420;
  dock.addPanel({ id: 'table', component: 'table', title: 'table',
    position: { referencePanel: 'scatter', direction: tabs ? 'within' : 'below' }, inactive: tabs });
  placeFixed(host, true);
}

// The spatial view, unless it was closed by hand, when a layout lacks it
// (one saved before it docked), at viewWidth(); and that width on the first
// layout (`all`), once everything is placed, since each insert splits its
// neighbour's width
function placeFixed(host: HTMLElement | null = dockHost, all = false): void {
  if (!dock) return;
  const closed = store.getState().closedPanels;
  let view = false;
  if (available('spatial') && !closed.includes('spatial') && !dock.getPanel('spatial')) {
    dock.addPanel({ id: 'spatial', component: 'spatial', title: 'spatial', position: { direction: 'left' } });
    view = true;
  }
  if ((view || all) && host?.clientWidth) dock.getPanel('spatial')?.group.api.setSize({ width: viewWidth() });
}

// Panel ids in layout order: groups left to right and top to bottom, then
// tabs. A reload keeps it; dockview's own list is in order of creation.
function layoutIds(): string[] {
  if (!dock) return [];
  type Node = { type: 'leaf' | 'branch'; data: any };
  const ids: string[] = [];
  const walk = (n: Node) => n.type === 'leaf' ? ids.push(...n.data.views) : n.data.forEach(walk);
  walk(dock.toJSON().grid.root as Node);
  return ids;
}

// Single panels this launch does not have (a saved layout from another
// launch), and kinds no longer docked: the Preferences tab, the controls of a
// layout saved before the tray, which shows them by its own config, and the
// tools bar, now the tools rail
function dropUnavailable(): void {
  if (!dock) return;
  for (const p of [...dock.panels]) {
    const kind = views.get(p.id)?.kind;
    if (kind && kind !== 'spec' && !typeOf(kind)) dock.removePanel(p);
    else if (isSingle(kind) && !available(kind as BuiltinKind)) dock.removePanel(p);
  }
}

// Where a pushed panel goes without a `ref`: next to the active chart, else
// the last one active, else any chart, never beside the spatial view
let lastChart: string | null = null;
const isChart = (p?: IDockviewPanel | null) => !!p && !isSingle(views.get(p.id)?.kind);
function chartRef(): IDockviewPanel | undefined {
  if (!dock) return undefined;
  if (isChart(dock.activePanel)) return dock.activePanel!;
  const last = lastChart ? dock.getPanel(lastChart) : undefined;
  return isChart(last) ? last : dock.panels.find(isChart);
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
    dropUnavailable();
  } catch (e) {
    reportError(e, 'restoring the panel layout');
  } finally {
    restoring = false;
  }
  placeFixed();
  // Pushed panels R no longer holds cannot be filled; ones the layout lacks
  // (pushed before this page saved one) are placed again
  const held = heldPanels();
  if (held) for (const p of [...dock.panels])
    if (views.get(p.id)?.kind === 'spec' && !held.has(p.id)) { byR.add(p.id); dock.removePanel(p); }
  for (const p of payloads.values()) if (!dock.getPanel(p.id)) pushPanel({ ...p, restore: true });
  // A restore shows every pane: the module on keeps its view alone
  focusView(moduleView());
  save();
}

export function initDock(host: HTMLElement): void {
  dockHost = host;
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
    // A control or the spatial view closed in the viewer or by R stays closed
    // after a reload; a view closed by hand lets go of its tiles
    if (isSingle(p.id)) actions.setPanelClosed(p.id, true);
    if (p.id === 'spatial') abortAllTiles({ release: true });
    // Closed in the viewer: R stops keeping (and restoring) a pushed panel
    if (!byR.delete(p.id) && payloads.has(p.id)) sendToR('panel_closed', { id: p.id });
    payloads.delete(p.id);
  });
  dock.onDidActivePanelChange(p => { if (isChart(p)) lastChart = p!.id; });
  // Its real size first: dockview otherwise lays out at 0 x 0 until its
  // resize observer fires, and the default sizes come out wrong
  dock.layout(host.clientWidth, host.clientHeight);
  defaultLayout(host);
  dock.onDidLayoutChange(save);
  save();
  store.subscribe(s => s.layout, applyLayout);
}

// One view alone in the data area, its pane maximized (dockview hides the
// others and keeps the layout as it was when saving it), or every pane again
// with null. A module asks for its view (panels/modules.ts), and the panels
// toggle for the spatial view's. Making another pane active ends it, as when
// R pushes a panel. The view is opened if closed.
// dockview gives the panes back their shares of the width the dock had while
// one was alone, so the pane focused gets its own width back on leaving.
let unfocused: { group: DockviewGroupPanel; width: number } | null = null;
export function focusView(id: string | null): void {
  if (!dock) return;
  if (!id) {
    if (!dock.hasMaximizedGroup()) return;
    dock.exitMaximizedGroup();
    if (unfocused && dock.groups.includes(unfocused.group)) unfocused.group.api.setSize({ width: unfocused.width });
    unfocused = null;
    return;
  }
  let p = dock.getPanel(id);
  if (!p && isSingle(id) && available(id as BuiltinKind)) { showBuiltin(id as BuiltinKind); p = dock.getPanel(id); }
  if (!p) return;
  p.api.setActive();
  if (p.api.isMaximized()) return;
  if (dock.hasMaximizedGroup()) focusView(null);
  unfocused = { group: p.group, width: p.group.api.width };
  dock.maximizeGroup(p);
}

// The bottom bar's panels toggle (ui/selbar.js): the spatial view alone, both trays
// hidden too, or everything back. With a module on, the data area keeps the
// module's view alone and the toggle hides or shows the tray.
export function panelsShown(): boolean {
  return !dock || (!trayHidden() && (!dock.hasMaximizedGroup() || !!moduleView()));
}
export function togglePanels(): void {
  if (!dock) return;
  const show = !panelsShown();
  // The dock's width changes with the tray's, laid out at once rather than at
  // its resize observer. The view is focused before it widens and let go
  // after it narrows, so focusView() keeps and gives back its width as laid
  // out beside the tray.
  const relayout = () => { if (dockHost) dock?.layout(dockHost.clientWidth, dockHost.clientHeight); };
  if (!show) focusView('spatial');
  setTrayHidden(!show);
  setDrawerHidden(!show);
  relayout();
  if (show) focusView(moduleView());
}
export function onLayoutChange(fn: () => void): () => void {
  const d = dock?.onDidLayoutChange(fn);
  return () => d?.dispose();
}

// Charts follow the metadata: rebuilt when a new table arrives
export function refreshBuiltins(): void {
  for (const v of views.values()) if (typeOf(v.kind)?.meta) v.fill();
}

// Charts that take the theme's colours when built (ui/theme.ts): rebuilt
// when it changes. The scatter is dark in both themes.
const THEMED = new Set<PanelKind>(['histogram', 'density', 'spec']);
export function refreshCharts(): void {
  for (const v of views.values()) if (THEMED.has(v.kind)) v.fill();
}

// A panel pushed from R. An existing id is refilled where it is; a new one is
// placed by `where` next to `ref`, by default next to the charts (chartRef()),
// or at the dock's left edge when there are none.
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
  if (p.ref && !ref) reportError(new Error(`no panel '${p.ref}'; placed next to the charts`), 'push_panel');
  ref ??= chartRef();
  const where = p.where ?? 'tab';
  const position: AddPanelOptions['position'] = !ref ? { direction: 'left' }
    : { referencePanel: ref, direction: where === 'tab' ? 'within' : where };
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

// For R's state(): what is docked, and where, in layout order
export function listPanels(): { id: string; kind: string; title: string; group: string; visible: boolean }[] {
  return layoutIds().map(id => dock!.getPanel(id)).filter(p => !!p).map(p => ({
    id: p.id, kind: views.get(p.id)?.kind ?? '', title: p.title ?? p.id,
    group: p.group.id, visible: p.api.isVisible,
  }));
}

// For tests and the browser console: a panel's handle (its Vega view, ...)
export const panelHandle = (id: string): PanelHandle | null => views.get(id)?.panel ?? null;
