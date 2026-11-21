// The spatial view's deck.gl controller has one writer, here. A drag pans
// unless the tool takes it (the drawing tools) or the pointer is on a handle
// a drag moves (landmarks, annotation vertices). Handle modules report the
// pointer with setOverHandle and never set the controller themselves. Kept
// out of ui/input.js, which imports the handle modules.
import { state } from '../core/state.js';
import { store } from '../core/store.ts';
import { spatialView } from '../spatial/current.ts';

export const DRAG_MODES = ['lasso', 'txlasso', 'rect', 'freehand', 'brush'];

let _overHandle = false;
export const overHandle = () => _overHandle;

export function setOverHandle(on: boolean) {
  if (on === _overHandle) return;
  _overHandle = on;
  applyController();
}

// The handles went away under the pointer (tool changed, annotation
// deselected), so no pointer-leave will come; a drag in progress keeps it
export function releaseHandle() {
  if (!state.annotDrag && !state.landmarkDrag) setOverHandle(false);
}

export function applyController() {
  const pan = !DRAG_MODES.includes(store.getState().mode) && !_overHandle;
  spatialView()?.deck.setProps({
    controller: pan ? { doubleClickZoom: false } : { dragPan: false, doubleClickZoom: false } });
}
