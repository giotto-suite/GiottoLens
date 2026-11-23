// The spatial view as a dock panel (adr/0023): the deck.gl canvas, its tools,
// HUD, scalebar and overlays, built here and kept by reference, so the panel
// can move, close and open again. One Deck per view; closing the view
// finalizes it and gives back its WebGL context, as the scatter panel does.
import { Deck, OrthographicView } from 'deck.gl';
import { createIcons, icons } from 'lucide';
import { state } from '../core/state.js';
import { store, actions } from '../core/store.ts';
// @ts-ignore: plain JS module
import { scheduleTiles, setViewState, abortAllTiles } from '../data/schedule.js';
// @ts-ignore: plain JS module
import { requestRender } from '../render/schedule.js';
// @ts-ignore: plain JS module
import { updateScalebar, fitZoom, dragPan, viewportSize } from '../ui/dom.js';
// @ts-ignore: plain JS module
import { attachInput, updateRulerLabel, updateTxConnector } from '../ui/input.js';
// @ts-ignore: plain JS module
// @ts-ignore: plain JS module
import { hideCellTooltip } from '../ui/tooltip.js';
import { attachRegistration, onMainView } from '../ui/registration.ts';
import { spatialView, setSpatialView, type SpatialView } from './current.ts';
import type { PanelCtx, PanelHandle } from '../panels/dock.ts';

const TEMPLATE = `
  <canvas class="deck-canvas"></canvas>
  <div class="reg-pane" data-el="regPane" style="display:none"><canvas class="reg-canvas" data-el="regCanvas"></canvas><div class="reg-pane-label reg-image-label" data-el="regLabel"></div></div>
  <div class="reg-pane-label reg-ref-label" data-el="regRefLabel"></div>
  <svg class="tx-connector"><line data-el="txLine" x1="0" y1="0" x2="0" y2="0" stroke="#ffff64" stroke-width="1.5" display="none"/></svg>
  <div class="hud"><span class="hud-item" data-el="txSample"></span><span class="hud-item cursor-coords" data-el="coords"></span></div>
  <div class="toolbar">
    <button class="tool-btn active" data-mode="pan" title="pan (or, with any tool, hold Space or drag with the middle button)"><i data-lucide="hand"></i></button>
    <button class="tool-btn" data-el="fit" title="zoom to fit"><i data-lucide="maximize-2"></i></button>
    <div class="tool-group" data-group="measure">
      <button class="tool-btn tool-group-btn" title="measure"><i data-lucide="pencil-ruler"></i></button>
      <div class="tool-submenu">
        <button class="tool-btn" data-mode="ruler" title="ruler"><i data-lucide="ruler"></i></button>
        <button class="tool-btn" data-mode="txlasso" title="transcript lasso — count genes in region"><i data-lucide="scan-search"></i></button>
        <button class="tool-btn" data-el="clearMeasure" title="clear measurements"><i data-lucide="circle-x"></i></button>
      </div>
    </div>
    <div class="tool-sep"></div>
    <div class="tool-group" data-group="draw">
      <button class="tool-btn tool-group-btn" title="draw"><i data-lucide="pen-tool"></i></button>
      <div class="tool-submenu">
        <button class="tool-btn" data-mode="poly" title="polygon"><i data-lucide="pentagon"></i></button>
        <button class="tool-btn" data-mode="rect" title="rectangle"><i data-lucide="square"></i></button>
        <button class="tool-btn" data-mode="freehand" title="freehand"><i data-lucide="spline"></i></button>
      </div>
    </div>
    <div class="tool-sep"></div>
    <div class="tool-group" data-group="select">
      <button class="tool-btn tool-group-btn" title="select"><i data-lucide="mouse-pointer-2"></i></button>
      <div class="tool-submenu">
        <button class="tool-btn" data-mode="lasso" title="lasso (Shift adds, Alt or Ctrl/Cmd subtracts)"><i data-lucide="lasso"></i></button>
        <button class="tool-btn" data-mode="brush" title="brush select ([ and ] resize; Shift adds, Alt or Ctrl/Cmd subtracts)"><i data-lucide="paintbrush-2"></i></button>
      </div>
    </div>
  </div>
  <div class="scalebar"><div class="scalebar-bar" data-el="scalebarBar"></div><span class="scalebar-label" data-el="scalebarLabel"></span></div>
  <button class="tool-btn screenshot" data-el="screenshot" title="save screenshot"><i data-lucide="camera"></i></button>
  <div class="ruler-label" data-el="ruler"></div>
  <div class="cell-tooltip" data-el="tooltip"></div>
  <div class="tx-lasso-panel" data-el="txPanel">
    <div class="tx-lasso-hdr"><span class="tx-lasso-title" data-el="txTitle"></span><button class="tx-lasso-close" data-el="txClose">×</button></div>
    <div class="tx-lasso-results" data-el="txResults"></div>
  </div>`;

// The camera is saved with the config, a moment after it stops moving
let viewTimer: ReturnType<typeof setTimeout> | undefined;
export function saveView(viewState: any): void {
  clearTimeout(viewTimer);
  viewTimer = setTimeout(() => actions.setView({
    target: [viewState.target[0], viewState.target[1]], zoom: viewState.zoom,
  }), 250);
}

// A camera move from deck.gl's controller or a drag pan
function moveView(view: SpatialView, viewState: any): void {
  saveView(viewState);
  view.viewState = viewState;
  view.deck.setProps({ viewState });
  updateScalebar(view);
  updateRulerLabel();
  updateTxConnector();
  onMainView(viewState);
  requestRender();
  scheduleTiles(viewState);
}

// The view fitted to the manifest extent at the pane's size
function fitted(): any {
  const ext = state.manifest.extent;
  const zoom = fitZoom(ext.xmax - ext.xmin, ext.ymax - ext.ymin) - 0.3;
  return { target: [(ext.xmin + ext.xmax) / 2, (ext.ymin + ext.ymax) / 2, 0],
    zoom, minZoom: zoom - 2, maxZoom: zoom + 12 };
}

// Once the pane has a size: the saved camera, else the fitted one
function start(view: SpatialView): void {
  view.initialViewState = fitted();
  const saved = store.getState().view;
  setViewState(saved ? { ...view.initialViewState, target: [saved.target[0], saved.target[1], 0], zoom: saved.zoom }
    : view.initialViewState);
}

export function createSpatialPanel(body: HTMLElement, _ctx: PanelCtx): PanelHandle {
  const root = document.createElement('div');
  root.className = 'spatial-pane';
  root.innerHTML = TEMPLATE;
  body.append(root);
  const el: Record<string, HTMLElement> = {};
  root.querySelectorAll<HTMLElement>('[data-el]').forEach(e => { el[e.dataset.el!] = e; });
  // Polygons-only launch: no transcript tools
  if (!state.manifest.layers.transcripts) root.querySelector('[data-mode="txlasso"]')?.remove();
  createIcons({ icons, root });

  const off = new AbortController();
  const canvas = root.querySelector('.deck-canvas') as HTMLCanvasElement;
  const view: SpatialView = { root, canvas, deck: null, viewState: null, initialViewState: null,
    signal: off.signal, el, regDeck: null };
  view.deck = new Deck({
    canvas, width: '100%', height: '100%',
    views: new OrthographicView({ id: 'ortho', controller: true, flipY: false }),
    viewState: { target: [0, 0, 0], zoom: 0 }, controller: { doubleClickZoom: false },
    onViewStateChange: ({ viewState }: any) => moveView(view, viewState), layers: [],
  } as any);
  setSpatialView(view);
  dragPan(canvas, () => view.viewState, (vs: any) => moveView(view, vs), { signal: off.signal });

  el.fit.addEventListener('click', () => { if (view.viewState) setViewState({ ...fitted() }); });
  el.screenshot.addEventListener('click', () => {
    view.deck.redraw('screenshot');
    const a = document.createElement('a');
    a.href = canvas.toDataURL('image/png');
    a.download = `giottolens-${new Date().toISOString().slice(0, 19).replace(/[T:]/g, '-')}.png`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
  });

  attachInput(view);
  const detachReg = attachRegistration(view);

  // Started at its first size; resizes (dragging a sash, the panels toggle)
  // load what came into view
  const ro = new ResizeObserver(() => {
    const { width, height } = viewportSize(view);
    if (!width || !height) return;
    if (!view.viewState) { start(view); return; }
    updateScalebar(view);
    requestRender();
    scheduleTiles(view.viewState, 50);
  });
  ro.observe(root);

  return {
    destroy() {
      // A camera not saved yet goes with its view: a restore removes the view
      // the page started with, and its fitted camera would land on the restored one
      clearTimeout(viewTimer);
      off.abort();
      ro.disconnect();
      detachReg();
      hideCellTooltip();
      const gl = view.deck?.device?.gl;
      view.deck?.finalize();
      gl?.getExtension('WEBGL_lose_context')?.loseContext();
      if (spatialView() === view) setSpatialView(null);
      abortAllTiles();
      root.remove();
    },
  };
}
