// The annotations panel: the drawn and pushed shapes (store `annotations`),
// each selectable (its name is edited in the popup over the spatial view,
// ui/annotations.js), zoomed to, used to select the cells inside it (as a
// lasso stroke of the same ring), or deleted. A note until there are any.
import { store, actions, type Annotation } from '../core/store.ts';
// @ts-ignore: plain JS module
import { fitZoom, escapeHtml, withZoom } from '../ui/dom.js';
// @ts-ignore: plain JS module
import { setViewState } from '../data/schedule.js';
import { createIcons, icons } from 'lucide';
import type { PanelHandle } from './dock.ts';
import { spatialView } from '../spatial/current.ts';
import { lassoSpatial, strokeOp } from '../selection/selection.ts';

// Clamped to the fitted view's maxZoom: once the controller has moved the
// camera its view state carries maxZoomX/maxZoomY and no maxZoom
function zoomTo(a: Annotation) {
  const view = spatialView();
  const vs = view?.viewState;
  if (!vs) return;
  const xs = a.coords.map(p => p[0]), ys = a.coords.map(p => p[1]);
  const xmin = Math.min(...xs), xmax = Math.max(...xs);
  const ymin = Math.min(...ys), ymax = Math.max(...ys);
  const zoom = Math.min(fitZoom(Math.max(xmax - xmin, 1), Math.max(ymax - ymin, 1)) - 0.4,
                        view.initialViewState?.maxZoom ?? Infinity);
  setViewState(withZoom({ ...vs, target: [(xmin + xmax) / 2, (ymin + ymax) / 2, 0] }, zoom));
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
      row.innerHTML =
        `<span class="annot-name-text">${escapeHtml(a.name)}</span>` +
        `<button class="annot-row-btn annot-row-sel" title="select the cells inside (Shift adds, Alt or Ctrl/Cmd subtracts)"><i data-lucide="square-dashed-mouse-pointer"></i></button>` +
        `<button class="annot-row-btn annot-row-nav" title="zoom to"><i data-lucide="locate"></i></button>` +
        `<button class="annot-row-btn annot-row-del" title="delete"><i data-lucide="x"></i></button>`;
      row.querySelector<HTMLElement>('.annot-row-sel')!.addEventListener('click', (e: MouseEvent) => {
        e.stopPropagation();
        lassoSpatial(a.coords, strokeOp(e));
      });
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
