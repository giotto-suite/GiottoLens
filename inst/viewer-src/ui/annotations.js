// The annotation name popup over the spatial view, and the annotations sent
// to R. The list is a panel (panels/annotations.ts).
import { store, actions } from '../core/store.ts';
import { sendToR } from '../core/comms.js';

export function generateAnnotId() {
  return `ann_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`;
}

export function initAnnotations() {
  const $popup = document.getElementById('annot-popup');
  const $name  = document.getElementById('annot-name');
  const $type  = document.getElementById('annot-type');

  store.subscribe(s => s.selectedAnnotId, id => {
    const annot = id && store.getState().annotations.find(a => a.id === id);
    if (annot) {
      if ($name) $name.value = annot.name ?? '';
      if ($type) $type.textContent = annot.type ?? '';
      $popup?.classList.add('visible');
    } else {
      $popup?.classList.remove('visible');
    }
  });

  $name?.addEventListener('input', () => {
    const id = store.getState().selectedAnnotId;
    if (id) actions.renameAnnotation(id, $name.value);
  });

  store.subscribe(s => s.annotations, annotations => {
    sendToR('annotations_update', {
      annotations: annotations.map(a => ({
        id: a.id, type: a.type, name: a.name ?? '',
        geojson: JSON.stringify({ type: 'Feature', geometry: { type: 'Polygon', coordinates: [a.coords] } }),
      })),
    });
  });
}
