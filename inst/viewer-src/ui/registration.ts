// Register an image by landmarks (adr/0014): the Register section of the side
// panel, the landmark tool (mode 'landmark') and the registration sent to R.
// In landmark mode the spatial view splits: the image being registered in its
// own pane on the left (its pixels, in the pane's orientation), the reference
// and the data on the right. A click in one pane places that side of a pair,
// a click in the other its partner, in either order. From three complete
// pairs on, the image is drawn with their least-squares affine fit.
import { Deck, OrthographicView } from 'deck.gl';
import { Matrix4 } from '@math.gl/core';
import { state } from '../core/state.js';
import { store, actions } from '../core/store.ts';
import { sendToR } from '../core/comms.js';
import { setViewState } from '../data/schedule.js';
import { requestRender } from '../render/schedule.js';
import { imageLayer } from '../render/image-layer.ts';
import { landmarkLayers, MOVING_COLOR, FIXED_COLOR, type Side, type LandmarkDrag } from '../render/landmarks.ts';
import { clientToWorld, fitZoom } from './dom.js';
import {
  apply, compose, invert, flip, rotate90, currentTransform, registrationFit, completePairs, matrix4,
  mapView, MIN_PAIRS, UPRIGHT, type Registration, type Landmark, type XY, type Affine,
} from '../data/registration.ts';
import { createIcons, icons } from 'lucide';

const $ = (id: string) => document.getElementById(id) as HTMLElement | null;
const css = ([r, g, b]: number[]) => `rgb(${r},${g},${b})`;

let _seq = 0;
const landmarkId = () => `lm_${Date.now().toString(36)}_${(_seq++).toString(36)}`;

function imageSize(name: string): { width: number; height: number } | null {
  const img = state.images?.get(name);
  return img ? { width: img.width, height: img.height } : null;
}

export function registering(): boolean {
  const s = store.getState();
  return s.mode === 'landmark' && !!s.registration;
}

// Start registering `image` against `reference`. `base` defaults to where the
// image is drawn now; `landmarks` to none
export function startRegistration(image: string, reference: string | null,
                                  opts: { base?: Affine; landmarks?: Omit<Landmark, 'id'>[] } = {}) {
  const img = state.images?.get(image);
  if (!img) throw new Error(`no image '${image}'`);
  if (reference != null && (reference === image || !state.images.has(reference)))
    throw new Error(`the reference must be another of the viewer's images, not '${reference}'`);
  const prev = store.getState().registration;
  const same = prev?.image === image;
  const base = opts.base ?? (same ? currentTransform(prev) : img.transform);
  actions.setRegistration({
    image, reference, base,
    landmarks: (opts.landmarks ?? []).map(l => ({ id: landmarkId(), moving: l.moving ?? null, fixed: l.fixed ?? null })),
    orient: same ? prev.orient ?? UPRIGHT : UPRIGHT,
    preview: same ? !!prev.preview : false,
    link: same ? !!prev.link : false,
  });
  actions.setImage(image, { show: true });
  if (reference) actions.setImage(reference, { show: true });
}

// What R keeps (LensViewer$registration): the landmarks, the base and the
// drawn transform, all pixels → data; `reference_transform` is the
// reference's own, so R can give the fit in reference pixels
export function registrationPayload(reg: Registration | null) {
  if (!reg) return { image: null };
  const fit = registrationFit(reg);
  const size = imageSize(reg.image);
  return {
    image: reg.image, reference: reg.reference,
    width: size?.width ?? null, height: size?.height ?? null,
    base: reg.base,
    landmarks: reg.landmarks.map(l => ({ id: l.id, moving: l.moving, fixed: l.fixed })),
    transform: fit?.transform ?? reg.base,
    fitted: !!fit,
    rmse: fit?.rmse ?? null,
    residuals: fit?.residuals ?? [],
    reference_transform: reg.reference ? state.images?.get(reg.reference)?.transform ?? null : null,
  };
}

// The pair with one side placed, if any
const pending = (reg: Registration) => reg.landmarks.find(l => !l.moving !== !l.fixed) ?? null;

// Pane coordinates → the side's stored coordinates (image pixels or data)
function stored(reg: Registration, side: Side, pt: XY): XY | null {
  if (side === 'fixed') return pt;
  const inv = invert(reg.orient);
  return inv ? apply(inv, pt) : null;
}

// A click in landmark mode at `pt`, in `side`'s pane: completes the open pair,
// moves its point when it is this side's, or starts a pair
export function landmarkClick(side: Side, pt: XY) {
  const reg = store.getState().registration;
  if (!reg) return;
  const value = stored(reg, side, pt);
  if (!value) return;
  const open = pending(reg);
  if (open) actions.updateLandmark(open.id, { [side]: value });
  else actions.addLandmark({ id: landmarkId(), moving: side === 'moving' ? value : null,
    fixed: side === 'fixed' ? value : null });
}

// ── Dragging ──────────────────────────────────────────────────────────────────
// A pane does not pan while the pointer is over one of its points. Mousedown
// there arms a drag, which starts once the pointer moves more than DRAG_PX;
// moves preview it and mouseup drops it. A press and release without moving
// stays a click.
const DRAG_PX = 4;
let _deck: any = null;            // the image's pane
let _vs: any = null;              // its view state
let _armed: { side: Side; id: string; pos: XY; x: number; y: number } | null = null;
let _dropped = false;
const _over: Record<Side, boolean> = { moving: false, fixed: false };
const deckOf = (side: Side) => side === 'fixed' ? state.deckgl : _deck;
const panController = (side: Side, pan: boolean) => deckOf(side)?.setProps({
  controller: pan ? { doubleClickZoom: false } : { dragPan: false, doubleClickZoom: false } });

const _hovers: Record<Side, (info: { picked?: boolean }) => void> = {
  moving: info => hover('moving', info), fixed: info => hover('fixed', info),
};
function hover(side: Side, info: { picked?: boolean }) {
  const over = !!info.picked && registering();
  if (over === _over[side] || state.landmarkDrag) return;
  _over[side] = over;
  panController(side, !over);
}
export const landmarkHover = (side: Side) => _hovers[side];

export function landmarkDragStart(side: Side, e: MouseEvent, canvas: HTMLCanvasElement): boolean {
  const deck = deckOf(side);
  if (!registering() || !deck) return false;
  const r = canvas.getBoundingClientRect();
  const picked = deck.pickObject({ x: e.clientX - r.left, y: e.clientY - r.top, radius: 6, layerIds: [`lm-${side}-points`] });
  if (!picked?.object) return false;
  _armed = { side, id: picked.object.id, pos: picked.object.pos, x: e.clientX, y: e.clientY };
  panController(side, false);
  return true;
}

export function landmarkDragMove(side: Side, pt: XY, e: MouseEvent): boolean {
  if (!state.landmarkDrag) {
    if (!_armed || _armed.side !== side || Math.hypot(e.clientX - _armed.x, e.clientY - _armed.y) <= DRAG_PX) return false;
    state.landmarkDrag = { id: _armed.id, which: side, pos: _armed.pos };
  }
  if (state.landmarkDrag.which !== side) return false;
  state.landmarkDrag = { ...state.landmarkDrag, pos: pt };
  return true;
}

// Ends a drag on mouseup; the click that follows it places nothing
export function landmarkDragEnd(): boolean {
  _armed = null;
  const d = state.landmarkDrag as LandmarkDrag | null;
  if (!d) return false;
  state.landmarkDrag = null;
  _over[d.which] = false;
  panController(d.which, true);
  const reg = store.getState().registration;
  const value = reg && stored(reg, d.which, d.pos);
  if (value) actions.updateLandmark(d.id, { [d.which]: value });
  _dropped = true;
  return true;
}

// Whether the click now arriving ends a drag (and so places nothing)
export function consumeDrop(): boolean {
  const d = _dropped;
  _dropped = false;
  return d;
}

// Delete or Backspace in landmark mode: the open pair, or else the last pair
export function removeLastLandmark() {
  const reg = store.getState().registration;
  if (!reg?.landmarks.length) return;
  actions.removeLandmark((pending(reg) ?? reg.landmarks[reg.landmarks.length - 1]).id);
}

// Escape in landmark mode drops the open pair
export function cancelPendingLandmark(): boolean {
  const reg = store.getState().registration;
  const open = reg && pending(reg);
  if (open) actions.removeLandmark(open.id);
  return !!open;
}

// Flips and quarter turns of the image's pane
function orientBy(op: (p: Affine, w: number, h: number) => Affine) {
  const reg = store.getState().registration;
  const size = reg && imageSize(reg.image);
  if (reg && size) actions.patchRegistration({ orient: op(reg.orient, size.width, size.height) });
}
export const flipImage = (axis: 'h' | 'v') => orientBy((p, w, h) => flip(p, w, h, axis));
export const rotateImage = (turns: number) => orientBy((p, w, h) => rotate90(p, w, h, turns));

// ── The image's pane ──────────────────────────────────────────────────────────

const _matrices = new WeakMap<Affine, Matrix4>();
function orientMatrix(orient: Affine) {
  let m = _matrices.get(orient);
  if (!m) { m = new Matrix4(matrix4(orient)); _matrices.set(orient, m); }
  return m;
}

// Pane coordinates → data, with a fit
function paneToData(reg: Registration): Affine | null {
  const fit = registrationFit(reg);
  const inv = fit && invert(reg.orient);
  return fit && inv ? compose(fit.transform, inv) : null;
}

function fitPane() {
  const reg = store.getState().registration;
  const size = reg && imageSize(reg.image);
  const pane = $('reg-pane');
  if (!reg || !size || !pane || !_deck) return;
  const corners = ([[0, 0], [size.width, 0], [0, size.height], [size.width, size.height]] as XY[]).map(c => apply(reg.orient, c));
  const xs = corners.map(c => c[0]), ys = corners.map(c => c[1]);
  const [x0, x1, y0, y1] = [Math.min(...xs), Math.max(...xs), Math.min(...ys), Math.max(...ys)];
  const zoom = fitZoom(x1 - x0, y1 - y0, { width: pane.clientWidth, height: pane.clientHeight }) - 0.2;
  _vs = { target: [(x0 + x1) / 2, (y0 + y1) / 2, 0], zoom, minZoom: zoom - 3, maxZoom: zoom + 14 };
  _deck.setProps({ viewState: _vs });
  requestRender();
}

function paneViewChange(vs: any) {
  _vs = vs;
  _deck.setProps({ viewState: vs });
  const reg = store.getState().registration;
  const m = reg?.link && paneToData(reg);
  if (m && state.currentViewState) setViewState(mapView(vs, m, state.currentViewState));
  requestRender();
}

// The main view moved: with linked panes, the image's pane follows
export function onMainView(vs: any) {
  const reg = store.getState().registration;
  if (!registering() || !reg?.link || !_deck || !_vs) return;
  const m = paneToData(reg);
  const inv = m && invert(m);
  if (!m || !inv) return;
  _vs = mapView(vs, inv, _vs);
  _deck.setProps({ viewState: _vs });
}

export function renderRegPane() {
  if (!_deck || !registering()) return;
  const s = store.getState();
  const reg = s.registration!;
  const img = state.images?.get(reg.image);
  const layers: any[] = [];
  if (img) layers.push(imageLayer('reg-img-' + img.entry.url, img, s.images[reg.image], orientMatrix(reg.orient), 1));
  layers.push(...landmarkLayers(reg, 'moving', state.landmarkDrag, landmarkHover('moving')));
  _deck.setProps({ layers });
}

let _paneImage: string | null = null;
let _paneOrient: Affine | null = null;
function syncPane() {
  const sp = $('spatial-pane'), pane = $('reg-pane');
  if (!sp || !pane) return;
  const on = registering();
  const was = sp.classList.contains('registering');
  if (on !== was) {
    sp.classList.toggle('registering', on);
    pane.style.display = on ? '' : 'none';
    window.dispatchEvent(new Event('resize'));
    // The main view is half as wide: tiles and the scalebar follow
    requestAnimationFrame(() => { if (state.currentViewState) setViewState({ ...state.currentViewState }); });
  }
  if (!on) { _paneImage = null; return; }
  const reg = store.getState().registration!;
  if (!_deck) {
    _deck = new Deck({
      canvas: 'reg-canvas', width: '100%', height: '100%',
      views: new OrthographicView({ id: 'reg', controller: true, flipY: false }),
      viewState: { target: [0, 0, 0], zoom: 0 }, controller: { doubleClickZoom: false },
      onViewStateChange: ({ viewState }: any) => paneViewChange(viewState),
      getCursor: ({ isDragging }: any) => isDragging ? 'grabbing' : 'crosshair',
      layers: [],
    } as any);
    state.regDeck = _deck;
  }
  ($('reg-pane-label') as HTMLElement).textContent = reg.image;
  ($('reg-ref-label') as HTMLElement).textContent = reg.reference ?? 'data';
  if (_paneImage !== reg.image || _paneOrient !== reg.orient) {
    _paneImage = reg.image;
    _paneOrient = reg.orient;
    requestAnimationFrame(fitPane);
  }
  requestRender();
}

function initPaneInput() {
  const canvas = $('reg-canvas') as HTMLCanvasElement | null;
  if (!canvas) return;
  let down: [number, number] | null = null;
  const world = (e: MouseEvent) => clientToWorld(e.clientX, e.clientY, canvas, _vs) as XY;
  canvas.addEventListener('mousedown', e => {
    down = [e.clientX, e.clientY];
    if (landmarkDragStart('moving', e, canvas)) requestRender();
  });
  canvas.addEventListener('mousemove', e => {
    if (_vs && landmarkDragMove('moving', world(e), e)) requestRender();
  });
  canvas.addEventListener('click', e => {
    const moved = down && Math.hypot(e.clientX - down[0], e.clientY - down[1]) > 4;
    if (!consumeDrop() && !moved && _vs && registering()) landmarkClick('moving', world(e));
    requestRender();
  });
}

// ── Panel ─────────────────────────────────────────────────────────────────────

function options(sel: HTMLSelectElement, names: string[], none: string | null) {
  sel.replaceChildren(...[...(none != null ? [[ '', none ]] : []), ...names.map(n => [n, n])].map(([v, t]) =>
    Object.assign(document.createElement('option'), { value: v, textContent: t })));
}

export function initRegistration() {
  if (!state.images?.size) return;
  const panel = $('reg-panel');
  if (!panel) return;
  panel.style.display = '';
  const names = [...state.images.keys()] as string[];
  const $image = $('reg-image') as HTMLSelectElement;
  const $ref = $('reg-reference') as HTMLSelectElement;
  const $start = $('reg-start') as HTMLButtonElement;
  const $preview = $('reg-preview') as HTMLInputElement;
  const $link = $('reg-link') as HTMLInputElement;
  const $status = $('reg-status')!;
  const $list = $('reg-list')!;
  const orientBtns = ['reg-flip-h', 'reg-flip-v', 'reg-rot-ccw', 'reg-rot-cw'].map($) as HTMLButtonElement[];

  options($image, names, null);
  // Default: the first RGB image (an H&E) against the first other image
  const rgb = names.find(n => state.images.get(n).rgb);
  $image.value = rgb ?? names[names.length - 1];
  const refFor = (img: string) => names.find(n => n !== img && !state.images.get(n).rgb) ?? names.find(n => n !== img) ?? '';
  const fillRef = () => { options($ref, names.filter(n => n !== $image.value), 'none'); $ref.value = refFor($image.value); };
  fillRef();
  $image.addEventListener('change', fillRef);

  $start.addEventListener('click', () => {
    const s = store.getState();
    if (s.mode === 'landmark') { actions.setMode('pan'); return; }
    if (!s.registration || s.registration.image !== $image.value || s.registration.reference !== ($ref.value || null))
      startRegistration($image.value, $ref.value || null);
    actions.setMode('landmark');
  });
  $('reg-reset')?.addEventListener('click', () => {
    actions.setRegistration(null);
    if (store.getState().mode === 'landmark') actions.setMode('pan');
  });
  $('reg-flip-h')?.addEventListener('click', () => flipImage('h'));
  $('reg-flip-v')?.addEventListener('click', () => flipImage('v'));
  $('reg-rot-ccw')?.addEventListener('click', () => rotateImage(1));
  $('reg-rot-cw')?.addEventListener('click', () => rotateImage(-1));
  $preview.addEventListener('change', () => actions.patchRegistration({ preview: $preview.checked }));
  $link.addEventListener('change', () => {
    actions.patchRegistration({ link: $link.checked });
    if ($link.checked && state.currentViewState) onMainView(state.currentViewState);
  });

  const render = () => {
    const s = store.getState();
    const reg = s.registration;
    const active = registering();
    $start.textContent = active ? 'done' : reg ? 'place points' : 'start';
    $start.classList.toggle('active', active);
    $image.disabled = $ref.disabled = active;
    if (reg) { $image.value = reg.image; if (!active) { fillRef(); $ref.value = reg.reference ?? ''; } }
    const fit = reg ? registrationFit(reg) : null;
    for (const b of orientBtns) b.disabled = !active;
    ($('reg-reset') as HTMLButtonElement).disabled = !reg;
    $preview.checked = !!reg?.preview;
    $preview.disabled = !reg;
    $link.checked = !!reg?.link;
    $link.disabled = !fit;

    const done = reg ? completePairs(reg).length : 0;
    const open = reg && pending(reg);
    const fixedName = reg?.reference ?? 'the data';
    $status.textContent = !reg ? 'pick an image and a reference, then start'
      : open ? (open.moving ? `click the matching point on ${fixedName} (right)` : `click the matching point on ${reg.image} (left)`)
      : fit ? `${done} pairs · RMSE ${fit.rmse.toFixed(2)} μm`
      : active ? `click a point in either pane · ${done}/${MIN_PAIRS} pairs for a fit`
      : `${done}/${MIN_PAIRS} pairs for a fit`;

    $list.replaceChildren();
    if (!reg) return;
    let k = 0;
    reg.landmarks.forEach((l, i) => {
      const row = Object.assign(document.createElement('div'), { className: 'reg-row' });
      const dot = (on: boolean, c: number[]) => `<span class="reg-dot" style="${on ? `background:${css(c)}` : ''};border-color:${css(c)}"></span>`;
      const res = l.moving && l.fixed && fit ? fit.residuals[k++] : null;
      row.innerHTML = `<span class="reg-n">${i + 1}</span>${dot(!!l.moving, MOVING_COLOR)}${dot(!!l.fixed, FIXED_COLOR)}` +
        `<span class="reg-res">${res != null ? `${res.toFixed(2)} μm` : ''}</span>` +
        `<button class="annot-row-btn" title="delete"><i data-lucide="x"></i></button>`;
      row.querySelector('button')!.addEventListener('click', () => actions.removeLandmark(l.id));
      $list.appendChild(row);
    });
    createIcons({ icons, root: $list });
  };
  render();
  store.subscribe(s => [s.registration, s.mode], () => { render(); syncPane(); },
    { equalityFn: (a, b) => a[0] === b[0] && a[1] === b[1] });
  initPaneInput();
  syncPane();

  // R keeps the latest (LensViewer$registration)
  let timer: ReturnType<typeof setTimeout> | null = null;
  store.subscribe(s => s.registration, () => {
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => sendToR('registration_update', registrationPayload(store.getState().registration)), 150);
  });
}
