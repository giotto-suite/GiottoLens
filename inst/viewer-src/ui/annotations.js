// Annotation names and ids, and the annotations sent to R. The list, where a
// name is edited, is a panel (panels/annotations.ts).
import { store, actions } from '../core/store.ts';
import { sendToR, onMessage } from '../core/comms.js';

export function generateAnnotId() {
  return `ann_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`;
}

// Names are unique and never empty: they key the annotations in R. A new
// shape gets annotation_<n>, n above any in use.
export function nextAnnotName(names) {
  let n = 0;
  for (const s of names) {
    const m = /^annotation_(\d+)$/.exec(s);
    if (m) n = Math.max(n, Number(m[1]));
  }
  return `annotation_${n + 1}`;
}

// What is wrong with `name` for annotation `id`, or null
export function nameProblem(id, name) {
  if (!name) return 'a name is needed';
  if (store.getState().annotations.some(a => a.id !== id && a.name === name)) return 'name taken';
  return null;
}

// The annotations R holds (drawn in an earlier page, or opened from a save)
// come with the 'restore' on the first connect, to a page with none of its
// own. Later connects are reconnects: the page's own are the newer ones.
export function annotationsFromR(rows) {
  return (rows ?? []).map(r => ({
    id: generateAnnotId(), name: r.name, coords: JSON.parse(r.geojson).geometry.coordinates[0],
  }));
}

export function initAnnotations() {
  let restored = false;
  onMessage('restore', ({ annotations }) => {
    if (restored) return;
    restored = true;
    if (!store.getState().annotations.length && annotations?.length)
      actions.addAnnotations(annotationsFromR(annotations));
  });
  store.subscribe(s => s.annotations, annotations => {
    sendToR('annotations_update', {
      annotations: annotations.map(a => ({
        name: a.name,
        geojson: JSON.stringify({ type: 'Feature', geometry: { type: 'Polygon', coordinates: [a.coords] } }),
      })),
    });
  });
}
