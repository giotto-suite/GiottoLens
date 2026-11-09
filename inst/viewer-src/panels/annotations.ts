// The annotations panel: the drawn and pushed shapes (store `annotations`),
// each selectable (its name is edited in the popup over the spatial view,
// ui/annotations.js), zoomed to, or deleted. A note until there are any.
import { state } from '../core/state.js';
import { store, actions, type Annotation } from '../core/store.ts';
// @ts-ignore: plain JS module
import { fitZoom, escapeHtml, withZoom } from '../ui/dom.js';
// @ts-ignore: plain JS module
import { setViewState } from '../data/schedule.js';
import { createIcons, icons } from 'lucide';
import type { PanelHandle } from './dock.ts';

const TYPE_ABBR: Record<string, string> = { polygon: 'poly', rectangle: 'rect', freehand: 'free' };

function zoomTo(a: Annotation) {
  const xs = a.coords.map(p => p[0]), ys = a.coords.map(p => p[1]);
  const xmin = Math.min(...xs), xmax = Math.max(...xs);
  const ymin = Math.min(...ys), ymax = Math.max(...ys);
  const zoom = Math.min(fitZoom(Math.max(xmax - xmin, 1), Math.max(ymax - ymin, 1)) - 0.4,
                        state.currentViewState.maxZoom);
  setViewState(withZoom({ ...state.currentViewState, target: [(xmin + xmax) / 2, (ymin + ymax) / 2, 0] }, zoom));
}

export function createAnnotationsPanel(body: HTMLElement): PanelHandle {
  const note = Object.assign(document.createElement('div'), { className: 'panel-note',
    textContent: 'Draw a shape with the draw tools, or push them from R: viewer$push_polygons()' });
  const list = Object.assign(document.createElement('div'), { className: 'annot-list' });
  body.append(note, list);

  function render() {
    const { annotations, selectedAnnotId } = store.getState();
    note.style.display = annotations.length ? 'none' : '';
    list.replaceChildren(...annotations.map(a => {
      const row = Object.assign(document.createElement('div'), {
        className: 'annot-row' + (a.id === selectedAnnotId ? ' selected' : '') });
      row.dataset.id = a.id;
      const name = a.name ? escapeHtml(a.name) : '<span class="annot-unnamed">unnamed</span>';
      row.innerHTML =
        `<span class="annot-type-tag ${escapeHtml(a.type)}">${escapeHtml(TYPE_ABBR[a.type] ?? a.type)}</span>` +
        `<span class="annot-name-text">${name}</span>` +
        `<button class="annot-row-btn annot-row-nav" title="zoom to"><i data-lucide="locate"></i></button>` +
        `<button class="annot-row-btn annot-row-del" title="delete"><i data-lucide="x"></i></button>`;
      row.querySelector('.annot-row-nav')!.addEventListener('click', e => { e.stopPropagation(); zoomTo(a); });
      row.querySelector('.annot-row-del')!.addEventListener('click', e => {
        e.stopPropagation();
        actions.removeAnnotation(a.id);
      });
      row.addEventListener('click', () =>
        actions.selectAnnotation(a.id === store.getState().selectedAnnotId ? null : a.id));
      return row;
    }));
    createIcons({ icons, root: list });
  }
  render();
  const unsub = store.subscribe(s => [s.annotations, s.selectedAnnotId], render,
    { equalityFn: (a, b) => a[0] === b[0] && a[1] === b[1] });

  return { destroy: unsub };
}
