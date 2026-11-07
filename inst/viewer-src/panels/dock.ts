// The panels, docked beside the spatial view (dockview-core): tabs and
// splits, placed from R by push_panel() and movable by dragging a tab. The
// spatial view is not a panel; it stays where it is.
//
// Each panel has a stable id: R's selection rules, push_panel(id =) and the
// saved layout all refer to it, so moving a panel changes nothing else. The
// layout is config (store `layout`): it is saved through R and restored after
// a reload. Charts (scatter, histogram, density) are rebuilt from metadata;
// pushed panels from the payload R keeps and sends again on reconnect.
// Controls (cells, transcripts, images, annotations, register, layers) are one
// per viewer, with their kind as id, and keep their own state in the store
// (adr/0016).
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
import { createCellsPanel } from './cells.ts';
import { createTranscriptsPanel } from './transcripts.ts';
import { createImagesPanel } from './images.ts';
import { createAnnotationsPanel } from './annotations.ts';
import { createRegisterPanel } from './register.ts';
import { createLayersPanel } from './layers.ts';

// The built-in panels. A chart (`meta`) shows a note until metadata arrives
// and is rebuilt when it changes; there can be several. A control (`single`)
// is one per viewer, its id is its kind, and it follows the store itself.
// `available`: whether this launch has what the panel shows. `slot`: controls
// in one slot are tabs of one group, the first one shown; slots stack in the
// controls' column in the order below, `height` px tall where given.
interface PanelType {
  create(body: HTMLElement, ctx: PanelCtx): PanelHandle;
  meta?: boolean;
  single?: boolean;
  slot?: string;
  height?: number;
  available?(): boolean;
}
const hasImages = () => !!state.images?.size;
const TYPES = {
  scatter:     { create: createScatterPanel, meta: true },
  histogram:   { create: createHistogramPanel, meta: true },
  density:     { create: createDensityPanel, meta: true },
  // Two tabs at most per slot: more do not fit the column's tab bar
  cells:       { create: createCellsPanel, single: true, slot: 'data', available: () => !!state.cells },
  transcripts: { create: createTranscriptsPanel, single: true, slot: 'data',
                 available: () => !!state.manifest?.layers?.transcripts },
  images:      { create: createImagesPanel, single: true, slot: 'images', height: 220, available: hasImages },
  register:    { create: createRegisterPanel, single: true, slot: 'images', height: 220, available: hasImages },
  annotations: { create: createAnnotationsPanel, single: true, slot: 'annotations', height: 150 },
  layers:      { create: createLayersPanel, single: true, slot: 'layers', height: 130 },
} satisfies Record<string, PanelType>;
export type PanelKind = keyof typeof TYPES | 'spec';
type BuiltinKind = keyof typeof TYPES;
const typeOf = (kind: string): PanelType | undefined => (TYPES as Record<string, PanelType>)[kind];
const available = (kind: BuiltinKind) => typeOf(kind)!.available?.() ?? true;
const builtins = () => (Object.keys(TYPES) as BuiltinKind[]).filter(available);
const isControl = (kind: string | undefined) => !!kind && !!typeOf(kind)?.single;
export const CONTROL_WIDTH = 260;   // px, the controls' column in the default layout

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
      } else if (typeOf(this.kind)!.meta && !state.meta?.size) {
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
        addBuiltin(kind, { referenceGroup: group.id, direction: 'within' });
      });
      return item;
    }));
    btn.addEventListener('click', e => {
      e.stopPropagation();
      if (!menu.classList.contains('open')) fill();
      menu.classList.toggle('open');
    });
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
    for (const kind of builtins()) {
      const b = el('button', '', kind);
      b.addEventListener('click', () => addBuiltin(kind));
      this.element.append(b);
    }
  }
}

function newId(kind: string): string {
  if (!dock?.getPanel(kind)) return kind;
  for (let i = 2; ; i++) if (!dock.getPanel(`${kind}-${i}`)) return `${kind}-${i}`;
}

function addBuiltin(kind: BuiltinKind, position?: AddPanelOptions['position']): void {
  if (!dock) return;
  if (isControl(kind)) {
    actions.setPanelClosed(kind, false);
    const open = dock.getPanel(kind);
    if (open) { open.api.setActive(); return; }
  }
  dock.addPanel({ id: isControl(kind) ? kind : newId(kind), component: kind, title: kind,
    ...(position && { position }) });
}

// Charts on the left, controls in a column on the right
function defaultLayout(host: HTMLElement): void {
  if (!dock) return;
  // Scatter above histogram, or as tabs when the dock is short
  dock.addPanel({ id: 'scatter', component: 'scatter', title: 'scatter' });
  const tabs = host.clientHeight > 0 && host.clientHeight < 420;
  dock.addPanel({ id: 'histogram', component: 'histogram', title: 'histogram',
    position: { referencePanel: 'scatter', direction: tabs ? 'within' : 'below' }, inactive: tabs });
  placeControls();
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
    if (isControl(kind) && !available(kind as BuiltinKind)) dock.removePanel(p);
  }
}

// Where a pushed panel goes without a `ref`: next to the active chart, else
// the last one active, else any chart, never among the controls
let lastChart: string | null = null;
function chartRef(): IDockviewPanel | undefined {
  if (!dock) return undefined;
  const isChart = (p?: IDockviewPanel | null) => !!p && !isControl(views.get(p.id)?.kind);
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
  placeControls();
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
    // A control closed in the viewer or by R stays closed after a reload
    if (isControl(p.id)) actions.setPanelClosed(p.id, true);
    // Closed in the viewer: R stops keeping (and restoring) a pushed panel
    if (!byR.delete(p.id) && payloads.has(p.id)) sendToR('panel_closed', { id: p.id });
    payloads.delete(p.id);
  });
  dock.onDidActivePanelChange(p => { if (p && !isControl(views.get(p.id)?.kind)) lastChart = p.id; });
  // Its real size first: dockview otherwise lays out at 0 x 0 until its
  // resize observer fires, and the default sizes come out wrong
  dock.layout(host.clientWidth, host.clientHeight);
  defaultLayout(host);
  dock.onDidLayoutChange(save);
  save();
  store.subscribe(s => s.layout, applyLayout);
}

// Charts follow the metadata: rebuilt when a new table arrives
export function refreshBuiltins(): void {
  for (const v of views.values()) if (typeOf(v.kind)?.meta) v.fill();
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
