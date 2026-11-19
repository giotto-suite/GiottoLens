// The page's panels (dockview-core): tabs and splits, placed from R by
// push_panel() and movable by dragging a tab. The spatial view and the tools
// bar dock too (adr/0023); the selection bar along the bottom does not.
//
// Each panel has a stable id: R's selection rules, push_panel(id =) and the
// saved layout all refer to it, so moving a panel changes nothing else. The
// layout is config (store `layout`): it is saved through R and restored after
// a reload. Charts (scatter, histogram, density, table) are rebuilt from metadata;
// pushed panels from the payload R keeps and sends again on reconnect.
// Controls (cells, transcripts, data, regions, images, annotations, register, layers)
// are one per viewer, with their kind as id, and keep their own state in the store
// (adr/0016). So are the spatial view, which can be closed and opened again
// from a "+" menu, and the tools bar, which cannot be closed.
// Why dockview-core 4, and why R holds the saved config: adr/0009.
import {
  createDockview, themeDark, LayoutPriority,
  type DockviewApi, type IContentRenderer, type GroupPanelPartInitParameters,
  type IHeaderActionsRenderer, type IGroupHeaderProps, type IWatermarkRenderer,
  type AddPanelOptions, type SerializedDockview, type IDockviewPanel, type ITabRenderer,
  type DockviewGroupPanel,
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
import { createCellsPanel } from './cells.ts';
import { createTranscriptsPanel } from './transcripts.ts';
import { createDataPanel } from './data.ts';
import { createTablePanel } from './table.ts';
import { createRegionsPanel } from './regions.ts';
import { createImagesPanel } from './images.ts';
import { createAnnotationsPanel } from './annotations.ts';
import { createRegisterPanel } from './register.ts';
import { createLayersPanel } from './layers.ts';
import { createToolsPanel } from './tools.ts';
import { createSpatialPanel } from '../spatial/view.ts';
// @ts-ignore: plain JS module
import { abortAllTiles } from '../data/schedule.js';
// @ts-ignore: plain JS module
import { createAnalysisPanel } from './analysis.js';

// The built-in panels. A chart (`meta`) shows a note until metadata arrives
// and is rebuilt when it changes; there can be several. A `single` panel is
// one per viewer, its id is its kind, and it follows the store itself; a
// control is a single one with a `slot`. `available`: whether this launch has
// what the panel shows. `slot`: controls in one slot are tabs of one group,
// the first one shown; slots stack in the controls' column in the order
// below, `height` px tall where given. `fixed`: never closed, nor offered in
// the "+" menus.
interface PanelType {
  create(body: HTMLElement, ctx: PanelCtx): PanelHandle;
  meta?: boolean;
  single?: boolean;
  slot?: string;
  height?: number;
  fixed?: boolean;
  available?(): boolean;
}
const hasImages = () => !!state.images?.size;
const TYPES = {
  spatial:     { create: createSpatialPanel, single: true,
                 available: () => !!(state.cells || state.manifest?.layers?.transcripts) },
  tools:       { create: createToolsPanel, single: true, fixed: true },
  scatter:     { create: createScatterPanel, meta: true },
  histogram:   { create: createHistogramPanel, meta: true },
  density:     { create: createDensityPanel, meta: true },
  table:       { create: createTablePanel, meta: true },
  // Two tabs at most per slot: more do not fit the column's tab bar
  cells:       { create: createCellsPanel, single: true, slot: 'data', available: () => !!state.cells },
  transcripts: { create: createTranscriptsPanel, single: true, slot: 'data',
                 available: () => !!state.manifest?.layers?.transcripts },
  // A giotto object shown: R has a catalog to pull from
  data:        { create: createDataPanel, single: true, slot: 'sources',
                 available: () => !!state.cells && !!state.manifest?.catalog },
  // The object's analysis (viewer$analysis()): opened from "+" or when R starts one
  analysis:    { create: createAnalysisPanel, single: true,
                 available: () => !!state.cells && !!state.manifest?.catalog },
  // Regions of the object's cells and their comparison, a tab beside the Data panel
  regions:     { create: createRegionsPanel, single: true, slot: 'sources',
                 available: () => !!state.cells && !!state.manifest?.catalog },
  images:      { create: createImagesPanel, single: true, slot: 'images', height: 220, available: hasImages },
  register:    { create: createRegisterPanel, single: true, slot: 'images', height: 220, available: hasImages },
  annotations: { create: createAnnotationsPanel, single: true, slot: 'annotations', height: 150 },
  layers:      { create: createLayersPanel, single: true, slot: 'layers', height: 130 },
} satisfies Record<string, PanelType>;
export type PanelKind = keyof typeof TYPES | 'spec';
type BuiltinKind = keyof typeof TYPES;
const typeOf = (kind: string): PanelType | undefined => (TYPES as Record<string, PanelType>)[kind];
const available = (kind: BuiltinKind) => typeOf(kind)!.available?.() ?? true;
// What the "+" menus offer
const builtins = () => (Object.keys(TYPES) as BuiltinKind[]).filter(k => available(k) && !typeOf(k)!.fixed);
const isSingle = (kind: string | undefined) => !!kind && !!typeOf(kind)?.single;
const isControl = (kind: string | undefined) => !!kind && !!typeOf(kind)?.slot;
export const CONTROL_WIDTH = 260;   // px, the controls' column in the default layout
const TOOLS_WIDTH = 40;             // px, the tools bar: one column of icons
const TOOLS_MAX = 80;               // px, at most two columns (index.html .tools-bar: 32 px + 4 px gap)

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
    if (this.kind === 'tools') api.onDidGroupChange(() => toolsGroup(api.group));
    // After addPanel() has finished, so a title the panel sets is not
    // overwritten by the one it was added with (and the panel is in its group)
    queueMicrotask(() => {
      if (views.get(this.id) !== this) return;
      if (this.kind === 'tools') toolsGroup(api.group);
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
        this.element.append(el('div', 'panel-note', 'Push metadata from R to fill this panel: viewer$push_metadata(g)'));
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

// "+" in each group's tab bar: add a built-in panel there
class AddMenu implements IHeaderActionsRenderer {
  readonly element = el('div', 'dock-actions');
  private off = new AbortController();
  init({ group }: IGroupHeaderProps): void {
    const btn = el('button', 'dock-add', '+') as HTMLButtonElement;
    btn.title = 'add a panel';
    const menu = el('div', 'dock-menu');
    // Built when opened: a control already docked is shown, not added again
    const fill = () => menu.replaceChildren(...builtins().map(kind => {
      const item = el('button', '', kind) as HTMLButtonElement;
      item.addEventListener('click', () => {
        menu.classList.remove('open');
        // Never into the tools bar's group: beside it
        const tools = group.panels.some(p => p.id === 'tools');
        addBuiltin(kind, { referenceGroup: group.id, direction: tools ? 'right' : 'within' });
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
    this.element.append(btn, menu);
  }
  dispose(): void { this.off.abort(); this.element.remove(); }
}

// The tools bar's "+": the same menu, the panel added beside the bar. It is
// how a closed spatial view comes back when no other group is left.
export function openAddMenu(anchor: HTMLElement): void {
  const doc = anchor.ownerDocument;
  doc.querySelectorAll('.dock-menu.open').forEach(m => m.classList.remove('open'));
  const menu = el('div', 'dock-menu open dock-menu-float');
  const r = anchor.getBoundingClientRect();
  Object.assign(menu.style, { left: `${r.right + 4}px`, top: `${r.top}px`, right: 'auto' });
  const close = () => { menu.remove(); doc.removeEventListener('click', close); };
  menu.append(...builtins().map(kind => {
    const item = el('button', '', kind) as HTMLButtonElement;
    item.addEventListener('click', () => {
      close();
      const tools = dock?.getPanel('tools');
      addBuiltin(kind, tools ? { referenceGroup: tools.group.id, direction: 'right' } : undefined);
    });
    return item;
  }));
  doc.body.append(menu);
  setTimeout(() => doc.addEventListener('click', close));   // not the click that opened it
}

// With every panel closed
class Empty implements IWatermarkRenderer {
  readonly element = el('div', 'dock-empty');
  init(): void {
    this.element.append(el('div', '', 'No panels. Add one:'));
    for (const kind of builtins()) {
      const b = el('button', '', kind);
      b.addEventListener('click', () => addBuiltin(kind));
      this.element.append(b);
    }
  }
}

// The tools bar's tab: a grip to drag it by, with no title or close button
class GripTab implements ITabRenderer {
  readonly element = el('div', 'dock-grip');
  init(): void {
    this.element.title = 'drag to move the tools bar';
    this.element.textContent = '⠿';
  }
}

// The tools bar alone in its group keeps it narrow: no "+", no panels dropped
// into it (see initDock()), a width of one or two columns of icons, and low layout priority,
// so room freed by a closed or hidden panel, or a wider window, goes to the
// others. dockview sets a group's priority only for groups it makes itself;
// `_priority` is read on every layout (dockview-core 4.13.1, pinned).
function toolsGroup(group: DockviewGroupPanel): void {
  for (const g of dock?.groups ?? []) g.element.classList.toggle('lens-tools-group', false);
  if (group.panels.length !== 1) return;
  group.element.classList.add('lens-tools-group');
  group.locked = 'no-drop-target';
  group.api.setConstraints({ minimumWidth: TOOLS_WIDTH, maximumWidth: TOOLS_MAX });
  (group as unknown as { _priority: LayoutPriority })._priority = LayoutPriority.Low;
}

// The tools bar keeps the width it was left at. dockview shares a removed
// group's room out evenly along its row and splits a group beside a new one,
// the bar included (its low priority does not apply there), so after either
// the bar gets its width back. A restored layout brings its own width.
let toolsWidth = TOOLS_WIDTH, toolsHold = false;
function holdTools(): void {
  if (toolsHold) return;
  toolsHold = true;
  queueMicrotask(() => {
    const g = dock?.getPanel('tools')?.group;
    if (g) { toolsGroup(g); g.api.setSize({ width: toolsWidth }); }
    toolsHold = false;
  });
}
// A panel's width in a saved layout, where its group is in a row
function savedWidth(layout: SerializedDockview, id: string): number | null {
  type Node = { type: 'leaf' | 'branch'; data: any; size: number };
  let out: number | null = null;
  const walk = (n: Node, inRow: boolean) => {
    if (n.type === 'leaf') { if (inRow && n.data.views.includes(id)) out = n.size; return; }
    n.data.forEach((c: Node) => walk(c, !inRow));
  };
  // The root's children are laid out along its orientation
  walk(layout.grid.root as Node, layout.grid.orientation !== 'HORIZONTAL');
  return out;
}

// The view's width in a layout of its own: 65% of what the tools and the
// controls leave, as it had beside the charts before it docked
const viewWidth = () => Math.round(0.65 * ((dockHost?.clientWidth ?? 0) - CONTROL_WIDTH - TOOLS_WIDTH));

function newId(kind: string): string {
  if (!dock?.getPanel(kind)) return kind;
  for (let i = 2; ; i++) if (!dock.getPanel(`${kind}-${i}`)) return `${kind}-${i}`;
}

// A built-in panel brought forward (opened if closed), as R asks when it
// gives the panel something new: a saved region
export function showBuiltin(kind: BuiltinKind): void {
  if (!dock || !available(kind)) return;
  if (!dock.getPanel(kind)) {
    actions.setPanelClosed(kind, false);
    if (isControl(kind)) placeControls(); else addBuiltin(kind);
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
  // Opened from "+" with no place given, the Analysis panel goes where it opens from R
  if (kind === 'analysis' && !position) { placeAnalysis(); return; }
  const p = dock.addPanel({ id: isSingle(kind) ? kind : newId(kind), component: kind, title: kind,
    ...(position && { position }) });
  // A view opened again in a group of its own gets its usual width, after the
  // tools bar has its own back (holdTools())
  if (kind === 'spatial' && p.group.panels.length === 1 && viewWidth() > 0)
    queueMicrotask(() => p.group.api.setSize({ width: viewWidth() }));
}

// The tools bar at the left edge, the spatial view beside it, the charts
// next, the controls in a column at the right edge
function defaultLayout(host: HTMLElement): void {
  if (!dock) return;
  const view = available('spatial');
  if (view) dock.addPanel({ id: 'spatial', component: 'spatial', title: 'spatial' });
  // Scatter above histogram, or as tabs when the dock is short
  dock.addPanel({ id: 'scatter', component: 'scatter', title: 'scatter',
    ...(view && { position: { referencePanel: 'spatial', direction: 'right' } }) });
  const tabs = host.clientHeight > 0 && host.clientHeight < 420;
  dock.addPanel({ id: 'histogram', component: 'histogram', title: 'histogram',
    position: { referencePanel: 'scatter', direction: tabs ? 'within' : 'below' }, inactive: tabs });
  dock.addPanel({ id: 'table', component: 'table', title: 'table',
    position: { referencePanel: 'histogram', direction: 'within' }, inactive: true });
  placeControls();
  placeFixed(host, true);
}

// The tools bar, and the spatial view unless it was closed by hand, when a
// layout lacks them (the first one, or one saved before they docked). Sized
// once everything is placed, since each insert splits its neighbour's width:
// the tools one column, the view viewWidth(), the controls their column
// (`all`, the first layout).
function placeFixed(host: HTMLElement | null = dockHost, all = false): void {
  if (!dock) return;
  const closed = store.getState().closedPanels;
  let view = false, tools = false;
  if (available('spatial') && !closed.includes('spatial') && !dock.getPanel('spatial')) {
    dock.addPanel({ id: 'spatial', component: 'spatial', title: 'spatial', position: { direction: 'left' } });
    view = true;
  }
  if (!dock.getPanel('tools')) {
    const p = dock.addPanel({ id: 'tools', component: 'tools', tabComponent: 'grip', title: 'tools',
      position: { direction: 'left' } });
    toolsGroup(p.group);   // now: a group is at least 100 px wide until then
    tools = true;
  }
  // In this order: a group's change is taken from the far end of the row
  if (tools || all) dock.getPanel('tools')?.group.api.setSize({ width: TOOLS_WIDTH });
  if ((view || all) && host?.clientWidth) dock.getPanel('spatial')?.group.api.setSize({ width: viewWidth() });
  if (all) dock.panels.find(p => isControl(views.get(p.id)?.kind))?.group.api.setSize({ width: CONTROL_WIDTH });
}

// Every control this launch has, unless closed by hand: a tab next to one in
// its slot, else a group above the next control in TYPES order (or under the
// last), else a column at the dock's right edge. A saved layout from before a
// control existed gets it here too, and so do controls whose data arrives
// after the dock (images).
export function placeControls(): void {
  if (!dock) return;
  const closed = store.getState().closedPanels;
  const order = (Object.keys(TYPES) as BuiltinKind[]).filter(isControl);
  let added = false;
  for (const kind of builtins()) {
    if (!isControl(kind) || closed.includes(kind) || dock.getPanel(kind)) continue;
    const { slot, height } = typeOf(kind)!;
    const controls = layoutIds().map(id => dock!.getPanel(id)!).filter(p => isControl(views.get(p.id)?.kind));
    const mate = controls.find(p => typeOf(p.id)?.slot === slot);
    const next = order.slice(order.indexOf(kind) + 1).map(k => dock!.getPanel(k)).find(p => !!p);
    const ref = mate ?? next ?? controls.at(-1);
    const direction = mate ? 'within' : next ? 'above' : ref ? 'below' : 'right';
    // Inactive only as a tab: a new group needs its panel active to draw it
    const panel = dock.addPanel({ id: kind, component: kind, title: kind, inactive: direction === 'within',
      position: ref ? { referencePanel: ref, direction } : { direction } });
    if (direction === 'right') panel.group.api.setSize({ width: CONTROL_WIDTH });
    added = true;
  }
  if (added) sizeControls();
}

// The controls' column: slots with a height get it, the others (the data)
// share what is left. Set top down, since dockview gives a group's change to
// the group below it; the last takes what rounding leaves.
function sizeControls(): void {
  if (!dock) return;
  const groups = [...new Set(layoutIds().map(id => dock!.getPanel(id)!)
    .filter(p => isControl(views.get(p.id)?.kind)).map(p => p.group))];
  const fixed = groups.map(g => Math.max(0, ...g.panels.map(p => typeOf(p.id)?.height ?? 0)) || null);
  const total = groups.reduce((h, g) => h + g.api.height, 0);
  const free = groups.length - fixed.filter(h => h).length;
  const rest = free ? (total - fixed.reduce<number>((h, f) => h + (f ?? 0), 0)) / free : 0;
  groups.slice(0, -1).forEach((g, i) => g.api.setSize({ height: Math.round(fixed[i] ?? rest) }));
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

// Controls this launch does not have (a saved layout from another launch)
function dropUnavailable(): void {
  if (!dock) return;
  for (const p of [...dock.panels]) {
    const kind = views.get(p.id)?.kind;
    if (isSingle(kind) && !available(kind as BuiltinKind)) dock.removePanel(p);
  }
}

// Where a pushed panel goes without a `ref`: next to the active chart, else
// the last one active, else any chart, never among the controls, beside
// the spatial view or the tools bar, or in the Analysis panel's group
let lastChart: string | null = null;
const isChart = (p?: IDockviewPanel | null) => {
  const kind = p ? views.get(p.id)?.kind : undefined;
  return !!p && !isSingle(kind) && kind !== 'analysis' &&
    !p.group.panels.some(q => views.get(q.id)?.kind === 'analysis');
};
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
    toolsWidth = savedWidth(layout as SerializedDockview, 'tools') ?? toolsWidth;
    dock.fromJSON(layout as SerializedDockview);
    dropUnavailable();
  } catch (e) {
    reportError(e, 'restoring the panel layout');
  } finally {
    restoring = false;
  }
  placeControls();
  placeFixed();
  // Pushed panels R no longer holds cannot be filled; ones the layout lacks
  // (pushed before this page saved one) are placed again
  const held = heldPanels();
  if (held) for (const p of [...dock.panels])
    if (views.get(p.id)?.kind === 'spec' && !held.has(p.id)) { byR.add(p.id); dock.removePanel(p); }
  for (const p of payloads.values()) if (!dock.getPanel(p.id)) pushPanel({ ...p, restore: true });
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
    createTabComponent: ({ name }) => name === 'grip' ? new GripTab() : undefined,
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
  dock.onDidLayoutChange(() => {
    const w = dock?.getPanel('tools')?.group.api.width;
    if (!toolsHold && w) toolsWidth = w;
  });
  dock.onDidAddGroup(holdTools);
  dock.onDidRemoveGroup(holdTools);
  // The tools bar's group takes no panels, as a tab or as a split of it (its
  // lock alone still shows drop targets and splits it); the bar itself moves
  // only into a group of its own, at an edge of another
  const toolsIn = (g?: DockviewGroupPanel) => !!g?.panels.some(p => p.id === 'tools');
  const refused = (e: { group?: DockviewGroupPanel; kind: string; position: string; getData(): { panelId: string | null } | undefined }) =>
    toolsIn(e.group) || (e.getData()?.panelId === 'tools' &&
      (e.kind === 'tab' || e.kind === 'header_space' || (e.kind === 'content' && e.position === 'center')));
  dock.onWillShowOverlay(e => { if (refused(e)) e.preventDefault(); });
  dock.onWillDrop(e => { if (refused(e)) e.preventDefault(); });
  // Its real size first: dockview otherwise lays out at 0 x 0 until its
  // resize observer fires, and the default sizes come out wrong
  dock.layout(host.clientWidth, host.clientHeight);
  defaultLayout(host);
  dock.onDidLayoutChange(save);
  save();
  store.subscribe(s => s.layout, applyLayout);
}

// The tools bar's panels toggle: every group but the spatial view's and the
// tools bar's is hidden, or shown again. Hidden groups are saved with the
// layout. Without a spatial view there is nothing to show alone.
const keepsShown = (g: DockviewGroupPanel) => g.panels.some(p => p.id === 'spatial' || p.id === 'tools');
export function panelsShown(): boolean {
  return !dock || dock.groups.every(g => keepsShown(g) || g.api.isVisible);
}
// Shown again, the hidden groups take their old widths from the view and the
// tools bar unevenly: both get theirs back
let shownWidths: { tools: number; view: number } | null = null;
export function togglePanels(): void {
  if (!dock) return;
  const tools = dock.getPanel('tools')?.group, view = dock.getPanel('spatial')?.group;
  const show = !panelsShown() || !view;
  if (!show && tools && view) shownWidths = { tools: tools.api.width, view: view.api.width };
  for (const g of dock.groups) if (!keepsShown(g)) g.api.setVisible(show);
  if (show && shownWidths) {
    tools?.api.setSize({ width: shownWidths.tools });
    view?.api.setSize({ width: shownWidths.view });
    shownWidths = null;
  }
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
  // A tab next to the Analysis panel goes beside its group instead
  const beside = where === 'tab' && !!ref && ref.group.panels.some(q => views.get(q.id)?.kind === 'analysis');
  const position: AddPanelOptions['position'] = !ref ? { direction: 'left' }
    : { referencePanel: ref, direction: beside ? 'right' : where === 'tab' ? 'within' : where };
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

// Where the Analysis panel opens: beside the tools bar, left of the spatial
// view, a third of the page wide; kept where the user or a restored layout
// put it
function placeAnalysis(): void {
  if (!dock || dock.getPanel('analysis')) return;
  const view = dock.getPanel('spatial'), tools = dock.getPanel('tools');
  const position: AddPanelOptions['position'] = view ? { referencePanel: view, direction: 'left' }
    : tools ? { referenceGroup: tools.group.id, direction: 'right' } : { direction: 'left' };
  const p = dock.addPanel({ id: 'analysis', component: 'analysis', title: 'analysis', position });
  p.group.api.setSize({ width: Math.round(window.innerWidth / 3) });
}
