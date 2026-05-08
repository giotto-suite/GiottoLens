// Lightweight coordination — components register handlers for named types;
// any module that changes coordinated state calls notify(type) once.

const _handlers = {};

export function onCoord(type, handler) {
  (_handlers[type] ??= []).push(handler);
}

export function notify(type) {
  (_handlers[type] ?? []).forEach(h => {
    try { h(); } catch(e) { console.warn('[coord]', type, e); }
  });
}
