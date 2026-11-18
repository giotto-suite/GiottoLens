// One render per animation frame, however many changes asked for one.
import { spatialView } from '../spatial/current.ts';
import { store } from '../core/store.ts';
import { renderLayers } from './render.js';

let _pending = false;
export function requestRender() {
  if (_pending) return;
  _pending = true;
  requestAnimationFrame(() => {
    _pending = false;
    // A view behind another tab has no size: it catches up when shown (its
    // resize observer asks for a render)
    const view = spatialView();
    if (view?.root.clientWidth) renderLayers(view);
  });
}

// Every store change may change what is drawn
export function initRenderScheduler() {
  store.subscribe(requestRender);
}
