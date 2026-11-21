// Editing the selected annotation's ring in pan mode or a drawing tool (so
// shapes can be drawn and fixed without changing tools): drag a vertex to
// move it, drag a midpoint to add one there, double-click a vertex to remove
// it. A press on a handle edits; anywhere else the tool draws as usual.
// Arming and dropping are the landmark drag's (ui/registration.ts); the ring
// being dragged is runtime state (state.annotDrag) and reaches the store, and
// so R, once, on mouseup.
import { state } from '../core/state.js';
import { store, actions, type Annotation } from '../core/store.ts';
import { spatialView } from '../spatial/current.ts';
// @ts-ignore: plain JS module
import { spaceHeld } from './dom.js';
import { setOverHandle } from './controller.ts';
import type { XY } from '../data/registration.ts';

export const VERTEX_LAYER = 'annot-vertices';
export const MIDPOINT_LAYER = 'annot-midpoints';
const DRAG_PX = 4;
const MIN_VERTICES = 3;
// A side shorter than this on screen gets no midpoint: freehand rings would
// otherwise be lined with them
const MIDPOINT_MIN_PX = 24;

// A handle: a vertex at `index`, or a midpoint that inserts one at `index`
export interface Handle { index: number; pos: XY }
// The ring being dragged, open (no repeated first point)
export interface AnnotDrag { id: string; ring: XY[] }

// ── Rings ─────────────────────────────────────────────────────────────────────
// Annotations keep closed rings (GeoJSON); edits work on the open one.
export function openRing(coords: XY[]): XY[] {
  const n = coords.length, [a, b] = [coords[0], coords[n - 1]];
  return n > 1 && a[0] === b[0] && a[1] === b[1] ? coords.slice(0, -1) : coords.slice();
}
export const closeRing = (ring: XY[]): XY[] => [...ring, ring[0]];

export function insertVertex(ring: XY[], index: number, pos: XY): XY[] {
  return [...ring.slice(0, index), pos, ...ring.slice(index)];
}

// null when the ring would fall below a triangle
export function removeVertex(ring: XY[], index: number): XY[] | null {
  return ring.length > MIN_VERTICES ? ring.filter((_, i) => i !== index) : null;
}

export function handles(ring: XY[], zoom: number) {
  const scale = Math.pow(2, zoom);
  const vertices: Handle[] = ring.map((pos, index) => ({ index, pos }));
  const midpoints: Handle[] = [];
  ring.forEach((a, i) => {
    const b = ring[(i + 1) % ring.length];
    if (Math.hypot(b[0] - a[0], b[1] - a[1]) * scale >= MIDPOINT_MIN_PX)
      midpoints.push({ index: i + 1, pos: [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2] });
  });
  return { vertices, midpoints };
}

// ── The edited annotation ─────────────────────────────────────────────────────
// The tools a selected annotation can be edited in
export const EDIT_MODES = ['pan', 'poly', 'rect', 'freehand'];

// The selected one, in pan mode or a drawing tool, while annotations are
// drawn; not while a polygon is being drawn, whose clicks are its own
export function editedAnnotation(): Annotation | null {
  const s = store.getState();
  if (!EDIT_MODES.includes(s.mode) || !s.selectedAnnotId) return null;
  if (s.mode === 'poly' && state.drawRing?.length) return null;
  if (!s.layers.annotations.show || s.layers.annotations.alpha <= 0) return null;
  return s.annotations.find(a => a.id === s.selectedAnnotId) ?? null;
}

// Its ring as drawn: the dragged one while a drag is on
export function editedRing(a: Annotation): XY[] {
  const d = state.annotDrag as AnnotDrag | null;
  return d?.id === a.id ? d.ring : openRing(a.coords);
}

// ── Dragging ──────────────────────────────────────────────────────────────────
// The view does not pan while the pointer is over a handle (ui/controller.ts).
// Mousedown there arms a drag, which starts once the pointer moves more than
// DRAG_PX. A midpoint's vertex is only added if it is dragged.
let _armed: { id: string; ring: XY[]; index: number; x: number; y: number } | null = null;

export function annotHandleHover(info: { picked?: boolean }) {
  if (!state.annotDrag) setOverHandle(!!info.picked);
}

function pick(e: MouseEvent, canvas: HTMLCanvasElement, layerIds: string[]) {
  const r = canvas.getBoundingClientRect();
  return spatialView()?.deck.pickObject({ x: e.clientX - r.left, y: e.clientY - r.top, radius: 6, layerIds });
}

export function annotDragStart(e: MouseEvent, canvas: HTMLCanvasElement): boolean {
  const a = editedAnnotation();
  if (!a || spaceHeld()) return false;
  const picked = pick(e, canvas, [VERTEX_LAYER, MIDPOINT_LAYER]);
  if (!picked?.object) return false;
  const { index, pos } = picked.object as Handle;
  const ring = openRing(a.coords);
  _armed = { id: a.id, index, x: e.clientX, y: e.clientY,
             ring: picked.layer.id === MIDPOINT_LAYER ? insertVertex(ring, index, pos) : ring };
  setOverHandle(true);
  return true;
}

export function annotDragMove(pt: XY, e: MouseEvent): boolean {
  if (!_armed) return false;
  if (!state.annotDrag) {
    if (Math.hypot(e.clientX - _armed.x, e.clientY - _armed.y) <= DRAG_PX) return false;
    state.annotDrag = { id: _armed.id, ring: _armed.ring };
  }
  const ring = state.annotDrag.ring.slice();
  ring[_armed.index] = pt;
  state.annotDrag = { ...state.annotDrag, ring };
  return true;
}

export function annotDragEnd(): boolean {
  _armed = null;
  const d = state.annotDrag as AnnotDrag | null;
  if (!d) return false;
  state.annotDrag = null;
  setOverHandle(false);
  actions.setAnnotationCoords(d.id, closeRing(d.ring));
  return true;
}

// Escape during a drag puts the vertex back
export function cancelAnnotDrag(): boolean {
  if (!_armed && !state.annotDrag) return false;
  _armed = null;
  state.annotDrag = null;
  setOverHandle(false);
  return true;
}

// Double-click on a vertex removes it, down to a triangle
export function annotVertexRemove(e: MouseEvent, canvas: HTMLCanvasElement): boolean {
  const a = editedAnnotation();
  if (!a) return false;
  const picked = pick(e, canvas, [VERTEX_LAYER]);
  if (!picked?.object) return false;
  const ring = removeVertex(openRing(a.coords), (picked.object as Handle).index);
  if (ring) actions.setAnnotationCoords(a.id, closeRing(ring));
  return true;
}
