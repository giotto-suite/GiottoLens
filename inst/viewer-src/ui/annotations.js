// The annotation name popup over the spatial view, and the annotations sent
// to R. The list is a panel (panels/annotations.ts).
import { store, actions } from '../core/store.ts';
import { sendToR } from '../core/comms.js';

export function generateAnnotId() {
  return `ann_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`;
}

// The selected annotation's name, edited in a view's popup
export function attachAnnotPopup(view) {
  const { annotPopup: $popup, annotName: $name, annotType: $type } = view.el;
  const unsub = store.subscribe(s => s.selectedAnnotId, id => {
    const annot = id && store.getState().annotations.find(a => a.id === id);
    if (annot) {
      $name.value = annot.name ?? '';
      $type.textContent = annot.type ?? '';
      $popup.classList.add('visible');
    } else {
      $popup.classList.remove('visible');
    }
  }, { fireImmediately: true });
  view.signal.addEventListener('abort', unsub);

  $name.addEventListener('input', () => {
    const id = store.getState().selectedAnnotId;
    if (id) actions.renameAnnotation(id, $name.value);
  });
}

export function initAnnotations() {
  store.subscribe(s => s.annotations, annotations => {
    sendToR('annotations_update', {
      annotations: annotations.map(a => ({
        id: a.id, type: a.type, name: a.name ?? '',
        geojson: JSON.stringify({ type: 'Feature', geometry: { type: 'Polygon', coordinates: [a.coords] } }),
      })),
    });
  });
}
