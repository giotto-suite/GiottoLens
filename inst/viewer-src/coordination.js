// Lightweight coordination — components register handlers for named types;
// any module that changes coordinated state calls notify(type) once.

import { state } from './state.js';

const _handlers = {};

// Returns a cleanup function that removes the handler when called.
export function onCoord(type, handler) {
  (_handlers[type] ??= []).push(handler);
  return () => {
    _handlers[type] = (_handlers[type] ?? []).filter(h => h !== handler);
  };
}

// ── Cross-filter helpers ──────────────────────────────────────────────────────
export function recomputeCrossFilter() {
  const sf = state.spatialFilter, sc = state.scatterFilter;
  if      (!sf && !sc) state.selectedCells = new Set();
  else if (!sc)        state.selectedCells = new Set(sf);
  else if (!sf)        state.selectedCells = new Set(sc);
  else                 state.selectedCells = new Set([...sf].filter(id => sc.has(id)));
  state.selVersion++;
  notify('cellSelection');
}

export function clearFilters() {
  state.spatialFilter = null;
  state.scatterFilter = null;
  state.selectedCells = new Set();
  state.selVersion++;
  notify('cellSelection');
}

export function sqlIds(ids) {
  return [...ids].map(id => `'${String(id).replace(/'/g, "''")}'`).join(',');
}

export function notify(type) {
  (_handlers[type] ?? []).forEach(h => {
    try { h(); } catch(e) { console.warn('[coord]', type, e); }
  });
}
