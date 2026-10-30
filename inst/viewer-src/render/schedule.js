// One render per animation frame, however many changes asked for one.
import { state } from '../core/state.js';
import { store } from '../core/store.ts';
import { renderLayers } from './render.js';

let _pending = false;
export function requestRender() {
  if (_pending) return;
  _pending = true;
  requestAnimationFrame(() => {
    _pending = false;
    renderLayers(state.currentViewState);
  });
}

// Every store change may change what is drawn
export function initRenderScheduler() {
  store.subscribe(requestRender);
}
